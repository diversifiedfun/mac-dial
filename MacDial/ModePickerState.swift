import Foundation

enum RadialMenuAppearance: String, CaseIterable {
    case automatic, liquidGlass, classic

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .liquidGlass: return "Liquid Glass"
        case .classic: return "Classic"
        }
    }

    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func usesLiquidGlass(isSupported: Bool = Self.supportsLiquidGlass) -> Bool {
        isSupported && self != .classic
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "radialMenuAppearance") ?? "") ?? .automatic
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "radialMenuAppearance")
    }
}

enum RadialMenuStartPosition: String, CaseIterable {
    case lastSelected
    case firstItem

    static func load(from defaults: UserDefaults = .standard) -> RadialMenuStartPosition {
        let raw = defaults.string(forKey: "radialMenuStartPosition") ?? ""
        return RadialMenuStartPosition(rawValue: raw) ?? .lastSelected
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "radialMenuStartPosition")
    }
}

struct ModePickerState {
    private(set) var selectedSliceID: SliceID?
    let dial: ResolvedDial
    let application: ApplicationConfiguration?
    var isArmed = false

    var selectedSlice: SliceDefinition? { dial.clockwiseSlices.first { $0.id == selectedSliceID } }
    // Built-in compatibility for the existing test/preview callers. Runtime
    // dispatch must use selectedSliceID; an empty or custom dial isn't Scroll.
    var selectedMode: Mode { selectedSlice?.builtInMode ?? .scrolling }
    var profile: AppProfile? { AppProfile.matching(application?.bundleIdentifier) }
    var availableModes: [Mode] { dial.clockwiseSlices.compactMap(\.builtInMode) }

    init(dial: ResolvedDial, application: ApplicationConfiguration? = nil,
         selectedSliceID: SliceID?, startPosition: RadialMenuStartPosition = .lastSelected) {
        self.dial = dial
        self.application = application
        if startPosition == .lastSelected, let id = selectedSliceID, dial.contains(id) {
            self.selectedSliceID = id
        } else {
            self.selectedSliceID = dial.clockwiseSlices.first?.id
        }
    }

    init(selectedMode: Mode, profile: AppProfile? = nil,
         startPosition: RadialMenuStartPosition = .lastSelected) {
        let configuration = SliceConfiguration.builtInDefaults
        self.init(dial: configuration.resolved(for: profile?.bundleIdentifier),
                  application: configuration.applications.first { $0.bundleIdentifier == profile?.bundleIdentifier },
                  selectedSliceID: .builtIn(selectedMode), startPosition: startPosition)
    }

    @discardableResult
    mutating func select(_ mode: Mode) -> Bool {
        selectSlice(.builtIn(mode))
    }

    @discardableResult
    mutating func selectSlice(_ id: SliceID) -> Bool {
        guard dial.contains(id) else { return false }
        let changed = selectedSliceID != id
        selectedSliceID = id
        return changed
    }

    @discardableResult
    mutating func move(by steps: Int) -> Bool {
        let ids = dial.clockwiseSlices.map(\.id)
        guard !ids.isEmpty else { return false }
        let index = ids.firstIndex { $0 == selectedSliceID } ?? 0
        return selectSlice(ids[(index + steps % ids.count + ids.count) % ids.count])
    }

    @discardableResult
    mutating func rotate(_ rotation: Dial.Rotation) -> Bool {
        let count: Int
        let direction: Int
        switch rotation {
        case .Clockwise(let value): count = value; direction = 1
        case .CounterClockwise(let value): count = value; direction = -1
        }
        guard count > 0 else { return false }
        return move(by: direction * count)
    }
}
