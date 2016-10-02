//
//  LocationManager.swift
//  BlueCap
//
//  Created by Troy Stribling on 9/1/14.
//  Copyright (c) 2014 Troy Stribling. The MIT License (MIT).
//

import Foundation
import CoreLocation

// MARK: - Errors -
public enum LocationError : Swift.Error {
    case notAvailable
    case updateFailed
    case authorizationAlwaysFailed
    case authorizationWhenInUseFailed
    case authroizationInvalid
}

// MARK: - CLLocationManagerInjectable -
public protocol CLLocationManagerInjectable {

    var delegate: CLLocationManagerDelegate? { get set }

    // MARK: Authorization
    static func authorizationStatus() -> CLAuthorizationStatus
    func requestAlwaysAuthorization()
    func requestWhenInUseAuthorization()

    // MARK: Configure
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var activityType: CLActivityType { get set }
    var distanceFilter : CLLocationDistance { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }

    // MARK: Location Updates
    var location: CLLocation? { get }
    static func locationServicesEnabled() -> Bool
    func requestLocation()
    func startUpdatingLocation()
    func stopUpdatingLocation()

     // MARK: Deferred Location Updates
    static func deferredLocationUpdatesAvailable() -> Bool
    func allowDeferredLocationUpdatesUntilTraveled(_ distance: CLLocationDistance, timeout: TimeInterval)

    // MARK: Significant Change in Location
    static func significantLocationChangeMonitoringAvailable() -> Bool
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()

    // MARK: Region Monitoring
    var maximumRegionMonitoringDistance: CLLocationDistance { get }
    var monitoredRegions: Set<CLRegion> { get }
    func startMonitoringForRegion(_ region: CLRegion)
    func stopMonitoringForRegion(_ region: CLRegion)

    // MARK: Beacons
    static func isRangingAvailable() -> Bool
    var rangedRegions: Set<CLRegion> { get }
    func startRangingBeaconsInRegion(_ region: CLBeaconRegion)
    func stopRangingBeaconsInRegion(_ region: CLBeaconRegion)
    func requestStateForRegion(_ region: CLRegion)
}

extension CLLocationManager : CLLocationManagerInjectable {}

// MARK: - FLLocationManager -
public class LocationManager : NSObject, CLLocationManagerDelegate {

    // MARK: Serilaize Property IO
    static let ioQueue = Queue("us.gnos.futureLocation.location-manager.io")


    // MARK: Properties
    fileprivate var locationUpdatePromise: StreamPromise<[CLLocation]>?
    fileprivate var deferredLocationUpdatePromise: Promise<Void>?
    fileprivate var requestLocationPromise: Promise<[CLLocation]>?
    fileprivate var authorizationStatusChangedPromise: Promise<CLAuthorizationStatus>?
    fileprivate var authorizationFuture: Future<Void>?

    fileprivate var _isUpdating = false

    internal fileprivate(set) var clLocationManager: CLLocationManagerInjectable

    public fileprivate(set) var isUpdating: Bool {
        get {
            return LocationManager.ioQueue.sync { return self._isUpdating }
        }
        set {
            LocationManager.ioQueue.sync { self._isUpdating = newValue }
        }
    }

    // MARK: Configure
    public var pausesLocationUpdatesAutomatically: Bool {
        get {
            return self.clLocationManager.pausesLocationUpdatesAutomatically
        }
        set {
            self.clLocationManager.pausesLocationUpdatesAutomatically = newValue
        }
    }

    public var allowsBackgroundLocationUpdates: Bool {
        get {
            if let locationManager = self.clLocationManager as? CLLocationManager {
                return locationManager.allowsBackgroundLocationUpdates
            } else {
                return false
            }
        }
        set {
            if let locationManager = self.clLocationManager as? CLLocationManager {
                locationManager.allowsBackgroundLocationUpdates = newValue
            }
        }
    }

    public var activityType: CLActivityType {
        get {
            return self.clLocationManager.activityType
        }
        set {
            self.clLocationManager.activityType = newValue
        }
    }

    public var distanceFilter: CLLocationDistance {
        get {
            return self.clLocationManager.distanceFilter
        }
        set {
            self.clLocationManager.distanceFilter = newValue
        }
    }
    
