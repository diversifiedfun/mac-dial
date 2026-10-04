import Foundation

struct ModePickerState {
    private(set) var selectedMode: Mode
    var isArmed = false
    private var accumulatedSteps = 0.0

    init(selectedMode: Mode) { self.selectedMode = selectedMode }

    @discardableResult
    mutating func select(_ mode: Mode) -> Bool {
        accumulatedSteps = 0
        let changed = selectedMode != mode
        selectedMode = mode
        return changed
    }

    @discardableResult
    mutating func move(by steps: Int) -> Bool {
        select(selectedMode.advanced(by: steps))
    }

    @discardableResult
    mutating func rotate(_ rotation: Dial.Rotation, sensitivity: Int) -> Bool {
        guard sensitivity > 0 else { return false }
        let count: Int
        let direction: Double
        switch rotation {
        case .Clockwise(let value): count = value; direction = 1
        case .CounterClockwise(let value): count = value; direction = -1
        }
        guard count > 0 else { return false }
        // HID sensitivity is ticks/revolution. Twelve selection steps per
        // revolution gives ~30 degrees without reconfiguring the device.
        accumulatedSteps += direction * Double(count) * 12 / Double(sensitivity)
        let wholeSteps = Int((abs(accumulatedSteps) + 1e-9).rounded(.down))
        guard wholeSteps > 0 else { return false }
        let signedSteps = accumulatedSteps < 0 ? -wholeSteps : wholeSteps
        accumulatedSteps -= Double(signedSteps)
        selectedMode = selectedMode.advanced(by: signedSteps)
        return true
    }
}
