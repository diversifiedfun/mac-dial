

import Foundation
import AppKit

// https://stackoverflow.com/a/55854051
func HIDPostAuxKey(key: Int32, modifiers: [NSEvent.ModifierFlags], _repeat: Int = 1) {
    func doKey(down: Bool) {
        
        var rawFlags: UInt = (down ? 0xa00 : 0xb00);
        
        for modifier in modifiers {
            rawFlags |= modifier.rawValue
        }
        
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        
        let data1 = Int((key<<16) | (down ? 0xa00 : 0xb00))

        let ev = NSEvent.otherEvent(with: NSEvent.EventType.systemDefined,
                                    location: NSPoint(x:0,y:0),
                                    modifierFlags: flags,
                                    timestamp: 0,
                                    windowNumber: 0,
                                    context: nil,
                                    subtype: 8,
                                    data1: data1,
                                    data2: -1
                                    )
        let cev = ev?.cgEvent
        cev?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    for _ in 0..<_repeat {
        doKey(down: true)
        doKey(down: false)
    }

}


class PlaybackController : Controller {
    
    var lastClick = -TimeInterval.infinity
    private let post: (Int32, [NSEvent.ModifierFlags], Int) -> Void

    init(post: @escaping (Int32, [NSEvent.ModifierFlags], Int) -> Void = {
        HIDPostAuxKey(key: $0, modifiers: $1, _repeat: $2)
    }) {
        self.post = post
    }

    func onCancel() {
        lastClick = -TimeInterval.infinity
    }
    
    func onDown() {
        
    }
    
    func onUp() {
        
        let clickDelay = Date().timeIntervalSince1970 - lastClick
        
        // Next song on double click
        if (clickDelay < 0.5) {
            // Undo pause sent on first click
            post(NX_KEYTYPE_PLAY, [], 1)
            
            post(NX_KEYTYPE_NEXT, [], 1)
        }
        else { // Play / Pause on single click
            
            post(NX_KEYTYPE_PLAY, [], 1)
        }
        
        lastClick = Date().timeIntervalSince1970
    }
    
    
    
    func onRotate(_ rotation: Dial.Rotation,_ scrollDirection: Int) {
        
        let modifiers = [NSEvent.ModifierFlags.shift, NSEvent.ModifierFlags.option]
        
        switch (rotation) {
        case .Clockwise(let _repeat):
            post(NX_KEYTYPE_SOUND_UP, modifiers, _repeat)
            break
        case .CounterClockwise(let _repeat):
            post(NX_KEYTYPE_SOUND_DOWN, modifiers, _repeat)

            break
        }
    }
    
    
}
