import CoreLocation
import MapKit

/// Shows a photo's GPS position in Apple Maps, only after an explicit click.
/// No geocoding, network check or logging happens in Louppe; Maps itself may
/// load map data once it opens. No location entitlement is needed to pass a
/// coordinate read from a file.
@MainActor
enum MapsLauncher {
    #if LOUPPE_TEST_SEAMS
    /// Replaces the MapKit handoff; receives the exact full-precision value.
    static var openOverride: ((PhotoGPSCoordinate) -> Void)?
    #endif

    static func open(_ coordinate: PhotoGPSCoordinate, onFailure: @escaping @MainActor () -> Void) {
        #if LOUPPE_TEST_SEAMS
        if let openOverride { openOverride(coordinate); return }
        #endif
        let item = mapItem(for: coordinate)
        if #available(macOS 14.4, *) {
            item.openInMaps(launchOptions: nil) { success in
                guard !success else { return }
                Task { @MainActor in onFailure() }
            }
        } else if !item.openInMaps(launchOptions: nil) {
            // macOS 14.0–14.3: synchronous, returns once Maps has launched.
            onFailure()
        }
    }

    static func mapItem(for coordinate: PhotoGPSCoordinate) -> MKMapItem {
        if #available(macOS 26.0, *) {
            return MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                                  longitude: coordinate.longitude),
                             address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(
            latitude: coordinate.latitude, longitude: coordinate.longitude)))
    }
}