    public var desiredAccuracy: CLLocationAccuracy {
        get {
            return self.clLocationManager.desiredAccuracy
        }
        set {
            self.clLocationManager.desiredAccuracy = newValue
        }
    }

    // MARK: Authorization
    public func authorizationStatus() -> CLAuthorizationStatus {
        return CLLocationManager.authorizationStatus()
    }

    fileprivate func requestWhenInUseAuthorization()  {
        self.clLocationManager.requestWhenInUseAuthorization()
    }

    fileprivate func requestAlwaysAuthorization() {
        self.clLocationManager.requestAlwaysAuthorization()
    }

    public func authorize(_ authorization: CLAuthorizationStatus, context: ExecutionContext = QueueContext.main) -> Future<Void> {
        let currentAuthorization = self.authorizationStatus()
        if currentAuthorization != authorization {
            if let authorizationFuture = self.authorizationFuture, !authorizationFuture.completed {
                return authorizationFuture
            }
            self.authorizationStatusChangedPromise = Promise<CLAuthorizationStatus>()
            switch authorization {
            case .authorizedAlways:
                self.requestAlwaysAuthorization()
            case .authorizedWhenInUse:
                self.requestWhenInUseAuthorization()
            default:
                Logger.debug("requested location authorization invalid")
                return Future(error: LocationError.authroizationInvalid)
            }
            authorizationFuture = self.authorizationStatusChangedPromise!.future.map(context: context) { status in
                switch authorization {
                case .authorizedAlways:
                    if status == .authorizedAlways {
                        Logger.debug("location AuthorizedAlways succcess")
                        return
                    } else {
                        Logger.debug("location AuthorizedAlways failed")
                        throw LocationError.authorizationAlwaysFailed
                    }
                case .authorizedWhenInUse:
                    if status == .authorizedWhenInUse {
                        Logger.debug("location AuthorizedWhenInUse succcess")
                        return
                    } else {
                        Logger.debug("location AuthorizedWhenInUse failed")
                        throw LocationError.authorizationWhenInUseFailed
                    }
                default:
                    throw LocationError.authroizationInvalid
                }
            }
            return authorizationFuture!
        } else {
            return Future(value: ())
        }
    }

    //MARK: Initialize
    public convenience override init() {
        self.init(clLocationManager: CLLocationManager())
    }

    public init(clLocationManager: CLLocationManagerInjectable) {
        self.clLocationManager = clLocationManager
        super.init()
        self.clLocationManager.delegate = self
    }

    deinit {
        clLocationManager.delegate = nil
    }

    // MARK: Reverse Geocode
    public class func reverseGeocode(location: CLLocation) -> Future<[CLPlacemark]>  {
        let geocoder = CLGeocoder()
        let promise = Promise<[CLPlacemark]>()
        geocoder.reverseGeocodeLocation(location) { (placemarks: [CLPlacemark]?, error: Swift.Error?) -> Void in
            if let error = error {
                promise.failure(error)
            } else {
                if let placemarks = placemarks {
                    promise.success(placemarks)
                } else {
                    promise.success([CLPlacemark]())
                }
            }
        }
        return promise.future
    }

    public func reverseGeocodeLocation()  -> Future<[CLPlacemark]>  {
        if let location = self.location {
            return LocationManager.reverseGeocode(location: location)
        } else {
            return Future(error: LocationError.updateFailed)
        }
    }

    // MARK: Location Updates
    public var location: CLLocation? {
        return self.clLocationManager.location
    }

    public func locationServicesEnabled() -> Bool {
        return CLLocationManager.locationServicesEnabled()
    }

    public func startUpdatingLocation(authorization: CLAuthorizationStatus = .authorizedWhenInUse, capacity: Int = Int.max, context: ExecutionContext = QueueContext.main) -> FutureStream<[CLLocation]> {
        if let locationUpdatePromise = self.locationUpdatePromise, self.isUpdating {
            return locationUpdatePromise.stream
        }
        self.locationUpdatePromise = StreamPromise<[CLLocation]>(capacity:capacity)
        self.isUpdating = true
        let authorizationFuture = self.authorize(authorization, context: context)
        authorizationFuture.onFailure(context: context) { _ in self.isUpdating = false }
        return authorizationFuture.flatMap(capacity: capacity, context: context) { Void -> FutureStream<[CLLocation]> in
            self.clLocationManager.startUpdatingLocation()
            return self.locationUpdatePromise!.stream
        }
    }

