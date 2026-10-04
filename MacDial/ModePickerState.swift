import Foundation

struct ModePickerState {
    private(set) var selectedMode: Mode
    let profile: AppProfile?
    let availableModes: [Mode]
    var isArmed = false

    init(selectedMode: Mode, profile: AppProfile? = nil) {
        self.profile = profile
        availableModes = profile?.availableModes ?? Mode.generalModes
        self.selectedMode = availableModes.contains(selectedMode) ? selectedMode : .scrolling
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
