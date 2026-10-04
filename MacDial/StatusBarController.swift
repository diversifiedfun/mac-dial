
import Foundation
import AppKit

enum ScrollDirection: String {
    case standard = "standard"
    case natural = "natural"
}

enum HapticsMode: String {
    case enabled = "enabled"
    case disabled = "disabled"
}

extension NSMenuItem {
    convenience init(title: String) {
        self.init()
        self.title = title
    }
}

class MenuOptionItem<Type>: NSMenuItem {
    init(title: String, option: Type) {
        super.init(title: title, action: nil, keyEquivalent: "")
        self.representedObject = option
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var selected : Bool
    {
        get { return self.state == .on }
        set (on) { self.state = on ? .on : .off }
    }
    
    var option : Type
    {
        get
        {
            return self.representedObject as! Type
        }
    }
}

class ControllerOptionItem: MenuOptionItem<Mode>
{
    let controller: Controller
    
    init(title: String, mode: Mode, controller: Controller) {
        self.controller = controller
        super.init(title: title, option: mode)
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}


extension NSMenu {
    func addMenuItems(_ items: StatusBarController.MenuItems) {
        self.addItem(items.title)
        self.addItem(items.connectionStatus)
        self.addItem(items.separator)
        for item in items.modeItems { self.addItem(item) }
        items.lightroom.submenu = NSMenu()
        for item in items.lightroomModes { items.lightroom.submenu?.addItem(item) }
        self.addItem(items.lightroom)
        self.addItem(items.separator2)
        
        items.wheelSensitivity.submenu = NSMenu.init()
        for sensitivityOption in items.wheelSensitivityOptions {
            items.wheelSensitivity.submenu?.addItem(sensitivityOption)
        }
        self.addItem(items.wheelSensitivity)

        items.menuPressDuration.submenu = NSMenu()
        for option in items.menuPressDurationOptions {
            items.menuPressDuration.submenu?.addItem(option)
        }
        self.addItem(items.menuPressDuration)
        
        items.scrollDirection.submenu = NSMenu.init()
        for scrollDirectionOption in items.scrollDirectionOptions {
            items.scrollDirection.submenu?.addItem(scrollDirectionOption)
        }
        self.addItem(items.scrollDirection)
        
        items.hapticsMode.submenu = NSMenu.init()
        for hapticsModeOption in items.hapticsModeOptions {
            items.hapticsMode.submenu?.addItem(hapticsModeOption)
        }
        self.addItem(items.hapticsMode)
        
        self.addItem(items.separator3)
        self.addItem(items.quit)
    }
}

class StatusBarController
{
    private let statusBar: NSStatusBar
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let dial: Dial
    private let menuItems = MenuItems()
    private let modeContext = AppModeContext()
    private let inputGate = InputContextGate()
    private var foregroundPID: pid_t?
    private var foregroundBundleID: String?
    private lazy var input = DialInputCoordinator(
        currentMode: { [weak self] in self?.currentMode ?? .scrolling },
        currentProfile: { [weak self] in self?.modeContext.profile })
    private let radialMenu = RadialMenuController()
    private var connectionTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    
    struct MenuItems {
        let title = NSMenuItem.init(title: "Mac Dial")
        let connectionStatus = NSMenuItem.init()
        let separator = NSMenuItem.separator()
        let scrollMode = ControllerOptionItem.init(title: "Scroll mode", mode: .scrolling, controller: ScrollController())
        let playbackMode = ControllerOptionItem.init(title: "Playback mode", mode: .playback, controller: PlaybackController())
        let zoomMode = ControllerOptionItem(title: "Zoom mode", mode: .zoom, controller: ZoomController())
        var modeItems: [ControllerOptionItem] { [scrollMode, playbackMode, zoomMode] }
        let lightroom = NSMenuItem(title: "Lightroom")
        let lightroomModes = AppProfile.lightroom.modes.map {
            ControllerOptionItem(title: $0.title, mode: $0, controller: LightroomController(mode: $0))
        }
        var allModeItems: [ControllerOptionItem] { modeItems + lightroomModes }
        let separator2 = NSMenuItem.separator()
        let wheelSensitivity = NSMenuItem.init(title: "Wheel Sensitivity")
        let wheelSensitivityOptions = [
            MenuOptionItem<WheelSensitivity>.init(title: "Low", option: .low),
            MenuOptionItem<WheelSensitivity>.init(title: "Medium", option: .medium),
            MenuOptionItem<WheelSensitivity>.init(title: "High", option: .high),
            MenuOptionItem<WheelSensitivity>.init(title: "Extreme", option: .extreme)
        ]
        let menuPressDuration = NSMenuItem(title: "Menu Press Duration")
        let menuPressDurationOptions = MenuPressDuration.allCases.map {
            MenuOptionItem(title: "\($0.rawValue) ms", option: $0)
        }
        let scrollDirection = NSMenuItem.init(title: "Scroll Direction")
        let scrollDirectionOptions = [
            MenuOptionItem<ScrollDirection>.init(title: "Standard", option: .standard),
            MenuOptionItem<ScrollDirection>.init(title: "Natural", option: .natural)
        ]
        let hapticsMode = NSMenuItem.init(title: "Haptics")
        let hapticsModeOptions = [
            MenuOptionItem<HapticsMode>.init(title: "Disabled", option: .disabled),
            MenuOptionItem<HapticsMode>.init(title: "Enabled", option: .enabled)
        ]
        let separator3 = NSMenuItem.separator()
        let quit = NSMenuItem.init(title: "Quit")
    }
    
