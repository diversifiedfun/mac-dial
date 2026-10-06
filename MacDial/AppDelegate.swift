
import Cocoa
import ServiceManagement
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusBarController: StatusBarController?
    let dial = Dial()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        do { statusBarController = try StatusBarController(dial) }
        catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        dial.start(); // Install preferences and input callbacks before reading HID.
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        statusBarController?.cancelPendingInput()
        dial.stop();
    }
}
