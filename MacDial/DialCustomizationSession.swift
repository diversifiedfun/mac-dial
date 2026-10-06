import Foundation

// Window-owned editing state. Preview selection never writes a runtime selection.
final class DialCustomizationSession {
    let store: SliceConfigurationStore
    let undoManager = UndoManager()
    private(set) var context: String?
    var selectedID: SliceID?
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(store: SliceConfigurationStore) {
        self.store = store
        selectedID = store.configuration.standardSlices.first?.id
    }

    var application: ApplicationConfiguration? { store.configuration.applications.first { $0.id == context } }
    var slices: [SliceDefinition] { application?.slices ?? store.configuration.standardSlices }
    var resolved: ResolvedDial { store.configuration.resolved(for: context) }
    var selected: SliceDefinition? {
        (store.configuration.standardSlices + (application?.slices ?? [])).first { $0.id == selectedID }
    }
    var isReadOnly: Bool {
        if case .unsupportedVersion = store.loadStatus { return true }
        return false
    }

    func selectContext(_ id: String?) {
        context = id
        selectedID = slices.first?.id
        onChange?()
    }

    func selectSlice(_ id: SliceID) { selectedID = id; onChange?() }

    private struct EditLocation {
        let context: String?
        let sliceID: SliceID?
        let row: Int?
    }

    private func location(of id: SliceID, in configuration: SliceConfiguration) -> EditLocation {
        if let row = configuration.standardSlices.firstIndex(where: { $0.id == id }) {
            return EditLocation(context: nil, sliceID: id, row: row)
        }
        for app in configuration.applications {
            if let row = app.slices.firstIndex(where: { $0.id == id }) {
                return EditLocation(context: app.id, sliceID: id, row: row)
            }
        }
        return EditLocation(context: context, sliceID: id, row: nil)
    }

    private func reveal(_ location: EditLocation) {
        context = store.configuration.applications.contains { $0.id == location.context } ? location.context : nil
        if slices.contains(where: { $0.id == location.sliceID }) {
            selectedID = location.sliceID
        } else {
            // Undoing an addition or redoing a deletion leaves no target slice.
            // Show its former position, or the empty group if nothing remains.
            let row = min(location.row ?? 0, slices.count - 1)
            selectedID = row >= 0 ? slices[row].id : nil
        }
    }

    private func apply(_ candidate: SliceConfiguration, name: String, location: EditLocation, revealChange: Bool = false) {
        let previous = store.configuration
        guard !candidate.hasSameContent(as: previous) else { return }
        do {
            try store.replace(with: candidate)
            undoManager.registerUndo(withTarget: self) { $0.restore(previous, name: name, location: location) }
            undoManager.setActionName(name)
            if revealChange { reveal(location) }
            onChange?()
        } catch { onError?(error) }
    }

    private func restore(_ saved: SliceConfiguration, name: String, location: EditLocation) {
        var candidate = saved
        // Undo content edits without rewinding selections made by live input.
        candidate.selectedStandardSliceID = store.configuration.selectedStandardSliceID
        for index in candidate.applications.indices {
            if let current = store.configuration.applications.first(where: { $0.id == candidate.applications[index].id }) {
                candidate.applications[index].selectedSliceID = current.selectedSliceID
            }
        }
        apply(candidate, name: name, location: location, revealChange: true)
    }

    func update(_ id: SliceID, name: String, _ change: (inout SliceDefinition) -> Void) {
        var candidate = store.configuration
        if let index = candidate.standardSlices.firstIndex(where: { $0.id == id }) {
            change(&candidate.standardSlices[index])
        } else if let app = candidate.applications.firstIndex(where: { $0.slices.contains { $0.id == id } }),
                  let index = candidate.applications[app].slices.firstIndex(where: { $0.id == id }) {
            change(&candidate.applications[app].slices[index])
        }
        apply(candidate, name: name, location: location(of: id, in: candidate))
    }

    func updateCustom(_ id: SliceID, name: String, _ change: (inout CustomSlice) -> Void) {
        update(id, name: name) { slice in
            guard case .custom(var custom) = slice.content else { return }
            let previousName = custom.name
            change(&custom)
            if custom.name != previousName {
                custom.name = String(custom.name.prefix(CustomSlice.maximumNameLength))
            }
            slice.content = .custom(custom)
        }
    }

    private func editList(name: String, affectedID: SliceID, _ change: (inout [SliceDefinition]) -> Void) {
        var candidate = store.configuration
        if let app = candidate.applications.firstIndex(where: { $0.id == context }) {
            change(&candidate.applications[app].slices)
        } else { change(&candidate.standardSlices) }
        apply(candidate, name: name, location: location(of: affectedID, in: candidate))
    }

    func addSlice() {
        let slice = SliceDefinition.custom()
        selectedID = slice.id
        editList(name: "Add Slice", affectedID: slice.id) { $0.append(slice) }
    }

    func deleteSelected() {
        guard let selected = selected, selected.id.isCustom else { return }
        // A preview can select a standard slice while an app remains selected.
        var candidate = store.configuration
        candidate.standardSlices.removeAll { $0.id == selected.id }
        for index in candidate.applications.indices { candidate.applications[index].slices.removeAll { $0.id == selected.id } }
        let editedLocation = location(of: selected.id, in: store.configuration)
        selectedID = nil
        apply(candidate, name: "Delete Slice", location: editedLocation)
    }

    func move(_ id: SliceID, to destination: Int) {
        guard let source = slices.firstIndex(where: { $0.id == id }), !slices.isEmpty else { return }
        let target = max(0, min(destination, slices.count - 1))
        guard source != target else { return }
        editList(name: "Reorder Slices", affectedID: id) { list in
            let slice = list.remove(at: source)
            list.insert(slice, at: target)
        }
    }

    func removeApplication(_ id: String) {
        guard !isReadOnly,
              let app = store.configuration.applications.first(where: { $0.id == id }) else { return }
        let editedID = app.slices.contains(where: { $0.id == selectedID }) ? selectedID : app.slices.first?.id
        let editedLocation = EditLocation(context: id, sliceID: editedID,
            row: app.slices.firstIndex { $0.id == editedID })
        var candidate = store.configuration
        candidate.applications.removeAll { $0.id == id }
        // Reveal after a successful save: removal selects Standard, while Undo
        // restores and reveals this app, including its original slice selection.
        apply(candidate, name: "Remove Application", location: editedLocation, revealChange: true)
    }

    func addApplication(_ app: ApplicationConfiguration) {
        if store.configuration.applications.contains(where: { $0.id == app.id }) { selectContext(app.id); return }
        guard !isReadOnly else { return }
        var fresh = app
        // Add Application is a fresh configuration. Only Undo restores removed
        // custom actions, switches and ordering.
        fresh.slices = AppProfile.matching(app.id)?.modes.map(SliceDefinition.builtIn) ?? []
        fresh.selectedSliceID = nil
        var candidate = store.configuration
        candidate.applications.append(fresh)
        apply(candidate, name: "Add Application",
            location: EditLocation(context: fresh.id, sliceID: fresh.slices.first?.id, row: 0), revealChange: true)
    }
}
