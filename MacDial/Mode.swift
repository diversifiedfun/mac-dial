import Foundation

enum Mode: String, CaseIterable {
    case scrolling
    case playback
    case zoom

    var title: String {
        switch self {
        case .scrolling: return "Scroll"
        case .playback: return "Playback"
        case .zoom: return "Zoom"
        }
    }

    var symbolName: String {
        switch self {
        case .scrolling: return "arrow.up.arrow.down"
        case .playback: return "speaker.wave.2"
        case .zoom: return "plus.magnifyingglass"
        }
    }

    // Preserve preferences written by earlier versions.
    var savedValue: String { self == .scrolling ? "scroll" : rawValue }

    init(savedValue: String?) {
        self = savedValue == "scroll" ? .scrolling : Mode(rawValue: savedValue ?? "") ?? .scrolling
    }

    func advanced(by steps: Int) -> Mode {
        let modes = Self.allCases
        let index = modes.firstIndex(of: self)!
        return modes[(index + steps % modes.count + modes.count) % modes.count]
    }
}
