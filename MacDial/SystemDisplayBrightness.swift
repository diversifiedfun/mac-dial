import AppKit
import Darwin

struct BrightnessDisplay: Equatable {
    let id: CGDirectDisplayID
    let identifier: String
}

protocol DisplayBrightnessAccess {
    func preferredDisplay() -> BrightnessDisplay?
    func display(identifier: String) -> BrightnessDisplay?
    func brightness(of display: BrightnessDisplay) -> Float?
    func setBrightness(_ level: Float, for display: BrightnessDisplay) -> Bool
}

final class SystemDisplayBrightness: DisplayBrightnessAccess {
    static let shared = SystemDisplayBrightness()
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (UInt32) -> Bool
    private let framework: UnsafeMutableRawPointer?
    private let get: GetBrightness?
    private let set: SetBrightness?
    private let canChange: CanChangeBrightness?

    private init() {
        // DisplayServices supports native brightness on Apple Silicon. It is
        // private SPI, loaded optionally so an OS change cannot prevent launch.
        // Signatures: https://github.com/nriley/brightness/blob/master/brightness.c
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        framework = handle
        get = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightness.self) }
        set = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightness.self) }
        canChange = handle.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }
            .map { unsafeBitCast($0, to: CanChangeBrightness.self) }
    }

    deinit { if let framework = framework { dlclose(framework) } }

    func preferredDisplay() -> BrightnessDisplay? {
        let candidates = activeDisplays()
        let regions: [(display: BrightnessDisplay, frame: NSRect)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = candidates.first(where: { $0.id == number.uint32Value }) else { return nil }
            return (display, screen.frame)
        }
        guard let display = Self.display(at: NSEvent.mouseLocation, in: regions),
              canChange?(display.id) == true else { return nil }
        return display
    }

    // Use AppKit coordinates for both the pointer and frames, including monitors
    // left of or above the main display. Never fall back to a different screen.
    static func display(at point: NSPoint, in regions: [(display: BrightnessDisplay, frame: NSRect)]) -> BrightnessDisplay? {
        regions.first { $0.frame.contains(point) }?.display
    }

    func display(identifier: String) -> BrightnessDisplay? {
        activeDisplays().first { $0.identifier == identifier }
    }

    func brightness(of display: BrightnessDisplay) -> Float? {
        guard let get = get, set != nil, isCurrent(display), canChange?(display.id) == true else { return nil }
        var level: Float = 0
        guard get(display.id, &level) == 0, level.isFinite, (0...1).contains(level) else { return nil }
        return level
    }

    func setBrightness(_ level: Float, for display: BrightnessDisplay) -> Bool {
        guard level.isFinite, (0...1).contains(level), let set = set,
              isCurrent(display), canChange?(display.id) == true else { return false }
        return Self.verifiedWrite(level, write: { set(display.id, level) == 0 },
                                  read: { self.brightness(of: display) })
    }

    // Some displays report success for writes they ignore. Do not discard the
    // restore value based on that status alone. Allow only minor float rounding.
    static func verifiedWrite(_ level: Float, write: () -> Bool, read: () -> Float?) -> Bool {
        guard level.isFinite, (0...1).contains(level), write(),
              let actual = read(), actual.isFinite, (0...1).contains(actual) else { return false }
        return abs(actual - level) <= 0.001
    }

    private func isCurrent(_ display: BrightnessDisplay) -> Bool {
        activeDisplays().contains(display)
    }

    private func activeDisplays() -> [BrightnessDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let identifier = CFUUIDCreateString(nil, uuid) else { return nil }
            return BrightnessDisplay(id: id, identifier: identifier as String)
        }
    }
}
