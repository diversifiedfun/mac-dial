import Foundation

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
    private(set) var selectedMode: Mode
    let profile: AppProfile?
    let availableModes: [Mode]
    var isArmed = false

    init(selectedMode: Mode, profile: AppProfile? = nil,
         startPosition: RadialMenuStartPosition = .lastSelected) {
        self.profile = profile
        availableModes = profile?.availableModes ?? Mode.generalModes
        switch startPosition {
        case .lastSelected:
            self.selectedMode = availableModes.contains(selectedMode) ? selectedMode : .scrolling
        case .firstItem:
            self.selectedMode = availableModes.first ?? .scrolling
        }
    }

    @discardableResult
    mutating func select(_ mode: Mode) -> Bool {
        guard availableModes.contains(mode) else { return false }
        let changed = selectedMode != mode
        selectedMode = mode
        return changed
    }

    @discardableResult
    mutating func move(by steps: Int) -> Bool {
        select(selectedMode.advanced(by: steps, in: availableModes))
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