    var currentMode: Mode { modeContext.currentMode }

    var currentController: Controller {
        menuItems.allModeItems.first { $0.option == currentMode }!.controller
    }

    var wheelSensitivity: WheelSensitivity? {
        get {
            let raw = UserDefaults.standard.string(forKey: "sensitivity") ?? WheelSensitivity.medium.rawValue
            return WheelSensitivity(rawValue: raw)
        }
        set (sensitivity) {
            if !dial.updatePreferences(sensitivity: sensitivity ?? .medium) {
                input.cancel()
            }
            for option in menuItems.wheelSensitivityOptions {
                option.state = (option.representedObject as! WheelSensitivity) == sensitivity ? .on : .off
            }
            
            UserDefaults.standard.setValue(sensitivity?.rawValue, forKey: "sensitivity")
        }
    }
    
    var menuPressDuration: MenuPressDuration {
        get { MenuPressDuration.load() }
        set {
            input.menuPressDuration = newValue
            for option in menuItems.menuPressDurationOptions {
                option.selected = option.option == newValue
            }
            newValue.save()
        }
    }

    var scrollDirection: ScrollDirection? {
        get {
            let raw = UserDefaults.standard.string(forKey: "direction") ?? ScrollDirection.natural.rawValue
            return ScrollDirection(rawValue: raw)
        }
        set (scrollingDirection) {
            switch scrollingDirection {
            case .standard:
                dial.scrollDirection = 1
                break
            case .natural:
                dial.scrollDirection = -1
                break
            case .none:
                break
            }
            for option in menuItems.scrollDirectionOptions {
                option.state = (option.representedObject as! ScrollDirection) == scrollingDirection ? .on : .off
            }
            
            UserDefaults.standard.setValue(scrollingDirection?.rawValue, forKey: "direction")
        }
    }
    
    var hapticsMode: HapticsMode? {
        get {
            let raw = UserDefaults.standard.string(forKey: "hapticsmode") ?? HapticsMode.disabled.rawValue
            return HapticsMode(rawValue: raw)
        }
        set (hapticsModeSet) {
            if !dial.updatePreferences(haptics: hapticsModeSet == .enabled) {
                input.cancel()
            }
            for option in menuItems.hapticsModeOptions {
                option.state = (option.representedObject as! HapticsMode) == hapticsModeSet ? .on : .off
            }
            
            UserDefaults.standard.setValue(String(hapticsModeSet!.rawValue), forKey: "hapticsmode")
        }
    }
    
