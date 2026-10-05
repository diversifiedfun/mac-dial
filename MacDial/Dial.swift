
import Foundation
import AppKit
import Cocoa
import SwiftUI

extension NSString {
    convenience init(wcharArray: UnsafeMutablePointer<wchar_t>) {
        self.init(bytes: UnsafePointer(wcharArray),
                        length: wcslen(wcharArray) * MemoryLayout<wchar_t>.stride,
                        encoding: String.Encoding.utf32LittleEndian.rawValue)!
    }
}

class Dial
{
    enum ButtonState {
        case pressed
        case released
    }
    
    enum Rotation {
        case Clockwise (Int)
        case CounterClockwise (Int)
    }
    
    enum InputReport
    {
        case dial(ButtonState, Rotation?)
        case unknown
    }
    
    class Device
    {
        private struct ReadBuffer {
            let pointer: UnsafeMutablePointer<UInt8>
            let size: Int
            init(size: Int) {
                self.size = size
                pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            }
        }
        
        // Identifiers for the Surface Dial
        static let VendorId: UInt16 = 0x045E
        static let ProductId: UInt16 = 0x091B
        private var dev: OpaquePointer?
        private let ioLock = NSRecursiveLock()
        private let readBuffer = ReadBuffer(size: 1024)
        
        var scrollDirection = 1
        
        init() {
            
        }
        
        var isConnected: Bool {
            get {
                ioLock.lock(); defer { ioLock.unlock() }
                return dev != nil
            }
        }
        
        var manufacturer: String {
            get {
                ioLock.lock(); defer { ioLock.unlock() }
                
                guard let dev = self.dev else {
                    return ""
                }
                
                let buffer = UnsafeMutablePointer<wchar_t>.allocate(capacity: 255)
                
                hid_get_manufacturer_string(dev, buffer, 255)
                
                return NSString(wcharArray: buffer) as String
            }
        }
        
        var serialNumber: String {
            get {
                ioLock.lock(); defer { ioLock.unlock() }
                guard let dev = self.dev else {
                    return ""
                }
                
                let buffer = UnsafeMutablePointer<wchar_t>.allocate(capacity: 255)
                hid_get_serial_number_string(dev, buffer, 255)
                    
                return NSString(wcharArray: buffer) as String
            }
        }
        
        @discardableResult
        func connect() -> Bool {
            ioLock.lock(); defer { ioLock.unlock() }
            dev = hid_open(Dial.Device.VendorId, Dial.Device.ProductId, nil)
            return isConnected
        }
        
        
        func disconnect() {
            ioLock.lock(); defer { ioLock.unlock() }
            if let dev = self.dev {
                hid_close(dev)
            }
            dev = nil
        }
        
        // https://github.com/daniel5151/surface-dial-linux/blob/main/src/dial_device/haptics.rs
        func configure(_ configuration: DialHardwareConfiguration) -> Bool {
            ioLock.lock(); defer { ioLock.unlock() }
            guard let dev = dev else { return false }
            let report = configuration.featureReport
            return hid_send_feature_report(dev, report, report.count) == report.count
        }
        
        func impact(repeatCount: UInt8 = 0) {
            ioLock.lock(); defer { ioLock.unlock() }
            if isConnected {
                var buf: Array<UInt8> = []
                buf.append(0x01) // Report ID
                buf.append(repeatCount) // RepeatCount
                buf.append(0x03) // ManualTrigger
                buf.append(0x00) // RetriggerPeriod (lo)
                buf.append(0x00) // RetriggerPeriod (hi)
                hid_write(dev, buf, 5)
            }
        }
        
        private func parse(bytes: UnsafeMutableBufferPointer<UInt8>) -> InputReport {
            switch bytes[0] {
            case 1 where bytes.count >= 4:
                
                let buttonState = bytes[1]&1 == 1 ? ButtonState.pressed : .released
                
                let rotation = { () -> Rotation? in
                    switch bytes[2] {
                        case 1:
                            return .Clockwise(1)
                        case 0xff:
                            return .CounterClockwise(1)
                        default:
                            return nil
                }}()
                
                return .dial(buttonState, rotation)
            default:
                return .unknown
            }
        }
        
        func read() -> InputReport?
        {
            ioLock.lock(); defer { ioLock.unlock() }
            guard let dev = self.dev else {
                return nil
            }
            
            // Bound reads so configuration never waits for physical input.
            let readBytes = hid_read_timeout(dev, readBuffer.pointer, readBuffer.size, 20)
            if readBytes == 0 { return .unknown }
            
            if readBytes <= 0 {
                print("Device disconnected")
                disconnect()
                return nil;
            }
            
            let array = UnsafeMutableBufferPointer(start: readBuffer.pointer, count: Int(readBytes))
            
            let dataStr = array.map({ String(format:"%02X", $0)}).joined(separator: " ")
            print("Read data from device: \(dataStr)")
            
            return parse(bytes: array)
        }
    }
    
