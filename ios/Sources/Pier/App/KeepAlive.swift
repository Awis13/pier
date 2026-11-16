import CoreLocation
import Foundation

/// Keeps the app running in the background while a terminal is open, the way
/// Blink's "geo track" does: coarse location updates with background delivery.
/// Locations are ignored.
@MainActor
final class KeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "keepAlive")
            update()
        }
    }

    private let manager = CLLocationManager()
    private var terminals = 0

    override init() {
        enabled = UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
    }

    func terminalOpened() {
        terminals += 1
        update()
    }

    func terminalClosed() {
        terminals = max(0, terminals - 1)
        update()
    }

    private func update() {
        guard enabled, terminals > 0 else {
            manager.stopUpdatingLocation()
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.update() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
