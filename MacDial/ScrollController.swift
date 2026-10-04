
import Foundation
import AppKit

class ScrollController: Controller
{
    private let scrollEventSource = CGEventSource(stateID: .hidSystemState)
    private var mouseIsDown = false
    private let post: (CGEvent) -> Void

    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
    }

    enum Direction {
        case up
        case down
    }
    
    private func sendMouse(button direction: Direction) {
        let mousePos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        
        let translatedMousePos = NSPoint(x: mousePos.x, y: screenHeight - mousePos.y)
        
        let event = CGEvent(mouseEventSource: nil, mouseType: direction == .down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: translatedMousePos, mouseButton: .left)
        
        if let event = event { post(event) }
    }
    
    func onDown() {
        guard !mouseIsDown else { return }
        mouseIsDown = true
        sendMouse(button: .down)
    }
    
    func onUp() {
        guard mouseIsDown else { return }
        mouseIsDown = false
        sendMouse(button: .up)
    }

    func onCancel() {
        onUp()
    }
    
    var lastRotate: TimeInterval = Date().timeIntervalSince1970
    
    func onRotate(_ rotation: Dial.Rotation,_ scrollDirection: Int) {
        var steps = 0
        switch rotation {
        case .Clockwise(let d):
            steps = d
        case .CounterClockwise(let d):
            steps = -d
        }
        
        steps *= scrollDirection;
        
        let diff = (Date().timeIntervalSince1970 - lastRotate) * 1000
        let multiplifer = Int(1 + ((150 - min(diff, 150)) / 40))
        
        
        let lineDelta = Int32(steps * multiplifer)
        let pixelDelta = lineDelta * 24
        let event = CGEvent(scrollWheelEvent2Source: scrollEventSource, units: .pixel, wheelCount: 1, wheel1: pixelDelta, wheel2: 0, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lineDelta))
        event?.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixelDelta))
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        
        if let event = event { post(event) }
        
        lastRotate = Date().timeIntervalSince1970
    }
}