    public func stopUpdatingLocation() {
        self.isUpdating = false
        self.locationUpdatePromise = nil
        self.clLocationManager.stopUpdatingLocation()
    }

    public func requestLocation(authorization: CLAuthorizationStatus = .authorizedWhenInUse, context: ExecutionContext = QueueContext.main) -> Future<[CLLocation]> {
        if let requestLocationPromise = self.requestLocationPromise, !requestLocationPromise.completed {
            return requestLocationPromise.future
        }
        self.requestLocationPromise = Promise<[CLLocation]>()
        return self.authorize(authorization, context: context).flatMap(context: context) {
            self.clLocationManager.requestLocation()
            return self.requestLocationPromise!.future
        }
    }

    // MARK: Significant Change in Location
    public class func significantLocationChangeMonitoringAvailable() -> Bool {
        return CLLocationManager.significantLocationChangeMonitoringAvailable()
    }

    public func startMonitoringSignificantLocationChanges(authorization: CLAuthorizationStatus = .authorizedAlways, capacity: Int = Int.max, context: ExecutionContext = QueueContext.main) -> FutureStream<[CLLocation]> {
        if let locationUpdatePromise = self.locationUpdatePromise, self.isUpdating {
            return locationUpdatePromise.stream
        }
        self.locationUpdatePromise = StreamPromise<[CLLocation]>(capacity: capacity)
        let authorizationFuture = self.authorize(authorization, context: context)
        authorizationFuture.onFailure(context: context) { _ in self.isUpdating = false }
        return authorizationFuture.flatMap(capacity: capacity, context: context) { Void -> FutureStream<[CLLocation]> in
            self.isUpdating = true
            self.clLocationManager.startMonitoringSignificantLocationChanges()
            return self.locationUpdatePromise!.stream
        }
    }
    
    public func stopMonitoringSignificantLocationChanges() {
        self.isUpdating = false
        self.locationUpdatePromise  = nil
        self.clLocationManager.stopMonitoringSignificantLocationChanges()
    }

    // MARK: Deferred Location Updates
    public func deferredLocationUpdatesAvailable() -> Bool {
        return CLLocationManager.deferredLocationUpdatesAvailable()
    }

    public func allowDeferredLocationUpdatesUntilTraveled(_ distance: CLLocationDistance, timeout: TimeInterval) -> Future<Void> {
        self.deferredLocationUpdatePromise = Promise<Void>()
        self.clLocationManager.allowDeferredLocationUpdatesUntilTraveled(distance, timeout: timeout)
        return self.deferredLocationUpdatePromise!.future
    }

    // MARK: CLLocationManagerDelegate
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        self.didUpdate(locations: locations)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.didFail(withError: error)
    }

    public func locationManager(_ manager: CLLocationManager, didFinishDeferredUpdatesWithError error: Error?) {
        self.didFinishDeferredUpdates(withError: error)
    }
        
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        self.didChangeAuthorization(status: status)
    }

    public func didUpdate(locations: [CLLocation]) {
        Logger.debug()
        if let requestLocationPromise = self.requestLocationPromise, !requestLocationPromise.completed {
            requestLocationPromise.success(locations)
        }
        self.locationUpdatePromise?.success(locations)
    }

    public func didFail(withError error: Error) {
        Logger.debug("error \(error.localizedDescription)")
        if let requestLocationPromise = self.requestLocationPromise, !requestLocationPromise.completed {
            requestLocationPromise.failure(error)
        }
        self.locationUpdatePromise?.failure(error)
    }

    public func didFinishDeferredUpdates(withError error: Error?) {
        if let error = error {
            self.deferredLocationUpdatePromise?.failure(error)
        } else {
            self.deferredLocationUpdatePromise?.success()
        }
    }

    public func didChangeAuthorization(status: CLAuthorizationStatus) {
        guard let authorizationStatusChangedPromise = self.authorizationStatusChangedPromise, !authorizationStatusChangedPromise.completed else {
            return
        }
        Logger.debug("status: \(status)")
        authorizationStatusChangedPromise.success(status)
    }

}
