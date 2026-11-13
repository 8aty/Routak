import SwiftData
import SwiftUI

// MARK: - Picker

/// A row of label chips for one trip. Each label is a colored icon; the chosen one opens up to
/// show its name. Scrolls sideways, so any number of labels fits. Ends with a button to add one.
struct LabelPicker: View {
    /// `TripLabel.key` of the chosen label, empty for none.
    let selectedKey: String
    let select: (TripLabel?) -> Void
    @State private var editing: TripLabel?
    @State private var isCreating = false

    private var book: LabelBook { LabelBook.shared }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(book.labels) { label in
                        LabelChip(label: label, isSelected: label.key == selectedKey) {
                            let choosing = label.key != selectedKey
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                select(choosing ? label : nil)
                            }
                            if choosing {
                                withAnimation(.snappy) { proxy.scrollTo(label.key, anchor: .center) }
                            }
                        }
                        .id(label.key)
                        .contextMenu {
                            Button("Edit Label", systemImage: "pencil") { editing = label }
                        }
                    }
                    addButton
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
            .onAppear {
                guard !selectedKey.isEmpty else { return }
                proxy.scrollTo(selectedKey, anchor: .center)
            }
        }
        .sensoryFeedback(.selection, trigger: selectedKey)
        .sheet(item: $editing) { label in
            LabelEditorView(label: label)
        }
        .sheet(isPresented: $isCreating) {
            LabelEditorView(label: nil) { created in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { select(created) }
            }
        }
    }

    private var addButton: some View {
        Button {
            isCreating = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: LabelChip.size, height: LabelChip.size)
                .overlay {
                    Circle().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Label")
    }
}

/// One label in the picker: a tinted circle with the icon, or a filled capsule with the name when chosen.
struct LabelChip: View {
    let label: TripLabel
    let isSelected: Bool
    let action: () -> Void

    static let size: CGFloat = 46

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: label.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22)
                if isSelected {
                    Text(label.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .foregroundStyle(isSelected ? label.foreground : label.color)
            .padding(.horizontal, isSelected ? 14 : 0)
            .frame(minWidth: Self.size, minHeight: Self.size)
            .background(isSelected ? AnyShapeStyle(label.color.gradient) : AnyShapeStyle(label.color.opacity(0.16)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small colored label tag, for trip cards and lists.
struct LabelBadge: View {
    let label: TripLabel

    var body: some View {
        Label(label.title, systemImage: label.symbol)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(label.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(label.color.gradient, in: Capsule())
    }
}

/// The label's icon in a round colored tile, for lists and menus.
struct LabelIcon: View {
    let label: TripLabel
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: label.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(label.foreground)
            .frame(width: size, height: size)
            .background(label.color.gradient, in: Circle())
    }
}

// MARK: - Editor

/// Creates or edits a label: name, color and icon, with a live preview.
struct LabelEditorView: View {
    /// Nil to create a new label.
    let label: TripLabel?
    var onCreate: ((TripLabel) -> Void)?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "tag.fill"
    @State private var color: LabelColor = .blue
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    private static let maxNameLength = 24

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onChange(of: name) { _, value in
                            if value.count > Self.maxNameLength { name = String(value.prefix(Self.maxNameLength)) }
                        }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 12) {
                        ForEach(LabelColor.allCases) { option in
                            Button {
                                withAnimation(.snappy) { color = option }
                            } label: {
                                Circle()
                                    .fill(option.color.gradient)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if option == color {
                                            Circle().strokeBorder(.background, lineWidth: 3)
                                            Circle().strokeBorder(option.color, lineWidth: 2).padding(-4)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: option.rawValue))
                            .accessibilityAddTraits(option == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(LabelSymbols.all, id: \.self) { option in
                            let chosen = option == symbol
                            Button {
                                withAnimation(.snappy) { symbol = option }
                            } label: {
                                Image(systemName: option)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(chosen ? color.foreground : Color.primary.opacity(0.75))
                                    .frame(width: 44, height: 44)
                                    .background(chosen ? AnyShapeStyle(color.color.gradient) : AnyShapeStyle(.fill.tertiary), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }

                if label != nil {
                    Section {
                        Button("Delete Label", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Trips with this label become unlabeled.")
                    }
                }
            }
            .navigationTitle(label == nil ? "New Label" : "Edit Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(label == nil ? "Add" : "Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog("Delete this label?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Label", role: .destructive) {
                    if let label { LabelBook.delete(label, context: context) }
                    dismiss()
                }
            } message: {
                Text("Trips with this label become unlabeled.")
            }
            .onAppear(perform: load)
        }
    }

    /// How the label will look when chosen on a trip.
    private var preview: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
            Text(trimmedName.isEmpty ? String(localized: "Label") : trimmedName)
                .font(.headline)
                .lineLimit(1)
        }
        .foregroundStyle(color.foreground)
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
        .background(color.color.gradient, in: Capsule())
        .contentTransition(.symbolEffect(.replace))
        .padding(.vertical, 4)
    }

    private func load() {
        if let label {
            name = label.title
            symbol = label.symbol
            color = label.labelColor
        } else {
            // A color not used yet, so new labels are easy to tell apart.
            let used = Set(LabelBook.shared.labels.map(\.colorName))
            color = LabelColor.allCases.first { !used.contains($0.rawValue) } ?? .blue
            nameFocused = true
        }
    }

    private func save() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        if let label {
            // A starter label keeps following the phone's language until it's actually renamed.
            if name != label.title { label.name = name }
            label.symbol = symbol
            label.labelColor = color
            try? context.save()
        } else {
            let order = (LabelBook.shared.labels.map(\.sortOrder).max() ?? -1) + 1
            let created = TripLabel(name: name, symbol: symbol, color: color, sortOrder: order)
            context.insert(created)
            try? context.save()
            LabelBook.shared.refresh(context: context)
            onCreate?(created)
        }
        dismiss()
    }
}

// MARK: - Settings list

/// All labels: reorder, edit, delete and add.
struct LabelsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Trip> { $0.isActive == false && $0.categoryRaw != "" }) private var labeledTrips: [Trip]
    @State private var editing: TripLabel?
    @State private var isCreating = false
    @State private var pendingDelete: TripLabel?

    private var book: LabelBook { LabelBook.shared }

    var body: some View {
        let counts = Dictionary(grouping: labeledTrips, by: \.categoryRaw).mapValues(\.count)
        List {
            Section {
                ForEach(book.labels) { label in
                    Button {
                        editing = label
                    } label: {
                        HStack(spacing: 12) {
                            LabelIcon(label: label)
                            Text(label.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(verbatim: "\(counts[label.key] ?? 0)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = label }
                    }
                }
                .onMove { from, to in
                    var labels = book.labels
                    labels.move(fromOffsets: from, toOffset: to)
                    LabelBook.reorder(labels, context: context)
                }

                Button {
                    isCreating = true
                } label: {
                    Label("New Label", systemImage: "plus")
                }
            } footer: {
                Text("Label trips on their page or by touching and holding them in History. Labels show up in History filters, Stats and the mileage log.")
            }
        }
        .navigationTitle("Labels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editing) { LabelEditorView(label: $0) }
        .sheet(isPresented: $isCreating) { LabelEditorView(label: nil) }
        .confirmationDialog(
            "Delete this label?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { label in
            Button("Delete Label", role: .destructive) {
                withAnimation { LabelBook.delete(label, context: context) }
            }
        } message: { _ in
            Text("Trips with this label become unlabeled.")
        }
    }
}
