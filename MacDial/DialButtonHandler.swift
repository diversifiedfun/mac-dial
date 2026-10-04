import Foundation

enum MenuPressDuration: Int, CaseIterable {
    case ms200 = 200
    case ms300 = 300
    case ms400 = 400
    case ms500 = 500
    case ms600 = 600

    var seconds: TimeInterval { Double(rawValue) / 1000 }

    static func load(from defaults: UserDefaults = .standard) -> MenuPressDuration {
        MenuPressDuration(rawValue: defaults.integer(forKey: "menuPressDuration")) ?? .ms600
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "menuPressDuration")
    }
}

// Main-queue gesture recognition, independent of controller actions.
// Nothing posts mouse/key down until a short press has been recognized.
final class DialButtonHandler {
    var menuPressDuration: MenuPressDuration = .ms600

    var onShortPress: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onLongPressRelease: (() -> Void)?
    private(set) var longPressActive = false
    var isPressed: Bool { pressStart != nil }
    private var pressStart: TimeInterval?
    private var pressThreshold: TimeInterval = MenuPressDuration.ms600.seconds
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

    func pressed(at timestamp: TimeInterval? = nil) {
        guard pressStart == nil else { return }
        generation += 1
        let currentGeneration = generation
        let start = timestamp ?? now()
        pressStart = start
        // Keep the timer and release classification consistent if the setting
        // changes while the Dial is held. The next press uses the new duration.
        pressThreshold = menuPressDuration.seconds
        longPressActive = false

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == currentGeneration else { return }
            self.fireLongPress()
        }
        timer = work
        schedule(max(0, pressThreshold - (now() - start)), work)
    }

    func advance(at timestamp: TimeInterval? = nil) {
        if let start = pressStart, (timestamp ?? now()) - start >= pressThreshold {
            fireLongPress()
        }
    }

    func released(at timestamp: TimeInterval? = nil) {
        guard isPressed else { return }
        let currentGeneration = generation
        // A busy main queue may deliver release before its overdue timer.
        advance(at: timestamp)
        // A long-press callback may cancel this gesture while closing a menu.
        guard generation == currentGeneration else { return }
        let callback = longPressActive ? onLongPressRelease : onShortPress
        clear()
        callback?()
    }

    func cancel() {
        clear()
    }

    private func fireLongPress() {
        guard pressStart != nil, !longPressActive else { return }
        timer?.cancel()
        timer = nil
        longPressActive = true
        onLongPress?()
    }

    private func clear() {
        timer?.cancel()
        timer = nil
        generation += 1
        pressStart = nil
        longPressActive = false
    }
}
