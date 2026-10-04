import Foundation

// Used on the main queue. Keep the controller that received down until the
// gesture ends, so a mode change cannot deliver up to a different controller.
final class DialButtonHandler {
    static let longPressThreshold: TimeInterval = 0.6

    var onLongPress: (() -> Void)?
    private(set) var longPressActive = false
    private var pressedController: Controller?
    private var pressStart: TimeInterval?
    private var timer: DispatchWorkItem?
    private var generation = 0
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         }) {
        self.now = now
        self.schedule = schedule
    }

    deinit { timer?.cancel() }

    func pressed(controller: Controller) {
        guard pressStart == nil else { return }
        generation += 1
        let currentGeneration = generation
        pressStart = now()
        pressedController = controller
        longPressActive = false
        controller.onDown()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == currentGeneration else { return }
            self.fireLongPress()
        }
        timer = work
        schedule(Self.longPressThreshold, work)
    }

    func released() {
        guard let start = pressStart else { return }
        // A busy main queue may deliver release before its overdue timer.
        if now() - start >= Self.longPressThreshold {
            fireLongPress()
        }
        if !longPressActive { pressedController?.onUp() }
        clear()
    }

    func cancel() {
        pressedController?.onCancel()
        clear()
    }

    private func fireLongPress() {
        guard pressStart != nil, !longPressActive else { return }
        timer?.cancel()
        timer = nil
        longPressActive = true
        pressedController?.onCancel()
        pressedController = nil
        onLongPress?()
    }

    private func clear() {
        timer?.cancel()
        timer = nil
        generation += 1
        pressedController = nil
        pressStart = nil
        longPressActive = false
    }
}
