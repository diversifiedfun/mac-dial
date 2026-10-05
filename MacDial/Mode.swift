import Foundation

enum Mode: String, CaseIterable {
    case scrolling
    case playback
    case zoom
    case undoRedo
    case lightroomCrop
    case lightroomFineTune
    case lightroomBrush
    case editwallSequence

    static let generalModes: [Mode] = [.scrolling, .playback, .zoom, .undoRedo]

    var isLightroom: Bool { AppProfile.lightroom.modes.contains(self) }

    var title: String {
        switch self {
        case .scrolling: return "Scroll"
        case .playback: return "Playback"
        case .zoom: return "Zoom"
        case .undoRedo: return "Undo/Redo"
        case .lightroomCrop: return "Crop & Browse"
        case .lightroomFineTune: return "Fine Tune"
        case .lightroomBrush: return "Remove"
        case .editwallSequence: return "Sequence"
        }
    }

    var symbolName: String {
        switch self {
        case .scrolling: return "arrow.up.arrow.down"
        case .playback: return "speaker.wave.2"
        case .zoom: return "plus.magnifyingglass"
        case .undoRedo: return "arrow.uturn.backward"
        case .lightroomCrop: return "crop"
        case .lightroomFineTune: return "slider.horizontal.3"
        case .lightroomBrush: return "paintbrush"
        case .editwallSequence: return "rectangle.stack"
        }
    }

    var turnHint: String {
        switch self {
        case .lightroomCrop: return "Turn: Previous / next"
        case .lightroomFineTune: return "Turn: Adjust − / +"
        case .lightroomBrush: return "Turn: Remove size"
        case .editwallSequence: return "Turn: Candidate ↑ / ↓"
        default: return "Turn to choose"
        }
    }

    var clickHint: String {
        switch self {
        case .lightroomCrop: return "Click: Crop (R)"
        case .lightroomFineTune: return "Click: Before (\\)"
        case .lightroomBrush: return "Click: Remove (Q)"
        case .editwallSequence: return "Click: Next slot →"
        default: return "Click to select"
        }
    }

    var usageHelp: String? {
        switch self {
        case .scrolling:
            return "Turn to scroll. Click to cycle Smooth / Stepped / Freewheel. Smooth adds a short glide; Freewheel accelerates faster turns with a longer glide for long pages. Pressing stops motion immediately. Hold to choose a mode."
        case .editwallSequence:
            return "Turn left: Up arrow, previous candidate. Turn right: Down arrow, next candidate. Click: Right arrow, next sequence slot. Double-click: Left arrow, previous sequence slot. Single clicks wait for the macOS double-click interval. Open Sequence in Editwall before using this mode."
        case .undoRedo:
            return "Turn left to undo; turn right to redo, one step per tick. Click to undo once; double-click to redo once. Single clicks wait for the macOS double-click interval. Requires Command+Z and Shift+Command+Z support in the focused app."
        case .lightroomBrush:
            return "Activate Remove before turning. With Remove inactive, turning may change photo star ratings."
        default: return nil
        }
    }

    // Preserve preferences written by earlier versions.
    var savedValue: String { self == .scrolling ? "scroll" : rawValue }

    init(savedValue: String?) {
        self = savedValue == "scroll" ? .scrolling : Mode(rawValue: savedValue ?? "") ?? .scrolling
    }

    func advanced(by steps: Int, in modes: [Mode] = Mode.generalModes) -> Mode {
        guard !modes.isEmpty else { return self }
        let index = modes.firstIndex(of: self) ?? 0
        return modes[(index + steps % modes.count + modes.count) % modes.count]
    }
}

struct AppProfile: Equatable {
    let bundleIdentifier: String
    let title: String
    let modes: [Mode]

    var availableModes: [Mode] { Mode.generalModes + modes }

    static let lightroom = AppProfile(bundleIdentifier: "com.adobe.LightroomClassicCC7",
                                     title: "Lightroom", modes: [.lightroomCrop, .lightroomFineTune, .lightroomBrush])
    static let editwall = AppProfile(bundleIdentifier: "com.editwall.desktop",
                                    title: "Editwall", modes: [.editwallSequence])

    static func matching(_ bundleIdentifier: String?) -> AppProfile? {
        [lightroom, editwall].first { $0.bundleIdentifier == bundleIdentifier }
    }
}
