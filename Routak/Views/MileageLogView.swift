import SwiftData
import SwiftUI

/// Builds a mileage log for expenses or taxes and exports it as PDF or CSV.
struct MileageLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate)
    private var trips: [Trip]
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.mileageRateKey) private var ratePerKm = 0.0
    @AppStorage("mileageLogRange") private var range: ReportRange = .thisMonth
    @AppStorage("mileageLogInclude") private var include: Include = .work
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var sharedFile: SharedFile?
    @State private var errorMessage: String?

    enum Include: String, CaseIterable, Identifiable {
        case work, workAndCommute, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .work: String(localized: "Work trips")
            case .workAndCommute: String(localized: "Work and commute")
            case .all: String(localized: "All trips")
            }
        }

        func includes(_ trip: Trip) -> Bool {
            switch self {
            case .work: trip.category == .work
            case .workAndCommute: trip.category == .work || trip.category == .commute
            case .all: true
            }
        }
    }

    private var log: MileageLog {
        let interval = range.interval(customStart: customStart, customEnd: customEnd)
        let selected = trips.filter { trip in
            (interval?.contains(trip.startDate) ?? true) && include.includes(trip)
        }
        return MileageLog(
            entries: selected.map(MileageLog.entry(for:)),
            periodLabel: range.label(customStart: customStart, customEnd: customEnd),
            useMiles: useMiles,
            ratePerKm: ratePerKm
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { (Costs.displayRate(ratePerKm, miles: useMiles) * 1_000).rounded() / 1_000 },
            set: { ratePerKm = Costs.storedRate(max($0, 0), miles: useMiles) }
        )
    }

    var body: some View {
        let log = log
        NavigationStack {
            Form {
                Section {
                    Picker("Period", selection: $range) {
                        ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
                    }
                    if range == .custom {
                        DatePicker("From", selection: $customStart, in: ...Date.now, displayedComponents: .date)
                        DatePicker("To", selection: $customEnd, in: ...Date.now, displayedComponents: .date)
                    }
                    Picker("Include", selection: $include) {
                        ForEach(Include.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Rate per \(Costs.distanceUnit(miles: useMiles))") {
                        TextField("0.00", value: rateBinding, format: .currency(code: Costs.currencyCode))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text(include == .all
                         ? "Every saved trip in the period is listed."
                         : "Label trips as Work in History or on a trip's page to include them. Commuting usually isn't deductible.")
                }

                Section("Summary") {
                    LabeledContent("Trips", value: "\(log.entries.count)")
                    LabeledContent("Distance", value: Format.distance(log.totalMeters, miles: useMiles))
                    LabeledContent("Amount") {
                        Text(Costs.money(log.totalAmount))
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }

                Section {
                    Button {
                        share { try log.pdf() }
                    } label: {
                        Label("Export PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        share { try log.csv() }
                    } label: {
                        Label("Export CSV", systemImage: "tablecells")
                    }
                }
                .disabled(log.entries.isEmpty)

                if !log.entries.isEmpty {
                    Section("Trips") {
                        ForEach(log.entries.reversed()) { entry in
                            entryRow(entry, log: log)
                        }
                    }
                }
            }
            .navigationTitle("Mileage Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .shareSheet($sharedFile)
            #if DEBUG
            // `-debugExport YES` writes the PDF and CSV to Documents (for checking the layout).
            .onAppear {
                guard UserDefaults.standard.bool(forKey: "debugExport") else { return }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                for url in [try? log.pdf(), try? log.csv()].compactMap({ $0 }) {
                    let target = docs.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.copyItem(at: url, to: target)
                }
            }
            #endif
            .alert("Couldn't create the file", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func entryRow(_ entry: MileageLog.Entry, log: MileageLog) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.subheadline.weight(.semibold))
                Text(route(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !entry.purpose.isEmpty {
                    Text(entry.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.distance(entry.meters, miles: useMiles))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if log.ratePerKm > 0 {
                    Text(Costs.money(log.amount(entry.meters)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func route(_ entry: MileageLog.Entry) -> String {
        switch (entry.from.isEmpty, entry.to.isEmpty) {
        case (false, false): "\(entry.from) → \(entry.to)"
        case (false, true): String(localized: "From \(entry.from)", comment: "Trip title when only the start place is known")
        case (true, false): String(localized: "To \(entry.to)", comment: "Trip title when only the end place is known")
        default: String(localized: "Drive", comment: "Title of a trip with no known places")
        }
    }

    private func share(_ make: () throws -> URL) {
        do {
            sharedFile = SharedFile(url: try make())
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
