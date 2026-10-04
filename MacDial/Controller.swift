
import Foundation

protocol Controller: AnyObject
{
    func onDown()
    
    func onUp()

    // End a pending press without performing its short-click action.
    func onCancel()
    
    func onRotate(_ rotation: Dial.Rotation,_ scrollDirection: Int)
}

extension Controller {
    func onCancel() {}
}
