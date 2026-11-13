import CoreLocation
import MapKit

/// Turns coordinates into short human-readable place names for trip titles.
enum PlaceNamer {
    static func name(for location: CLLocation) async -> String? {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            if let name = item.name, !name.isEmpty { return name }
            return item.address?.shortAddress ?? item.address?.fullAddress
        } else {
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            if let street = placemark.thoroughfare {
                if let number = placemark.subThoroughfare { return "\(number) \(street)" }
                return street
            }
            return placemark.name ?? placemark.locality
        }
    }
}
