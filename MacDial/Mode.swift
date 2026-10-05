import Foundation

enum Mode: String, CaseIterable {
    case scrolling
    case playback
    case zoom
    case lightroomCrop
    case lightroomFineTune
    case lightroomBrush

    static let generalModes: [Mode] = [.scrolling, .playback, .zoom]

    var isLightroom: Bool { AppProfile.lightroom.modes.contains(self) }

    var title: String {
        switch self {
        case .scrolling: return "Scroll"
        case .playback: return "Playback"
        case .zoom: return "Zoom"
        case .lightroomCrop: return "Crop & Browse"
        case .lightroomFineTune: return "Fine Tune"
        case .lightroomBrush: return "Remove"
        }
    }

    var symbolName: String {
        switch self {
        case .scrolling: return "arrow.up.arrow.down"
        case .playback: return "speaker.wave.2"
        case .zoom: return "plus.magnifyingglass"
        case .lightroomCrop: return "crop"
        case .lightroomFineTune: return "slider.horizontal.3"
        case .lightroomBrush: return "paintbrush"
        }
    }

    var turnHint: String {
        switch self {
        case .lightroomCrop: return "Turn: Previous / next"
        case .lightroomFineTune: return "Turn: Adjust − / +"
        case .lightroomBrush: return "Turn: Remove size"
        default: return "Turn to choose"
        }
    }

    var clickHint: String {
        switch self {
        case .lightroomCrop: return "Click: Crop (R)"
        case .lightroomFineTune: return "Click: Before (\\)"
        case .lightroomBrush: return "Click: Remove (Q)"
        default: return "Click to select"
        }
    }

    var usageHelp: String? {
        guard self == .lightroomBrush else { return nil }
        return "Activate Remove before turning. With Remove inactive, turning may change photo star ratings."
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
    static func matching(_ bundleIdentifier: String?) -> AppProfile? {
        [lightroom].first { $0.bundleIdentifier == bundleIdentifier }
    }
}
