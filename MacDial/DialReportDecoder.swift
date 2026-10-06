import Foundation

// Surface Dial input report 1, verified against the connected device's HID
// descriptor: one byte of button/touch bits, followed by a signed little-endian
// 16-bit relative Dial value. Screen-contact fields can follow those bytes.
// Keep this independent of HID I/O so actual wire reports are covered by tests.
enum DialReportDecoder {
    static func decode(_ bytes: [UInt8]) -> (button: Dial.ButtonState, rotation: Dial.Rotation?)? {
        guard bytes.count >= 4, bytes[0] == 1 else { return nil }
        let button: Dial.ButtonState = bytes[1] & 1 == 1 ? .pressed : .released
        let bits = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        // Widen before negating so the most-negative Int16 cannot overflow.
        let ticks = Int(Int16(bitPattern: bits))
        let rotation: Dial.Rotation?
        if ticks > 0 { rotation = .Clockwise(ticks) }
        else if ticks < 0 { rotation = .CounterClockwise(-ticks) }
        else { rotation = nil }
        return (button, rotation)
    }
}

// HIDAPI uses 32-bit wchar_t strings on macOS. Keep reads bounded and reject
// failed or invalid strings; this is independent of hardware for regression tests.
enum DialHIDString {
    static func read(_ read: (UnsafeMutablePointer<wchar_t>, Int) -> Int32) -> String {
        var buffer = [wchar_t](repeating: 0, count: 255)
        let result = buffer.withUnsafeMutableBufferPointer { read($0.baseAddress!, $0.count) }
        guard result == 0 else { return "" }
        let count = buffer.firstIndex(of: 0) ?? buffer.count
        return buffer.withUnsafeBytes { bytes in
            String(bytes: bytes.prefix(count * MemoryLayout<wchar_t>.stride), encoding: .utf32LittleEndian) ?? ""
        }
    }
}
