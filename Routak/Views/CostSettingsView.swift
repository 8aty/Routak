import SwiftUI

/// Fuel economy, fuel price and mileage rate, shown in the user's units and stored in metric.
struct CostSettingsView: View {
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.fuelEconomyKey) private var fuelEconomy = 8.0
    @AppStorage(Prefs.fuelPriceKey) private var fuelPrice = 0.0
    @AppStorage(Prefs.mileageRateKey) private var ratePerKm = 0.0

    private var economyBinding: Binding<Double> {
        Binding(
            get: { (Costs.displayEconomy(fuelEconomy, miles: useMiles) * 10).rounded() / 10 },
            set: { fuelEconomy = Costs.storedEconomy(max($0, 0), miles: useMiles) }
        )
    }

    private var priceBinding: Binding<Double> {
        Binding(
            get: { (Costs.displayPrice(fuelPrice, miles: useMiles) * 1_000).rounded() / 1_000 },
            set: { fuelPrice = Costs.storedPrice(max($0, 0), miles: useMiles) }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { (Costs.displayRate(ratePerKm, miles: useMiles) * 1_000).rounded() / 1_000 },
            set: { ratePerKm = Costs.storedRate(max($0, 0), miles: useMiles) }
        )
    }

    /// 20 km or 10 mi: a typical drive for the example line.
    private var exampleMeters: Double { useMiles ? 10 * Costs.metersPerMile : 20_000 }

    var body: some View {
        Form {
            Section {
                LabeledContent("Fuel economy") {
                    HStack(spacing: 4) {
                        TextField("0", value: economyBinding, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text(Costs.economyUnit(miles: useMiles)).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Fuel price") {
                    HStack(spacing: 4) {
                        TextField("0.00", value: priceBinding, format: .currency(code: Costs.currencyCode))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text(verbatim: "/ \(Costs.volumeUnit(miles: useMiles))").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Fuel")
            } footer: {
                if let cost = Costs.fuelCost(for: exampleMeters, economy: fuelEconomy, price: fuelPrice) {
                    Text("A \(Format.distance(exampleMeters, miles: useMiles)) drive uses about \(Costs.money(cost)) of fuel. Estimates appear on each trip and in Stats.")
                } else {
                    Text("Enter a fuel price to see estimated fuel costs on each trip and in Stats.")
                }
            }

            Section {
                LabeledContent("Rate per \(Costs.distanceUnit(miles: useMiles))") {
                    TextField("0.00", value: rateBinding, format: .currency(code: Costs.currencyCode))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Mileage log")
            } footer: {
                Text("Used for the mileage log's amounts, e.g. your employer's reimbursement rate or the tax authority's standard rate.")
            }
        }
        .navigationTitle("Fuel & Mileage")
        .navigationBarTitleDisplayMode(.inline)
    }
}
