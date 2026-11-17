import CoreLocation
import GigCore

/// Keeps your current location in the shared store so the screen reader can check
/// "is this offer on my way?". Runs in the background while you drive.
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()
    private let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 30
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        manager.requestWhenInUseAuthorization()
        startIfAllowed()
    }

    private func startIfAllowed() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization() // lets it keep updating while you're in the gig app
        }
        startIfAllowed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        SharedStore.shared.currentLocation = Coord(l.coordinate)
    }
}
