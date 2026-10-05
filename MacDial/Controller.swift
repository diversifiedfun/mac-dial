
import Foundation

protocol Controller: AnyObject
{
    // Physical press notification only; actions still wait for a short release.
    func onPressBegan()

    func onDown()
    
    func onUp()

    // End a pending press without performing its short-click action.
    func onCancel()
    
    func onRotate(_ rotation: Dial.Rotation,_ scrollDirection: Int)
}

extension Controller {
    func onPressBegan() {}
    func onCancel() {}
}
