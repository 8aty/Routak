import Foundation

/// Fuel and mileage money math. Everything is stored in metric (liters per 100 km,
/// price per liter, rate per km) and converted for display when miles are on.
enum Costs {
    static let metersPerMile = 1_609.344
    static let litersPerGallon = 3.785411784
    /// mpg = this / (L/100 km), and the other way around.
    static let mpgFactor = 235.214583

    static var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    static func money(_ amount: Double) -> String {
        amount.formatted(.currency(code: currencyCode))
    }

    /// Estimated fuel cost of driving `meters`, or nil when no fuel price is set.
    static func fuelCost(for meters: Double, economy: Double = Prefs.fuelEconomy, price: Double = Prefs.fuelPrice) -> Double? {
        guard economy > 0, price > 0 else { return nil }
        return liters(for: meters, economy: economy) * price
    }

    static func liters(for meters: Double, economy: Double = Prefs.fuelEconomy) -> Double {
        meters / 1_000 * economy / 100
    }

    /// Mileage reimbursement for `meters` at the saved rate.
    static func reimbursement(for meters: Double, ratePerKm: Double = Prefs.mileageRate) -> Double {
        meters / 1_000 * ratePerKm
    }

    // MARK: Unit conversion for the settings UI

    static func displayEconomy(_ litersPer100km: Double, miles: Bool) -> Double {
        guard litersPer100km > 0 else { return 0 }
        return miles ? mpgFactor / litersPer100km : litersPer100km
    }

    static func storedEconomy(_ value: Double, miles: Bool) -> Double {
        guard value > 0 else { return 0 }
        return miles ? mpgFactor / value : value
    }

    static func displayPrice(_ perLiter: Double, miles: Bool) -> Double {
        miles ? perLiter * litersPerGallon : perLiter
    }

    static func storedPrice(_ value: Double, miles: Bool) -> Double {
        miles ? value / litersPerGallon : value
    }

    static func displayRate(_ perKm: Double, miles: Bool) -> Double {
        miles ? perKm * metersPerMile / 1_000 : perKm
    }

    static func storedRate(_ value: Double, miles: Bool) -> Double {
        miles ? value / (metersPerMile / 1_000) : value
    }

    static func economyUnit(miles: Bool) -> String {
        miles ? "mpg" : String(localized: "L/100 km", comment: "Fuel economy unit: liters per 100 kilometers")
    }

    static func volumeUnit(miles: Bool) -> String {
        miles ? "gal" : String(localized: "L", comment: "Unit symbol for liters")
    }
    static func distanceUnit(miles: Bool) -> String { miles ? "mi" : "km" }
}
