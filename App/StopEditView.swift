import SwiftUI
import MapKit
import GigCore

/// ✏️ Edit a stop: its name (store or customer) and its full address, with address suggestions
/// like "Add a stop by hand". Return / Done on the keyboard puts the keyboard away.
struct StopEditView: View {
    let stop: Stop
    let onSave: (_ name: String, _ address: String, _ location: Coord?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = AddressCompleter()
    @State private var name: String
    @State private var address: String
    @State private var picked: Coord?          // set when a suggestion is chosen
    @State private var message: String?
    @State private var saving = false
    @FocusState private var field: Field?
    private enum Field { case name, address }
    private let originalAddress: String

    init(stop: Stop, onSave: @escaping (_ name: String, _ address: String, _ location: Coord?) -> Void) {
        self.stop = stop
        self.onSave = onSave
        let parts = stop.nameAndAddress
        _name = State(initialValue: parts.name)
        _address = State(initialValue: parts.address ?? "")
        originalAddress = parts.address ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(stop.type == .pickup ? "Store name" : "Customer name") {
                    TextField("Name", text: $name)
                        .focused($field, equals: .name)
                        .submitLabel(.done)
                        .onSubmit { field = nil }
                }
                Section {
                    TextField("Full address", text: $address)
                        .focused($field, equals: .address)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { field = nil }
                        .onChange(of: address) { _, q in
                            if picked != nil, q == pickedText { return } // just filled in from a suggestion
                            picked = nil
                            completer.update(query: q, near: SharedStore.shared.currentLocation ?? stop.location)
                        }
                    if picked == nil, field == .address {
                        ForEach(completer.results, id: \.self) { item in
                            Button { choose(item) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).foregroundStyle(.primary)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if picked != nil {
                        Label("Location found", systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(.green)
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text("Start typing to search, then pick a suggestion so the pin lands in the right spot. A typed address is looked up when you save.")
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit stop")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { save() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { field = nil }.fontWeight(.semibold)
                }
            }
        }
    }

    @State private var pickedText = ""

    private func choose(_ item: MKLocalSearchCompletion) {
        Task {
            guard let found = await completer.resolve(item) else {
                message = "Couldn't find that place. Try another suggestion."
                return
            }
            pickedText = found.label
            picked = found.coord
            address = found.label
            message = nil
            field = nil
        }
    }

    private func save() {
        field = nil
        let newName = name.trimmingCharacters(in: .whitespaces)
        let newAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // Address unchanged (or chosen from a suggestion): save right away.
        if let picked { onSave(newName, newAddress, picked); dismiss(); return }
        if newAddress == originalAddress || newAddress.isEmpty { onSave(newName, newAddress, nil); dismiss(); return }
        // Typed by hand: find it on the map so the pin moves too.
        saving = true
        Task {
            let found = await PlaceFinder.find(newAddress, near: stop.location)
            saving = false
            if let found {
                onSave(newName, newAddress, found)
                dismiss()
            } else {
                message = "Couldn't find “\(newAddress)” on the map. Pick a suggestion while typing, or check the address."
            }
        }
    }
}