    init( _ dial: Dial) {
        self.dial = dial
        self.menu = NSMenu.init()
        
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        
        let app = NSWorkspace.shared.frontmostApplication
        foregroundPID = app?.processIdentifier
        foregroundBundleID = app?.bundleIdentifier
        modeContext.activate(bundleIdentifier: foregroundBundleID)
        menu.minimumWidth = 260
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 0)
        ]
        
        menuItems.title.attributedTitle = NSAttributedString(string: menuItems.title.title, attributes: attributes)
        menuItems.title.target = self
        menuItems.title.action = #selector(showAbout(sender:))
        
        menuItems.connectionStatus.target = self
        menuItems.connectionStatus.isEnabled = false
        
        for item in menuItems.allModeItems {
            item.target = self
            item.action = #selector(setMode(sender:))
            item.selected = item.option == currentMode
        }
        
        for option in menuItems.wheelSensitivityOptions {
            option.target = self
            option.action = #selector(setSensitivity(sender:))
            option.selected = option.option == wheelSensitivity
        }
        wheelSensitivity = wheelSensitivity // trigger set which updates dial

        for option in menuItems.menuPressDurationOptions {
            option.target = self
            option.action = #selector(setMenuPressDuration(sender:))
        }
        menuPressDuration = menuPressDuration // restore timing and the checkmark at launch
        
        for option in menuItems.scrollDirectionOptions {
            option.target = self
            option.action = #selector(setScrollDirection(sender:))
            option.selected = option.option == scrollDirection
        }
        scrollDirection = scrollDirection // apply the saved direction when launching
        
        for option in menuItems.hapticsModeOptions {
            option.target = self
            option.action = #selector(setHaptics(sender:))
            option.selected = option.option == hapticsMode
        }
        hapticsMode = hapticsMode // trigger set which updates dial
        
        
        menuItems.quit.target = self;
        menuItems.quit.action = #selector(quitApp(sender:))
        
        menu.addMenuItems(menuItems)
        
        statusItem.menu = menu
        refreshModeUI()
        
