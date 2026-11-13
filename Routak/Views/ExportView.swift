import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Export many trips at once (GPX, KML, CSV) and import GPX files from other apps.
struct ExportView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Trip> { $0.isActive == false }, sort: \Trip.startDate)
    private var trips: [Trip]
    @AppStorage(Prefs.useMilesKey) private var useMiles = false
    @AppStorage(Prefs.fuelEconomyKey) private var fuelEconomy = 8.0
    @AppStorage(Prefs.fuelPriceKey) private var fuelPrice = 0.0
    @State private var range: ReportRange = .all
    @State private var format: TripExporter.FileFormat = .gpx
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var isExporting = false
    @State private var sharedFile: SharedFile?
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var message: (title: String, body: String)?

    static let gpxType = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)

    private var selected: [Trip] {
        guard let interval = range.interval(customStart: customStart, customEnd: customEnd) else { return trips }
        return trips.filter { interval.contains($0.startDate) }
    }

    var body: some View {
        let count = selected.count
        Form {
            Section {
                Picker("Trips", selection: $range) {
                    ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
                }
                if range == .custom {
                    DatePicker("From", selection: $customStart, in: ...Date.now, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, in: ...Date.now, displayedComponents: .date)
                }
                Picker("Format", selection: $format) {
                    ForEach(TripExporter.FileFormat.allCases) { format in
                        VStack(alignment: .leading) {
                            Text(format.title)
                            Text(format.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(format)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Button {
                    Task { await export() }
                } label: {
                    HStack {
                        Label("Export \(count) Trips", systemImage: "square.and.arrow.up")
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                }
                .disabled(count == 0 || isExporting)
            } header: {
                Text("Export")
            } footer: {
                if fuelPrice > 0 {
                    Text("GPX and KML contain the recorded GPS points of every trip. CSV lists one trip per row with distance, time, speeds, fuel cost and notes.")
                } else {
                    Text("GPX and KML contain the recorded GPS points of every trip. CSV lists one trip per row with distance, time, speeds and notes.")
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Label("Import GPX Files", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isImporting { ProgressView() }
                    }
                }
                .disabled(isImporting)
            } header: {
                Text("Import")
            } footer: {
                Text("Add drives recorded by another app or device. Each track in a file becomes a trip. Trips that are already saved are skipped.")
            }
        }
        .navigationTitle("Export & Import")
        .navigationBarTitleDisplayMode(.inline)
        .shareSheet($sharedFile)
        #if DEBUG
        // `-debugExport YES` exports every format to Documents, then re-imports the GPX (expect all duplicates).
        .task {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            // `-debugImport name.gpx` imports that file from Documents.
            if let name = UserDefaults.standard.string(forKey: "debugImport") {
                await importFiles([docs.appendingPathComponent(name)])
                return
            }
            guard UserDefaults.standard.bool(forKey: "debugExport") else { return }
            var gpx: URL?
            for format in TripExporter.FileFormat.allCases {
                self.format = format
                guard let url = try? await TripExporter.export(selected.map(ExportTrip.init), format: format, options: .init(useMiles: useMiles, fuelEconomy: fuelEconomy, fuelPrice: fuelPrice, label: "debug")) else { continue }
                let target = docs.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: url, to: target)
                if format == .gpx { gpx = target }
            }
            if let gpx { await importFiles([gpx]) }
        }
        #endif
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [Self.gpxType, .xml],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importFiles(urls) }
            case .failure(let error):
                message = (String(localized: "Couldn't open the files"), error.localizedDescription)
            }
        }
        .alert(message?.title ?? "", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message?.body ?? "")
        }
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        let snapshot = selected.map(ExportTrip.init)
        let options = TripExporter.Options(
            useMiles: useMiles,
            fuelEconomy: fuelEconomy,
            fuelPrice: fuelPrice,
            label: range.label(customStart: customStart, customEnd: customEnd)
        )
        do {
            let url = try await TripExporter.export(snapshot, format: format, options: options)
            sharedFile = SharedFile(url: url)
        } catch {
            message = (String(localized: "Couldn't create the file"), error.localizedDescription)
        }
    }

    private func importFiles(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        let result = await GPXImporter.importFiles(urls, context: context)
        GPXImporter.nameInBackground(result.trips, context: context)
        message = (result.imported > 0 ? String(localized: "Import complete") : String(localized: "Nothing imported"), result.summary)
    }
}