    private var thread: Thread?
    private var run: Bool = false
    let device = Device()
    private let configuration: DialConfigurationController
    private let hardwareQueue = DispatchQueue(label: "MacDial.hardware-feedback", qos: .userInteractive)
    private let commands: DialHardwareCommands
    private let connectionLock = NSLock()
    private var cachedSerialNumber: String?
    private let semaphore = DispatchSemaphore(value: 0)
    
    var onInput: ((InputReport, TimeInterval, UInt64) -> Void)?
    var onDisconnected: (() -> Void)?
    
    @discardableResult
    func updatePreferences(sensitivity: WheelSensitivity? = nil, haptics: Bool? = nil) -> Bool {
        configuration.update(sensitivity: sensitivity, haptics: haptics)
    }

    @discardableResult
    func setMenuNavigationActive(_ active: Bool) -> Bool {
        let success = commands.setMenuNavigationActive(active)
        if !success { print("Could not apply Dial menu configuration; restoring normal sensitivity.") }
        return success
    }

    func acceptsRotation(_ generation: UInt64) -> Bool {
        commands.acceptsRotation(generation)
    }

    func feedback() {
        commands.feedback()
    }

    func cancelFeedback() {
        commands.cancelFeedback()
    }

    var connectedSerialNumber: String? {
        connectionLock.lock(); defer { connectionLock.unlock() }
        return cachedSerialNumber
    }

    private func setConnectedSerialNumber(_ serial: String?) {
        connectionLock.lock(); defer { connectionLock.unlock() }
        cachedSerialNumber = serial
    }
    
    var scrollDirection: Int {
        get {
            return device.scrollDirection
        }
        
        set (value) {
            device.scrollDirection = value
        }
    }
    
    init() {
        let device = self.device
        configuration = DialConfigurationController(apply: { device.configure($0) })
        let queue = hardwareQueue
        commands = DialHardwareCommands(configuration: configuration,
                                        schedule: { work in queue.async(execute: work) },
                                        impact: { device.impact() })
        hid_init()
    }
    
    deinit {
        stop()
        hid_exit()
    }
    
    func start() {
        self.thread = Thread(target: self, selector: #selector(threadProc(arg:)), object: nil);
        
        run = true;
        thread!.start()
    }
    
    func stop() {
        run = false;
        commands.invalidate()
        hardwareQueue.sync {} // Finish any write already in flight before closing HID.
        setConnectedSerialNumber(nil)
        configuration.shutdown()
        if let thread = self.thread {
            semaphore.signal()
            device.disconnect()
            while !thread.isFinished { }
            self.thread = nil;
        }
        
    }
    
    private func connect() -> Bool
    {
        return false
    }
    
    @objc
    private func threadProc(arg: NSObject) {
        
        hid_monitor { vendorId, productId, serialNumber in
            if (vendorId==Device.VendorId && productId==Device.ProductId) {
                DispatchQueue.main.async {
                    // We cannot capture 'self' here since this is a c function pointer
                    // Luckily we can find ourselves again through the AppDelegate
                    let app = NSApplication.shared.delegate as! AppDelegate
                    app.dial.semaphore.signal()
                }

            }
        }
        
        while run {
            
            if !device.isConnected {
                print("Trying to open device...")
                if device.connect() {
                    let serial = device.serialNumber
                    print("Device \(serial) opened.")
                    if !configuration.didConnect() {
                        print("Could not configure Dial after connecting.")
                        device.disconnect()
                        configuration.didDisconnect()
                        onDisconnected?()
                    } else {
                        setConnectedSerialNumber(serial)
                    }
                } else {
                    print("Device couldn't be opened.")
                }
            }
            
            while device.isConnected {
                
                let input = configuration.withInputContext { device.read() }
                switch input.value {
                
                case .dial(let buttonState, let rotation):
                    // Deliver one complete report. The main-queue router must
                    // consume a confirmation release and its rotation together.
                    onInput?(.dial(buttonState, rotation), ProcessInfo.processInfo.systemUptime, input.generation)

                case .unknown:
                    break
                case nil:
                    print("Device disconnected.")
                    commands.invalidate()
                    setConnectedSerialNumber(nil)
                    configuration.didDisconnect()
                    onDisconnected?()
                }
            }
            
            let _ = semaphore.wait(timeout: .now().advanced(by: .seconds(60)))
        }
    }
}