        if let button = statusItem.button {
            button.target = self
            updateIcon()
        }
        
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self]_ in
            self?.updateConnectionStatus()
        }
        
        input.onShortPress = { [weak self] in
            guard let self = self, !self.refreshForegroundApplication() else { return }
            let controller = self.currentController
            controller.onDown()
            controller.onUp()
        }
        input.onRotation = { [weak self] rotation, direction in
            guard let self = self, !self.refreshForegroundApplication() else { return }
            self.currentController.onRotate(rotation, direction)
        }
        input.onCancelAction = { [weak self] in self?.currentController.onCancel() }
        input.onCommit = { [weak self] mode in self?.applyMode(mode) }
        input.onFeedback = { [weak self] in self?.dial.feedback() }
        input.onMenuNavigationChanged = { [weak self] active in
            self?.dial.setMenuNavigationActive(active) ?? false
        }
        input.onPickerChanged = { [weak self] state in
            guard let self = self else { return }
            if let state = state {
                guard !self.refreshForegroundApplication() else { return }
                self.radialMenu.show(state)
            }
            else { self.radialMenu.dismiss() }
        }
        radialMenu.view.onHighlight = { [weak self] mode in self?.input.highlight(mode) }
        radialMenu.view.onMove = { [weak self] steps in self?.input.moveSelection(by: steps) }
        radialMenu.view.onConfirm = { [weak self] in self?.input.confirmSelection() }
        radialMenu.view.onSelect = { [weak self] mode in
            self?.input.highlight(mode)
            self?.input.confirmSelection()
        }
        radialMenu.view.onCancel = { [weak self] in self?.cancelPendingInput() }

        let gate = inputGate
        dial.onInput = { [weak self] report, timestamp, configurationGeneration in
            let token = gate.token
            DispatchQueue.main.async {
                guard let self = self, case let .dial(button, rotation) = report else { return }
                let changedApp = self.refreshForegroundApplication()
                guard !changedApp, gate.accepts(token, timestamp: timestamp) else {
                    self.input.discard(button: button)
                    return
                }
                // A sensitivity transition invalidates only rotation. Preserve
                // release edges so an opening hold still arms the new picker.
                self.input.handle(button: button, rotation: rotation,
                                  rotationIsCurrent: self.dial.acceptsRotation(configurationGeneration),
                                  scrollDirection: self.dial.scrollDirection, timestamp: timestamp)
            }
        }
        dial.onDisconnected = { [weak self] in
            DispatchQueue.main.async { self?.cancelPendingInput() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observe(workspace, name)
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
    }

    deinit {
        connectionTimer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.cancelPendingInput()
            self.refreshForegroundApplication()
        }
        observers.append((center, observer))
    }

    private func updateConnectionStatus() {
        if !AXIsProcessTrusted() {
            menuItems.connectionStatus.title = "Accessibility permission required"
            return
        }
        if dial.device.isConnected {
            let serialNumber = dial.device.serialNumber
            menuItems.connectionStatus.title = "Surface Dial '\(serialNumber)' connected"
        }
        else {
            menuItems.connectionStatus.title = "No Surface Dial connected"
        }
    }
    
    private func refreshModeUI() {
        for item in menuItems.allModeItems { item.selected = item.option == currentMode }
        menuItems.lightroom.isHidden = modeContext.profile == nil
        menuItems.lightroom.state = currentMode.isLightroom ? .on : .off
        updateIcon()
    }

    // Also called before consuming input: do not rely on workspace notification
    // delivery winning a race with a queued HID report or menu confirmation.
    @discardableResult
    private func refreshForegroundApplication() -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        guard foregroundPID != app?.processIdentifier || foregroundBundleID != app?.bundleIdentifier else { return false }
        cancelPendingInput()
        foregroundPID = app?.processIdentifier
        foregroundBundleID = app?.bundleIdentifier
        modeContext.activate(bundleIdentifier: foregroundBundleID)
        refreshModeUI()
        return true
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let mode = currentMode
        switch mode {
        case .scrolling: button.image = #imageLiteral(resourceName: "icon-scroll")
        case .playback: button.image = #imageLiteral(resourceName: "icon-playback")
        default: button.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title)
        }
        button.image?.isTemplate = true
        button.image?.size = NSSize(width: 18, height: 18)
        let context = modeContext.profile.map { "\($0.title) — " } ?? ""
        button.toolTip = "Mac Dial — \(context)\(mode.title). Hold, release, turn, then click to choose a mode."
        button.imagePosition = .imageLeft
    }

    @objc func showAbout(sender: AnyObject) {
        
    }
    
    @objc func setMode(sender: AnyObject) {
        let item = sender as! ControllerOptionItem
        cancelPendingInput()
        applyMode(item.option)
    }

    func cancelPendingInput() {
        inputGate.invalidate()
        input.cancel()
    }

    private func applyMode(_ mode: Mode) {
        guard !refreshForegroundApplication(), modeContext.select(mode) else { return }
        refreshModeUI()
    }
    
    @objc func setSensitivity(sender: AnyObject) {
        let item = sender as! NSMenuItem
        wheelSensitivity = (item.representedObject as! WheelSensitivity)
    }
    
    @objc func setScrollDirection(sender: AnyObject) {
        let item = sender as! NSMenuItem
        scrollDirection = (item.representedObject as! ScrollDirection)
    }

    @objc func setMenuPressDuration(sender: AnyObject) {
        let item = sender as! MenuOptionItem<MenuPressDuration>
        menuPressDuration = item.option
    }
    
    @objc func setHaptics(sender: AnyObject) {
        let item = sender as! NSMenuItem
        hapticsMode = (item.representedObject as! HapticsMode)
    }

    @objc func quitApp(sender: AnyObject) {
        NSApplication.shared.terminate(self)
    }

}
