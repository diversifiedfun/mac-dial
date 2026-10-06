
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
        toolTip = mode.usageHelp
        setAccessibilityHelp(mode.usageHelp)
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
        self.addItem(items.customize)
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

        items.radialMenuStartPosition.submenu = NSMenu()
        for option in items.radialMenuStartPositionOptions {
            items.radialMenuStartPosition.submenu?.addItem(option)
        }
        self.addItem(items.radialMenuStartPosition)

        items.radialMenuAppearance.submenu = NSMenu()
        items.radialMenuAppearance.submenu?.autoenablesItems = false
        for option in items.radialMenuAppearanceOptions {
            items.radialMenuAppearance.submenu?.addItem(option)
        }
        self.addItem(items.radialMenuAppearance)
        
        items.scrollStyle.submenu = NSMenu()
        for option in items.scrollStyleOptions { items.scrollStyle.submenu?.addItem(option) }
        self.addItem(items.scrollStyle)

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
    private let modeContext: AppModeContext
    private let permissions = DialPermissions()
    private var permissionWindow: DialPermissionWindow?
    private let noActionController = NoActionController()
    private var customControllers: [SliceID: CustomSliceController] = [:]
    private var dynamicMenuItems: [NSMenuItem] = []
    private var observedConfiguration: SliceConfiguration?
    // The customization window will own this flag while it is active.
    var customizationIsActive = false {
        didSet { if customizationIsActive { cancelPendingInput() } }
    }
    var configurationStore: SliceConfigurationStore { modeContext.store }
    private let inputGate = InputContextGate()
    private var foregroundPID: pid_t?
    private var foregroundBundleID: String?
    private lazy var input = DialInputCoordinator(
        currentMode: { [weak self] in self?.currentMode ?? .scrolling },
        currentProfile: { [weak self] in self?.modeContext.profile })
    private let radialMenu = RadialMenuController()
    private lazy var customizationWindow: DialCustomizationWindow = {
        let window = DialCustomizationWindow(store: configurationStore)
        window.onVisibilityChanged = { [weak self] active in
            self?.cancelPendingInput()
            self?.customizationIsActive = active
        }
        return window
    }()
    private var connectionTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    
    struct MenuItems {
        let title = NSMenuItem.init(title: "About Mac Dial")
        let connectionStatus = NSMenuItem.init()
        let separator = NSMenuItem.separator()
        let scrollMode = ControllerOptionItem.init(title: "Scroll mode", mode: .scrolling, controller: ScrollController())
        let playbackMode = ControllerOptionItem.init(title: "Playback mode", mode: .playback, controller: PlaybackController())
        let zoomMode = ControllerOptionItem(title: "Zoom mode", mode: .zoom, controller: ZoomController())
        let undoRedoMode = ControllerOptionItem(title: "Undo/Redo mode", mode: .undoRedo, controller: UndoRedoController())
        let brightnessMode = ControllerOptionItem(title: "Brightness mode", mode: .brightness, controller: BrightnessController())
        var modeItems: [ControllerOptionItem] { [scrollMode, playbackMode, zoomMode, undoRedoMode, brightnessMode] }
        let lightroom = NSMenuItem(title: "Lightroom")
        let lightroomModes = AppProfile.lightroom.modes.map {
            ControllerOptionItem(title: $0.title, mode: $0, controller: LightroomController(mode: $0))
        }
        let editwall = NSMenuItem(title: "Editwall")
        let editwallModes = [ControllerOptionItem(title: Mode.editwallSequence.title,
                                                  mode: .editwallSequence, controller: EditwallSequenceController())]
        var allModeItems: [ControllerOptionItem] { modeItems + lightroomModes + editwallModes }
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
        let radialMenuStartPosition = NSMenuItem(title: "Radial Menu Starts At")
        let radialMenuAppearance = NSMenuItem(title: "Radial Menu Appearance")
        let radialMenuAppearanceOptions = RadialMenuAppearance.allCases.map {
            MenuOptionItem(title: $0.title, option: $0)
        }
        let radialMenuStartPositionOptions = [
            MenuOptionItem<RadialMenuStartPosition>(title: "Last Selected", option: .lastSelected),
            MenuOptionItem<RadialMenuStartPosition>(title: "First Item", option: .firstItem)
        ]
        let scrollStyle = NSMenuItem(title: "Scroll Style")
        let scrollStyleOptions = ScrollStyle.allCases.map { MenuOptionItem(title: $0.title, option: $0) }
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
        let customize = NSMenuItem(title: "Customize Dial…")
        let quit = NSMenuItem.init(title: "Quit")
    }
    
    var currentMode: Mode { modeContext.currentMode }

    var currentController: Controller {
        guard permissions.isGranted, !customizationIsActive, let slice = modeContext.currentSlice else { return noActionController }
        if let mode = slice.builtInMode {
            return menuItems.allModeItems.first { $0.option == mode }?.controller ?? noActionController
        }
        if let cached = customControllers[slice.id] { return cached }
        guard case .custom(let value) = slice.content else { return noActionController }
        let appID = modeContext.resolvedDial.applicationSlices.contains { $0.id == slice.id }
            ? modeContext.application?.bundleIdentifier : nil
        let controller = CustomSliceController(gestures: value.gestures, targetProcess: { [weak self] in
            guard let self = self, self.permissions.refresh(), !self.customizationIsActive,
                  self.modeContext.currentSlice?.id == slice.id,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  appID == nil || app.bundleIdentifier == appID else { return nil }
            return app.processIdentifier
        })
        customControllers[slice.id] = controller
        return controller
    }

    private var scrollController: ScrollController { menuItems.scrollMode.controller as! ScrollController }

    private func refreshScrollStyleUI() {
        for option in menuItems.scrollStyleOptions { option.selected = option.option == scrollController.style }
        let help = "Scroll style: \(scrollController.style.title). Click to cycle Stepped / Freestyle / Precision. Hold to choose a mode."
        menuItems.scrollMode.toolTip = help
        menuItems.scrollMode.setAccessibilityHelp(help)
        updateIcon()
    }

    var wheelSensitivity: WheelSensitivity? {
        get {
            let raw = UserDefaults.standard.string(forKey: "sensitivity") ?? WheelSensitivity.medium.rawValue
            return WheelSensitivity(rawValue: raw)
        }
        set (sensitivity) {
            scrollController.onCancel()
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

    var radialMenuStartPosition: RadialMenuStartPosition {
        get { RadialMenuStartPosition.load() }
        set {
            input.radialMenuStartPosition = newValue
            for option in menuItems.radialMenuStartPositionOptions {
                option.selected = option.option == newValue
            }
            newValue.save()
        }
    }

    var radialMenuAppearance: RadialMenuAppearance {
        get { RadialMenuAppearance.load() }
        set {
            radialMenu.view.preferredAppearance = newValue
            for option in menuItems.radialMenuAppearanceOptions {
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
            scrollController.onCancel()
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
    
    init( _ dial: Dial) throws {
        self.modeContext = try AppModeContext()
        self.dial = dial
        self.menu = NSMenu.init()
        
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        
        let app = NSWorkspace.shared.frontmostApplication
        foregroundPID = app?.processIdentifier
        foregroundBundleID = app?.bundleIdentifier
        modeContext.activate(bundleIdentifier: foregroundBundleID)
        observedConfiguration = modeContext.store.configuration
        modeContext.store.onChange = { [weak self] configuration in
            guard let self = self else { return }
            if self.observedConfiguration?.hasSameContent(as: configuration) != true {
                self.cancelPendingInput()
                self.customControllers.removeAll()
            }
            self.observedConfiguration = configuration
            self.refreshModeUI()
        }
        input.currentPicker = { [weak self] in
            self?.modeContext.pickerState ?? ModePickerState(selectedMode: .scrolling)
        }
        menu.minimumWidth = 260
        menu.autoenablesItems = false
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 0)
        ]
        
        menuItems.title.attributedTitle = NSAttributedString(string: menuItems.title.title, attributes: attributes)
        menuItems.title.target = self
        menuItems.title.action = #selector(showAbout(sender:))
        
        menuItems.connectionStatus.target = self
        menuItems.connectionStatus.action = #selector(showPermissionHelp)
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

        for option in menuItems.radialMenuStartPositionOptions {
            option.target = self
            option.action = #selector(setRadialMenuStartPosition(sender:))
            if option.option == .firstItem {
                let help = "Always highlight the first menu item when opening, so you can navigate by touch."
                option.toolTip = help
                option.setAccessibilityHelp(help)
            }
        }
        radialMenuStartPosition = radialMenuStartPosition // restore the opening choice and checkmark

        for option in menuItems.radialMenuAppearanceOptions {
            option.target = self
            option.action = #selector(setRadialMenuAppearance(sender:))
            option.isEnabled = option.option != .liquidGlass || RadialMenuAppearance.supportsLiquidGlass
            let help = option.option == .liquidGlass
                ? "Requires macOS 26 or later. Follows system appearance and accessibility settings."
                : option.option == .automatic
                    ? "Use native Liquid Glass on macOS 26 or later, and Classic on older systems."
                    : "Use the traditional frosted wheel, following system appearance."
            option.toolTip = help
            option.setAccessibilityHelp(help)
        }
        radialMenuAppearance = radialMenuAppearance
        
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
        menuItems.customize.target = self
        menuItems.customize.action = #selector(showCustomization)
        
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
        
        scrollController.setStyle(ScrollStyle.load())
        scrollController.onStyleChanged = { [weak self] style in
            guard let self = self else { return }
            style.save()
            self.refreshScrollStyleUI()
            self.dial.feedback() // The hardware queue honors the Haptics setting.
        }
        scrollController.canScroll = { [weak self] in
            guard let self = self, !self.refreshForegroundApplication() else { return false }
            return self.permissions.refresh() && !self.customizationIsActive && self.modeContext.currentSlice?.builtInMode == .scrolling && self.input.picker == nil
        }
        for option in menuItems.scrollStyleOptions {
            option.target = self
            option.action = #selector(setScrollStyle(sender:))
        }
        refreshScrollStyleUI()

        input.onPressBegan = { [weak self] in self?.currentController.onPressBegan() }
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
        input.onCommitSlice = { [weak self] id in self?.applySlice(id) ?? false }
        input.onConfirmation = { [weak self] state in self?.radialMenu.confirm(state) }
        input.onFeedback = { [weak self] in self?.dial.feedback() }
        input.onMenuNavigationChanged = { [weak self] active in
            self?.dial.setMenuNavigationActive(active) ?? false
        }
        input.onPickerChanged = { [weak self] state in
            guard let self = self else { return }
            if let state = state {
                guard self.permissions.refresh(), !self.refreshForegroundApplication() else { return }
                self.radialMenu.show(state)
            }
            else { self.radialMenu.dismiss() }
        }
        radialMenu.view.onHighlightSlice = { [weak self] id in self?.input.highlightSlice(id) }
        radialMenu.view.onPressHighlightSlice = { [weak self] id in self?.input.highlightSlice(id, feedback: false) }
        radialMenu.view.onMove = { [weak self] steps in self?.input.moveSelection(by: steps) }
        radialMenu.view.onConfirm = { [weak self] in self?.input.confirmSelection() }
        radialMenu.view.onSelectSlice = { [weak self] id in
            self?.input.confirmSlice(id)
        }
        radialMenu.view.onCancel = { [weak self] in self?.cancelPendingInput() }

        let gate = inputGate
        dial.onInput = { [weak self] report, timestamp, configurationGeneration in
            let token = gate.token
            DispatchQueue.main.async {
                guard let self = self, case let .dial(button, rotation) = report else { return }
                let changedApp = self.refreshForegroundApplication()
                guard self.permissions.refresh(), !self.customizationIsActive, !changedApp, gate.accepts(token, timestamp: timestamp) else {
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
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification)
        permissions.onChange = { [weak self] granted in
            guard let self = self else { return }
            self.cancelPendingInput()
            self.refreshModeUI()
            if granted {
                self.permissionWindow?.close()
                self.dial.retryConnection()
            } else {
                self.showPermissionHelp()
            }
        }
        updateConnectionStatus()
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
            self.updateConnectionStatus()
        }
        observers.append((center, observer))
    }

    private func updateConnectionStatus() {
        if !permissions.refresh() {
            menuItems.connectionStatus.title = "Dial paused — Fix Permissions…"
            menuItems.connectionStatus.isEnabled = true
            return
        }
        menuItems.connectionStatus.isEnabled = false
        if let serialNumber = dial.connectedSerialNumber {
            menuItems.connectionStatus.title = "Surface Dial '\(serialNumber)' connected"
        }
        else {
            menuItems.connectionStatus.title = "No Surface Dial connected"
        }
    }
    
    private func refreshModeUI() {
        dynamicMenuItems.forEach { menu.removeItem($0) }
        dynamicMenuItems.removeAll()
        let dial = modeContext.resolvedDial
        let selected = modeContext.currentSlice?.id
        func item(for slice: SliceDefinition) -> NSMenuItem {
            let item = NSMenuItem(title: slice.title, action: #selector(setSlice(sender:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = permissions.isGranted
            item.representedObject = slice.id
            item.state = slice.id == selected ? .on : .off
            item.toolTip = slice.usageHelp
            return item
        }
        for slice in dial.standardSlices { dynamicMenuItems.append(item(for: slice)) }
        if !dial.applicationSlices.isEmpty, let app = modeContext.application {
            let parent = NSMenuItem(title: app.displayName)
            parent.submenu = NSMenu()
            parent.submenu?.autoenablesItems = false
            parent.isEnabled = permissions.isGranted
            for slice in dial.applicationSlices { parent.submenu?.addItem(item(for: slice)) }
            parent.state = dial.applicationSlices.contains { $0.id == selected } ? .on : .off
            dynamicMenuItems.append(parent)
        }
        if dial.actionCount == 0 {
            let empty = NSMenuItem(title: "No enabled slices")
            empty.isEnabled = false
            dynamicMenuItems.append(empty)
        }
        if let insertionIndex = menu.items.firstIndex(of: menuItems.customize) {
            for (offset, item) in dynamicMenuItems.enumerated() { menu.insertItem(item, at: insertionIndex + offset) }
        }
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
        if !permissions.isGranted {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Mac Dial permission required")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
            button.toolTip = "Mac Dial is paused. Open the menu and choose Fix Permissions."
            button.setAccessibilityHelp(button.toolTip)
            return
        }
        let slice = modeContext.currentSlice
        switch slice?.builtInMode {
        case .scrolling?: button.image = #imageLiteral(resourceName: "icon-scroll")
        case .playback?: button.image = #imageLiteral(resourceName: "icon-playback")
        default:
            button.image = NSImage(systemSymbolName: slice?.symbolName ?? "circle", accessibilityDescription: slice?.title)
                ?? NSImage(systemSymbolName: "star", accessibilityDescription: slice?.title)
        }
        button.image?.isTemplate = true
        button.image?.size = NSSize(width: 18, height: 18)
        let context = modeContext.application.map { "\($0.displayName) — " } ?? ""
        button.toolTip = "Mac Dial — \(context)\(slice?.title ?? "No enabled slices"). Hold, release, turn, then click to choose."
            + (slice?.usageHelp.map { " " + $0 } ?? "")
            + (slice?.builtInMode == .scrolling ? " Scroll style: \(scrollController.style.title)." : "")
        button.setAccessibilityHelp(button.toolTip)
        button.imagePosition = .imageLeft
    }

    @objc func showAbout(sender: AnyObject) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSMutableAttributedString(
            string: "Original author: Andreas Karlsson\nFork maintained and extended by David — Diversified Fun\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ])
        credits.append(NSAttributedString(
            string: "Diversified Fun fork on GitHub\n",
            attributes: [
                .link: "https://github.com/diversifiedfun/mac-dial",
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraphStyle
            ]))
        credits.append(NSAttributedString(
            string: "View original project on GitHub",
            attributes: [
                .link: "https://github.com/andreasjhkarlsson/mac-dial",
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraphStyle
            ]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mac Dial",
            .credits: credits
        ])
    }

    @objc private func showPermissionHelp() {
        if permissionWindow == nil {
            permissionWindow = DialPermissionWindow(check: { [weak self] in
                self?.updateConnectionStatus()
                return self?.permissions.isGranted == true
            })
        }
        permissionWindow?.present()
    }

    @objc private func showCustomization() { customizationWindow.present() }
    
    @objc func setMode(sender: AnyObject) {
        let item = sender as! ControllerOptionItem
        cancelPendingInput()
        applyMode(item.option)
    }

    @objc private func setSlice(sender: NSMenuItem) {
        guard let id = sender.representedObject as? SliceID else { return }
        cancelPendingInput()
        _ = applySlice(id)
    }

    func cancelPendingInput() {
        // The store may already contain a new selection/configuration. Cancel
        // every old controller before looking up the next one.
        menuItems.allModeItems.forEach { $0.controller.onCancel() }
        customControllers.values.forEach { $0.onCancel() }
        inputGate.invalidate()
        dial.cancelFeedback()
        input.cancel()
        radialMenu.dismiss()
    }

    @discardableResult
    private func applyMode(_ mode: Mode) -> Bool {
        applySlice(.builtIn(mode))
    }
    
    @discardableResult
    private func applySlice(_ id: SliceID) -> Bool {
        guard permissions.refresh(), !customizationIsActive, !refreshForegroundApplication(), modeContext.selectSlice(id) else { return false }
        return true
    }

    @objc func setSensitivity(sender: AnyObject) {
        let item = sender as! NSMenuItem
        wheelSensitivity = (item.representedObject as! WheelSensitivity)
    }
    
    @objc func setScrollStyle(sender: AnyObject) {
        let item = sender as! MenuOptionItem<ScrollStyle>
        cancelPendingInput()
        scrollController.setStyle(item.option)
    }

    @objc func setScrollDirection(sender: AnyObject) {
        let item = sender as! NSMenuItem
        scrollDirection = (item.representedObject as! ScrollDirection)
    }

    @objc func setMenuPressDuration(sender: AnyObject) {
        let item = sender as! MenuOptionItem<MenuPressDuration>
        menuPressDuration = item.option
    }

    @objc func setRadialMenuStartPosition(sender: AnyObject) {
        let item = sender as! MenuOptionItem<RadialMenuStartPosition>
        radialMenuStartPosition = item.option
    }

    @objc func setRadialMenuAppearance(sender: AnyObject) {
        let item = sender as! MenuOptionItem<RadialMenuAppearance>
        cancelPendingInput()
        radialMenuAppearance = item.option
    }
    
    @objc func setHaptics(sender: AnyObject) {
        let item = sender as! NSMenuItem
        hapticsMode = (item.representedObject as! HapticsMode)
    }

    @objc func quitApp(sender: AnyObject) {
        NSApplication.shared.terminate(self)
    }

}
