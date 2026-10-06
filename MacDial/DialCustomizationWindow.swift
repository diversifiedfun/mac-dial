import AppKit
import UniformTypeIdentifiers

private final class CustomizationDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class CustomizationRootView: NSView {
    var arrange: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); arrange?() }
}

// Positions belong to the list, not to a draggable slice. A shared document
// keeps the gutter and native table aligned while scrolling or autoscrolling.
private final class CustomizationSliceListView: NSView {
    private let table: NSTableView
    private let gutter = CustomizationDocumentView()
    private var positions: [NSTextField] = []
    private let gutterWidth: CGFloat = 28
    override var isFlipped: Bool { true }

    init(table: NSTableView) {
        self.table = table
        super.init(frame: .zero)
        autoresizingMask = [.width]
        addSubview(gutter)
        addSubview(table)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reloadPositions() {
        positions.forEach { $0.removeFromSuperview() }
        positions = (0..<table.numberOfRows).map { row in
            let pastCapacity = row >= ResolvedDial.capacity
            let label = customizationLabel(pastCapacity ? "" : String(row + 1), secondary: true)
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            label.alignment = .right
            if !pastCapacity { label.setAccessibilityLabel("Slice row \(row + 1)") }
            gutter.addSubview(label)
            return label
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let scroll = enclosingScrollView { arrange(viewport: scroll.contentSize) }
    }

    func arrange(viewport: NSSize) {
        let rowsHeight = table.numberOfRows == 0 ? 0 : table.rect(ofRow: table.numberOfRows - 1).maxY + 12
        let height = max(viewport.height, rowsHeight)
        setFrameSize(NSSize(width: viewport.width, height: height))
        table.frame = NSRect(x: gutterWidth, y: 0, width: max(1, viewport.width - gutterWidth), height: height)
        if let column = table.tableColumns.first {
            let inset = table.numberOfRows == 0 ? 16 : table.frameOfCell(atColumn: 0, row: 0).minX
            column.width = max(1, table.bounds.width - inset * 2)
        }
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: height)
        for (row, label) in positions.enumerated() {
            let rowRect = table.convert(table.rect(ofRow: row), to: gutter)
            label.frame = NSRect(x: 0, y: rowRect.midY - 11, width: 22, height: 22)
        }
    }
}

final class DialCustomizationWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    let session: DialCustomizationSession
    var onVisibilityChanged: ((Bool) -> Void)?
    let sidebar = NSTableView()
    let sliceTable = NSTableView()
    let preview = RadialMenuView()
    private let root = CustomizationRootView()
    private let sidebarBackground = NSVisualEffectView()
    private let sidebarScroll = NSScrollView()
    private let sliceScroll = NSScrollView()
    private lazy var sliceDocument = CustomizationSliceListView(table: sliceTable)
    private let editor = CustomizationDocumentView()
    private let editorScroll = NSScrollView()
    private let heading = customizationLabel("Standard", size: 20, weight: .semibold)
    private let applicationsHeading = customizationLabel("Applications", size: 20, weight: .semibold)
    private let applicationIdentifier = customizationLabel("", size: 12, secondary: true)
    private let subtitle = customizationLabel("Slices for every application", secondary: true)
    private let previewHeading = customizationLabel("Preview", size: 20, weight: .semibold)
    private let detailsHeading = customizationLabel("Slice Details", size: 20, weight: .semibold)
    private let detailsHelp = customizationLabel("", secondary: true)
    private let capacity = customizationLabel("", secondary: true)
    private let footer = customizationLabel("", secondary: true)
    private let footerScroll = NSScrollView()
    private let footerDocument = CustomizationDocumentView()
    private let emptyList = customizationLabel("No slices yet. Add a slice to get started.", secondary: true)
    private let divider = NSBox()
    private let sidebarDivider = NSBox()
    private var addSliceButton: CustomizationButton!
    private var addAppButton: CustomizationButton!
    private var upButton: CustomizationButton!
    private var downButton: CustomizationButton!
    private var undoButton: CustomizationButton!
    private var redoButton: CustomizationButton!
    private var nameField: NSTextField?
    private var nameID: SliceID?
    private var refreshing = false
    private var choiceSheet: DialChoiceSheet?
    private var recorder: DialShortcutRecorder?
    private var applications: [DiscoveredDialApplication] = []
    private let dragType = NSPasteboard.PasteboardType("local.macdial.slice-order")
    private let dragToken = UUID().uuidString
    private var undoObservers: [NSObjectProtocol] = []

    init(store: SliceConfigurationStore) {
        session = DialCustomizationSession(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Customize Dial"
        window.minSize = NSSize(width: 1080, height: 740)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        window.center()
        root.arrange = { [weak self] in self?.arrange() }
        setup()
        session.onChange = { [weak self] in self?.refresh() }
        session.onError = { [weak self] error in
            guard let window = self?.window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: session.undoManager,
                queue: .main) { [weak self] _ in
                    self?.refreshUndoButtons()
                    if name == .NSUndoManagerDidUndoChange || name == .NSUndoManagerDidRedoChange {
                        self?.revealEditedSelection()
                    }
                })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.onVisibilityChanged?(self.window?.isVisible == true && NSApp.isActive)
            })
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }

    func present() {
        preview.preferredAppearance = RadialMenuAppearance.load()
        onVisibilityChanged?(true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        commitName()
        recorder?.finish(nil)
        choiceSheet?.close()
        onVisibilityChanged?(false)
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session.undoManager }

    private func setup() {
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow
        sidebarBackground.state = .active
        root.addSubview(sidebarBackground)
        for (table, scroll) in [(sidebar, sidebarScroll), (sliceTable, sliceScroll)] {
            let column = NSTableColumn(identifier: .init("main"))
            table.addTableColumn(column)
            table.headerView = nil
            table.delegate = self
            table.dataSource = self
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .regular
            table.columnAutoresizingStyle = table === sliceTable ? .noColumnAutoresizing : .lastColumnOnlyAutoresizingStyle
            table.rowHeight = table === sidebar ? 44 : 36
            table.allowsEmptySelection = false
            table.setAccessibilityLabel(table === sidebar ? "Dial contexts" : "Ordered slices")
            scroll.documentView = table === sliceTable ? sliceDocument : table
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            root.addSubview(scroll)
        }
        let applicationMenu = NSMenu()
        applicationMenu.autoenablesItems = false
        applicationMenu.delegate = self
        sidebar.menu = applicationMenu
        sliceTable.registerForDraggedTypes([dragType])
        sliceTable.setDraggingSourceOperationMask(.move, forLocal: true)
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = false
        root.addSubview(editorScroll)
        footerScroll.documentView = footerDocument
        footerScroll.hasVerticalScroller = true
        footerScroll.autohidesScrollers = true
        footerScroll.drawsBackground = false
        footerDocument.addSubview(footer)
        root.addSubview(footerScroll)
        divider.boxType = .separator
        sidebarDivider.boxType = .separator
        addSliceButton = CustomizationButton("＋ Add Slice") { [weak self] in
            self?.commitName(); self?.session.addSlice()
        }
        addAppButton = CustomizationButton("＋ Add Application…") { [weak self] in self?.showApplications() }
        upButton = CustomizationButton("Move Up") { [weak self] in self?.moveSelected(-1) }
        downButton = CustomizationButton("Move Down") { [weak self] in self?.moveSelected(1) }
        undoButton = CustomizationButton("Undo") { [weak self] in
            self?.commitName(); self?.session.undoManager.undo()
        }
        redoButton = CustomizationButton("Redo") { [weak self] in
            self?.commitName(); self?.session.undoManager.redo()
        }
        applicationIdentifier.isSelectable = true
        applicationIdentifier.lineBreakMode = .byCharWrapping
        applicationIdentifier.setAccessibilityLabel("Application bundle ID")
        for view in [heading, applicationsHeading, applicationIdentifier, subtitle, previewHeading, detailsHeading, detailsHelp, capacity, emptyList, divider, sidebarDivider,
                     preview, addSliceButton!, addAppButton!, upButton!, downButton!, undoButton!, redoButton!] {
            root.addSubview(view)
        }
        preview.setAccessibilityLabel("Dial preview. Select a slice to edit it.")
        preview.onSelectSlice = { [weak self] id in self?.commitName(); self?.session.selectSlice(id) }
        // Hover has no editing side effects. Keyboard arrows browse the same preview.
        preview.onMove = { [weak self] steps in
            guard let self = self else { return }
            var state = ModePickerState(dial: self.session.resolved, application: self.session.application,
                selectedSliceID: self.session.selectedID)
            state.move(by: steps)
            if let id = state.selectedSliceID { self.commitName(); self.session.selectSlice(id) }
        }
    }

    private func arrange() {
        let w = root.bounds.width, h = root.bounds.height
        let sidebarWidth: CGFloat = 320
        let middleWidth: CGFloat = 380
        let middleX = sidebarWidth + 24
        let rightX = sidebarWidth + middleWidth + 28
        let rightWidth = w - rightX - 24
        let previewHeight: CGFloat = 372
        let previewY = h - previewHeight
        let addApplicationY = previewY - 44
        sidebarBackground.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: h)
        applicationsHeading.frame = NSRect(x: 24, y: 28, width: sidebarWidth - 48, height: 32)
        sidebarScroll.frame = NSRect(x: 10, y: 76, width: sidebarWidth - 20, height: max(1, addApplicationY - 84))
        sidebarDivider.frame = NSRect(x: sidebarWidth, y: 0, width: 1, height: h)
        addAppButton.frame = NSRect(x: 12, y: addApplicationY, width: sidebarWidth - 24, height: 30)
        heading.frame = NSRect(x: middleX, y: 28, width: middleWidth - 40, height: 32)
        let identifierHeight = applicationIdentifier.isHidden ? 0 : max(18,
            ceil(applicationIdentifier.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                width: middleWidth - 40, height: 10000)).height))
        let identifierSpace = applicationIdentifier.isHidden ? 0 : identifierHeight + 6
        applicationIdentifier.frame = NSRect(x: middleX, y: 64, width: middleWidth - 40, height: identifierHeight)
        subtitle.frame = NSRect(x: middleX, y: 65 + identifierSpace, width: middleWidth - 40, height: 32)
        // The slice list owns the middle column; the fixed preview now sits
        // beneath Add Application in the wider sidebar.
        let toolbarY = h - 42
        let listTop = 108 + identifierSpace - (subtitle.isHidden ? 38 : 0)
        let listHeight = max(1, toolbarY - listTop - 8)
        sliceScroll.frame = NSRect(x: middleX - 8, y: listTop, width: middleWidth - 32, height: listHeight)
        sliceDocument.arrange(viewport: sliceScroll.contentSize)
        emptyList.frame = NSRect(x: middleX + 8, y: listTop + 24, width: middleWidth - 64, height: 70)
        addSliceButton.frame = NSRect(x: middleX - 4, y: toolbarY, width: 118, height: 30)
        upButton.frame = NSRect(x: middleX + 123, y: toolbarY, width: 92, height: 30)
        downButton.frame = NSRect(x: middleX + 220, y: toolbarY, width: 103, height: 30)

        detailsHeading.frame = NSRect(x: rightX, y: 28, width: rightWidth, height: 32)
        detailsHelp.frame = NSRect(x: rightX, y: 66, width: rightWidth, height: 38)
        editorScroll.frame = NSRect(x: rightX, y: 120, width: rightWidth, height: h - 180)
        editor.setFrameSize(NSSize(width: editorScroll.contentSize.width, height: max(422, editorScroll.contentSize.height)))
        undoButton.frame = NSRect(x: rightX - 4, y: h - 42, width: 80, height: 28)
        redoButton.frame = NSRect(x: rightX + 80, y: h - 42, width: 80, height: 28)
        divider.frame = NSRect(x: sidebarWidth + middleWidth, y: 0, width: 1, height: h)

        let previewX: CGFloat = 16
        let previewWidth = sidebarWidth - previewX * 2
        previewHeading.frame = NSRect(x: previewX, y: previewY, width: 110, height: 28)
        capacity.frame = NSRect(x: previewX + previewWidth - 154, y: previewY + 3, width: 154, height: 26)
        capacity.alignment = .right

        // Only exceptional states need a message below the heading. Normal
        // previews reclaim the former 38-point guidance area for the slice list.
        let textWidth = previewWidth - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let textHeight = ceil((footer.stringValue as NSString).boundingRect(with: NSSize(width: textWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: footer.font!]).height) + 2
        let footerHeight: CGFloat = footer.stringValue.isEmpty ? 0 : 38
        footerScroll.isHidden = footer.stringValue.isEmpty
        footerScroll.frame = NSRect(x: previewX, y: previewY + 34, width: previewWidth, height: footerHeight)
        footerDocument.setFrameSize(NSSize(width: footerScroll.contentSize.width, height: max(footerHeight, textHeight)))
        footer.frame = NSRect(x: 0, y: 0, width: textWidth, height: textHeight)
        let wheelTop = footerScroll.frame.maxY + 0.5
        let wheelBottom = h - 7
        let side = max(1, min(previewWidth, wheelBottom - wheelTop))
        // Normalize the main rim to the same on-screen radius in every context,
        // reserving the outer app ring even for Standard. Dense layouts may have
        // a larger logical radius; compensate for that before fitting the view.
        let coreRadius = RadialMenuLayout(profile: nil).coreRadius
        let previewPadding = RadialMenuLayout.effectPadding / 4
        let reservedDiameter = 2 * (coreRadius + RadialMenuLayout.applicationRingWidth + previewPadding)
        let displayedCoreRadius = side * coreRadius / reservedDiameter
        let layout = preview.menuLayout
        let viewSide = (layout.diameter + previewPadding * 2) * displayedCoreRadius / layout.coreRadius
        preview.fitPresentation(to: NSSize(width: viewSide, height: viewSide), padding: previewPadding)
        preview.setFrameOrigin(NSPoint(x: previewX + (previewWidth - viewSide) / 2,
            y: wheelTop + (wheelBottom - wheelTop - viewSide) / 2))
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        if session.selected == nil { session.selectedID = session.slices.first?.id }
        sidebar.reloadData()
        let sidebarRow = session.store.configuration.applications.firstIndex { $0.id == session.context }.map { $0 + 1 } ?? 0
        sidebar.selectRowIndexes(IndexSet(integer: sidebarRow), byExtendingSelection: false)
        sliceTable.reloadData()
        sliceTable.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<session.slices.count))
        sliceDocument.reloadPositions()
        if let row = session.slices.firstIndex(where: { $0.id == session.selectedID }) {
            sliceTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { sliceTable.deselectAll(nil) }
        heading.stringValue = session.application?.displayName ?? "Standard"
        applicationIdentifier.stringValue = session.application?.bundleIdentifier ?? ""
        applicationIdentifier.isHidden = session.application == nil
        subtitle.stringValue = "Slices for every application · clockwise"
        subtitle.isHidden = session.application != nil
        emptyList.isHidden = !session.slices.isEmpty
        addSliceButton.isEnabled = !session.isReadOnly
        addAppButton.isEnabled = !session.isReadOnly
        let row = session.slices.firstIndex { $0.id == session.selectedID }
        upButton.isEnabled = !session.isReadOnly && row != nil && row! > 0
        downButton.isEnabled = !session.isReadOnly && row != nil && row! < session.slices.count - 1
        arrange()
        rebuildEditor()
        var state = ModePickerState(dial: session.resolved, application: session.application, selectedSliceID: session.selectedID)
        state.isArmed = true
        preview.update(state)
        capacity.stringValue = "\(session.resolved.actionCount) of 18 actions"
        preview.toolTip = "Select a slice in the preview to edit it."
        var notes = ""
        if let selected = session.selected, !session.resolved.contains(selected.id), let fallback = state.selectedSlice {
            notes += "\nPreview highlights \(fallback.title) while \(selected.title) is unavailable."
        }
        if session.resolved.actionCount == 0 { notes += "\n\nNo enabled slices. Enable or add a slice to use the dial." }
        if session.isReadOnly { notes = "This configuration was saved by a newer version of Mac Dial. Update the app to edit it safely." }
        else if case .recovered = session.store.loadStatus { notes += "\n\nSaved settings could not be read. A backup is preserved; your next edit saves these recovered defaults." }
        footer.stringValue = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        footer.toolTip = footer.stringValue
        refreshUndoButtons()
        refreshing = false
        arrange()
    }

    private func revealEditedSelection() {
        root.layoutSubtreeIfNeeded()
        if sidebar.selectedRow >= 0 { sidebar.scrollRowToVisible(sidebar.selectedRow) }
        if sliceTable.selectedRow >= 0 { sliceTable.scrollRowToVisible(sliceTable.selectedRow) }
        editorScroll.contentView.scroll(to: .zero)
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
    }

    private func refreshUndoButtons() {
        undoButton.isEnabled = session.undoManager.canUndo
        redoButton.isEnabled = session.undoManager.canRedo
        undoButton.toolTip = session.undoManager.undoMenuItemTitle
        redoButton.toolTip = session.undoManager.redoMenuItemTitle
    }

    private func rebuildEditor() {
        editor.subviews.forEach { $0.removeFromSuperview() }
        nameField = nil; nameID = nil
        detailsHelp.stringValue = ""
        let width = max(320, editorScroll.contentSize.width)
        func place(_ view: NSView, _ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            view.frame = NSRect(x: x, y: top, width: w, height: h)
            view.autoresizingMask = [.maxYMargin]
            if abs(x + w - width) <= 8 { view.autoresizingMask.insert(.width) }
            editor.addSubview(view)
        }
        guard let slice = session.selected else {
            place(customizationLabel("Select a slice to edit its actions.", secondary: true), 0, 16, width, 48)
            return
        }
        let title = customizationLabel(slice.title, size: 18, weight: .semibold)
        title.autoresizingMask = [.width]
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        let icon = NSImageView()
        icon.image = customizationSymbol(slice.symbolName)
        place(icon, 0, 4, 36, 36)
        place(title, 48, 4, width - 48, 26)
        let isStandard = session.store.configuration.standardSlices.contains { $0.id == slice.id }
        let scope = session.context != nil && isStandard ? "Standard" : ""
        let kind = (slice.id.isCustom ? "Custom slice" : "Default slice")
            + (scope.isEmpty ? "" : " · " + scope)
        place(customizationLabel(kind, size: 11, secondary: true), 48, 31, width - 48, 20)
        let custom: CustomSlice?
        if case .custom(let value) = slice.content { custom = value } else { custom = nil }
        let canEdit = custom != nil && !session.isReadOnly
        let builtInGestures = slice.builtInMode.map(builtInGestureDisplay)
        let name = NSTextField(string: slice.title)
        name.delegate = self
        name.placeholderString = "Slice name"
        name.setAccessibilityLabel("Slice name")
        name.toolTip = "Up to \(CustomSlice.maximumNameLength) characters, including spaces."
        name.setAccessibilityHelp(name.toolTip)
        name.isEnabled = canEdit
        nameField = name; nameID = custom == nil ? nil : slice.id
        place(customizationLabel("Name"), 0, 70, 90, 24)
        place(name, 100, 67, width - 106, 26)
        place(customizationLabel("Icon"), 0, 110, 90, 24)
        let choose = CustomizationButton("Choose Icon…") { [weak self] in self?.showIcons() }
        choose.image = customizationSymbol(slice.symbolName)
        choose.imagePosition = .imageLeading
        choose.isEnabled = canEdit
        place(choose, 96, 102, width - 98, 32)
        let gestures = ["Rotate left", "Rotate right", "Click", "Double-click"]
        for (index, label) in gestures.enumerated() {
            let top = CGFloat(150 + index * 42)
            place(customizationLabel(label), 0, top + 3, 96, 26)
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let builtInGesture = builtInGestures?[index]
            let action = custom?.gestures.actions[index] ?? .noAction
            if let builtInGesture = builtInGesture {
                popup.addItem(withTitle: builtInGesture.action)
                popup.toolTip = builtInGesture.action
            } else {
                popup.addItems(withTitles: ["No Action", "Keyboard Shortcut", "macOS Action"])
                switch action {
                case .noAction: popup.selectItem(at: 0)
                case .keyboardShortcut: popup.selectItem(at: 1)
                case .macOSAction, .brightnessDown, .brightnessUp: popup.selectItem(at: 2)
                }
            }
            popup.tag = index
            popup.target = self
            popup.action = #selector(changeAction(_:))
            popup.setAccessibilityLabel(label + " action")
            popup.isEnabled = canEdit
            place(popup, 96, top, 165, 30)
            if let systemAction = action.systemAction, custom != nil {
                let systemPopup = NSPopUpButton(frame: .zero, pullsDown: false)
                systemPopup.addItems(withTitles: MacOSAction.allCases.map(\.title))
                systemPopup.selectItem(withTitle: systemAction.title)
                systemPopup.tag = index
                systemPopup.target = self
                systemPopup.action = #selector(changeMacOSAction(_:))
                systemPopup.setAccessibilityLabel(label + " macOS action")
                if let shortcut = systemAction.desktopShortcut {
                    systemPopup.toolTip = "Uses the macOS default \(shortcut.displayName). If you changed it in System Settings, use Keyboard Shortcut instead."
                } else {
                    systemPopup.toolTip = "\(systemAction.title) · Requires hardware or an app that supports this system control."
                }
                systemPopup.isEnabled = canEdit
                place(systemPopup, 267, top, width - 270, 30)
                continue
            }
            let record = CustomizationButton(builtInGesture?.shortcut ?? shortcutTitle(action)) { [weak self] in self?.recordGesture(index) }
            record.setAccessibilityLabel(custom == nil ? "\(label) shortcut" : "Record \(label.lowercased()) shortcut")
            record.toolTip = builtInGesture.map { "\($0.action) · \($0.shortcut)" }
            record.isEnabled = canEdit && popup.indexOfSelectedItem == 1
            place(record, 267, top, width - 270, 30)
        }
        let notice = custom == nil
            ? "Default slices can’t be edited. Create a new slice to add custom actions."
            : "Hold opens the dial. Changes save automatically."
        detailsHelp.stringValue = notice
        let delete = CustomizationButton("Delete Slice") { [weak self] in self?.commitName(); self?.session.deleteSelected() }
        delete.isEnabled = canEdit
        place(delete, 0, 326, 108, 26)
        if slice.builtInMode == .lightroomBrush {
            place(customizationLabel("Activate Remove before turning; otherwise turning may change star ratings.", size: 11, secondary: true), 0, 368, width, 48)
        } else if slice.builtInMode == .editwallSequence {
            place(customizationLabel("Open the Sequence view in Editwall first.", size: 11, secondary: true), 0, 368, width, 48)
        }
    }

    private func shortcutTitle(_ action: SliceAction) -> String {
        if case .keyboardShortcut(let shortcut) = action { return shortcut.displayName }
        return "—"
    }
    private func setGesture(_ index: Int, id: SliceID, action: SliceAction) {
        session.updateCustom(id, name: "Change Action") { custom in
            switch index {
            case 0: custom.gestures.rotateLeft = action
            case 1: custom.gestures.rotateRight = action
            case 2: custom.gestures.click = action
            default: custom.gestures.doubleClick = action
            }
        }
    }
    @objc private func changeAction(_ sender: NSPopUpButton) {
        guard let id = session.selectedID else { return }
        commitName()
        switch sender.indexOfSelectedItem {
        case 0: setGesture(sender.tag, id: id, action: .noAction)
        case 1: recordGesture(sender.tag)
        case 2: setGesture(sender.tag, id: id, action: .macOSAction(.brightnessDown))
        default: break
        }
    }
    @objc private func changeMacOSAction(_ sender: NSPopUpButton) {
        guard let id = session.selectedID, MacOSAction.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        commitName()
        setGesture(sender.tag, id: id, action: .macOSAction(MacOSAction.allCases[sender.indexOfSelectedItem]))
    }
    private func recordGesture(_ index: Int) {
        commitName()
        guard let window = window, let id = session.selectedID else { return }
        recorder = DialShortcutRecorder(parent: window, gesture: ["Rotate left", "Rotate right", "Click", "Double-click"][index]) { [weak self] shortcut in
            if let shortcut = shortcut { self?.setGesture(index, id: id, action: .keyboardShortcut(shortcut)) }
            else { self?.refresh() }
            self?.recorder = nil
        }
    }

    func commitName() {
        guard let field = nameField, let id = nameID else { return }
        guard field.stringValue != session.selected?.title else { return }
        let value = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(CustomSlice.maximumNameLength))
        guard !value.isEmpty else {
            field.stringValue = session.selected?.title ?? "New Slice"
            NSSound.beep()
            return
        }
        session.updateCustom(id, name: "Rename Slice") { $0.name = value }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard !refreshing, let field = obj.object as? NSTextField, field === nameField,
              nameID != nil, field.stringValue.count > CustomSlice.maximumNameLength else { return }
        let editor = field.currentEditor() as? NSTextView
        // Let input methods finish composing a character before enforcing the limit.
        guard editor?.hasMarkedText() != true else { return }
        let selection = editor?.selectedRange()
        let limited = String(field.stringValue.prefix(CustomSlice.maximumNameLength))
        field.stringValue = limited
        if let editor = editor, let selection = selection {
            let end = (limited as NSString).length
            let start = min(selection.location, end)
            editor.setSelectedRange(NSRange(location: start, length: min(selection.length, end - start)))
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) { if !refreshing { commitName() } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(sliceTable)
            return true
        }
        return false
    }
    private func moveSelected(_ delta: Int) {
        commitName()
        guard let id = session.selectedID, let row = session.slices.firstIndex(where: { $0.id == id }) else { return }
        session.move(id, to: row + delta)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? session.store.configuration.applications.count + 1 : session.slices.count
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === sliceTable ? 36 : 44
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        if notification.object as? NSTableView === sidebar {
            let row = sidebar.selectedRow
            guard row >= 0 else { return }
            let context = row == 0 ? nil : session.store.configuration.applications[row - 1].id
            commitName()
            session.selectContext(context)
        } else {
            let row = sliceTable.selectedRow
            guard session.slices.indices.contains(row) else { return }
            let id = session.slices[row].id
            commitName()
            session.selectSlice(id)
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = NSView()
        let width = tableColumn?.width ?? tableView.bounds.width
        view.frame = NSRect(x: 0, y: 0, width: width, height: self.tableView(tableView, heightOfRow: row))
        view.autoresizingMask = [.width]
        let icon = NSImageView()
        let title: NSTextField
        if tableView === sidebar {
            let app = row == 0 ? nil : session.store.configuration.applications[row - 1]
            title = customizationLabel(app?.displayName ?? "Standard", weight: .medium)
            icon.image = app.map(applicationIcon) ?? customizationSymbol("gearshape")
            icon.frame = NSRect(x: 8, y: 8, width: 28, height: 28)
            let showsRemove = app?.id == session.context && app != nil
            let textWidth = width - (showsRemove ? 88 : 52)
            title.frame = NSRect(x: 44, y: 12, width: textWidth, height: 22)
            if let app = app, showsRemove {
                let remove = CustomizationButton("") { [weak self] in
                    self?.commitName()
                    self?.session.removeApplication(app.id)
                }
                remove.image = customizationSymbol("trash")
                remove.imagePosition = .imageOnly
                remove.isBordered = false
                remove.toolTip = "Remove \(app.displayName) from Mac Dial"
                remove.setAccessibilityLabel(remove.toolTip)
                remove.isEnabled = !session.isReadOnly
                remove.autoresizingMask = [.minXMargin]
                remove.frame = NSRect(x: width - 36, y: 8, width: 28, height: 28)
                view.addSubview(remove)
            }
        } else {
            let slice = session.slices[row]
            let rowHeight = self.tableView(tableView, heightOfRow: row)
            let isPastCapacity = row >= ResolvedDial.capacity
            let grip = customizationLabel("⠿", size: 20, secondary: true)
            grip.frame = NSRect(x: 2, y: (rowHeight - 28) / 2, width: 18, height: 28)
            view.addSubview(grip)
            icon.image = customizationSymbol(slice.symbolName)
            icon.frame = NSRect(x: 25, y: (rowHeight - 24) / 2, width: 24, height: 24)
            title = customizationLabel(slice.title, weight: .medium)
            title.frame = NSRect(x: 61, y: (rowHeight - 22) / 2, width: width - 131, height: 22)
            let toggle = CustomizationSwitch(enabled: slice.isEnabled, label: "Enable \(slice.title)") { [weak self] enabled in
                self?.commitName()
                self?.session.update(slice.id, name: enabled ? "Enable Slice" : "Disable Slice") { $0.isEnabled = enabled }
            }
            toggle.isEnabled = !session.isReadOnly
            toggle.isHidden = isPastCapacity
            toggle.autoresizingMask = [.minXMargin]
            toggle.frame = NSRect(x: width - 54, y: (rowHeight - 26) / 2, width: 42, height: 26)
            view.addSubview(toggle)
        }
        title.autoresizingMask = [.width]
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = title.stringValue
        view.addSubview(icon); view.addSubview(title)
        return view
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sidebar.menu else { return }
        menu.removeAllItems()
        let index = sidebar.clickedRow - 1
        guard session.store.configuration.applications.indices.contains(index) else { return }
        let app = session.store.configuration.applications[index]
        let remove = NSMenuItem(title: "Remove Application", action: #selector(removeApplicationFromMenu(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = app.id
        remove.isEnabled = !session.isReadOnly
        menu.addItem(remove)
    }

    @objc private func removeApplicationFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        commitName()
        session.removeApplication(id)
    }

    private func applicationIcon(_ app: ApplicationConfiguration) -> NSImage {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) ?? app.applicationURL
        if let url = url, FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        return customizationSymbol("app.dashed")!
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === sliceTable, !session.isReadOnly else { return nil }
        let item = NSPasteboardItem()
        item.setString(dragToken + "|" + (session.context ?? "") + "|" + session.slices[row].id.rawValue, forType: dragType)
        return item
    }
    private func draggedID(_ info: NSDraggingInfo) -> SliceID? {
        guard let value = info.draggingPasteboard.string(forType: dragType) else { return nil }
        let prefix = dragToken + "|" + (session.context ?? "") + "|"
        guard value.hasPrefix(prefix) else { return nil }
        let id = SliceID(rawValue: String(value.dropFirst(prefix.count)))
        return session.slices.contains { $0.id == id } ? id : nil
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === sliceTable, !session.isReadOnly, draggedID(info) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = draggedID(info), let source = session.slices.firstIndex(where: { $0.id == id }) else { return false }
        commitName()
        session.move(id, to: row > source ? row - 1 : row)
        return true
    }

    private func showIcons() {
        commitName()
        guard let window = window, let id = session.selectedID else { return }
        let sheet = DialChoiceSheet(parent: window, title: "Choose Icon", placeholder: "Search symbols or categories") { [weak self] name in
            self?.session.updateCustom(id, name: "Change Icon") { $0.symbolName = name }
        }
        sheet.choices = DialSymbolCatalog.entries.map {
            DialChoiceSheet.Choice(id: $0.name, title: $0.name.replacingOccurrences(of: ".", with: " "), detail: $0.category, image: customizationSymbol($0.name))
        }
        choiceSheet = sheet
    }
    private func showApplications() {
        commitName()
        guard let window = window else { return }
        let sheet = DialChoiceSheet(parent: window, title: "Add Application", placeholder: "Search installed applications",
            browse: { [weak self] in self?.browseApplication() }) { [weak self] id in
                guard let self = self, let app = self.applications.first(where: { $0.id == id }) else { return }
                self.session.addApplication(app.configuration)
            }
        choiceSheet = sheet
        sheet.showLoading()
        DiscoveredDialApplication.discover { [weak self, weak sheet] apps in
            guard let self = self, let sheet = sheet, self.choiceSheet === sheet else { return }
            self.applications = apps
            sheet.choices = apps.map {
                DialChoiceSheet.Choice(id: $0.id, title: $0.name,
                    detail: ($0.running ? "Running · " : "") + $0.id,
                    image: NSWorkspace.shared.icon(forFile: $0.url.path))
            }
        }
    }
    private func browseApplication() {
        choiceSheet?.close()
        guard let window = window else { return }
        let open = NSOpenPanel()
        open.title = "Choose an Application"
        open.allowedContentTypes = [.applicationBundle]
        open.canChooseDirectories = false
        open.canChooseFiles = true
        open.allowsMultipleSelection = false
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            guard let app = DiscoveredDialApplication.read(url) else {
                let alert = NSAlert()
                alert.messageText = "Choose an application bundle"
                alert.informativeText = "This application does not have a bundle identifier."
                alert.beginSheetModal(for: window)
                return
            }
            self?.session.addApplication(app.configuration)
        }
    }
}

// Presentation only: built-in controllers remain the source of action behavior.
// System actions have no single recorded keyboard shortcut to display.
private func builtInGestureDisplay(_ mode: Mode) -> [(action: String, shortcut: String)] {
    switch mode {
    case .scrolling:
        return [("Scroll", "—"), ("Scroll", "—"), ("Cycle scroll style", "—"), ("Cycle style twice", "—")]
    case .playback:
        return [("Volume down", "—"), ("Volume up", "—"), ("Play / pause", "—"), ("Next track", "—")]
    case .zoom:
        return [("Zoom out", "⌘−"), ("Zoom in", "⌘="), ("Reset zoom", "⌘0"), ("Reset zoom twice", "⌘0 × 2")]
    case .undoRedo:
        return [("Undo", "⌘Z"), ("Redo", "⇧⌘Z"), ("Undo", "⌘Z"), ("Redo", "⇧⌘Z")]
    case .brightness:
        return [("Dim", "—"), ("Brighten", "—"), ("Zero / restore display", "—"), ("Toggle display twice", "—")]
    case .lightroomCrop:
        return [("Previous image", "⌘←"), ("Next image", "⌘→"), ("Crop", "R"), ("Toggle Crop twice", "R × 2")]
    case .lightroomFineTune:
        return [("Decrease adjustment", "−"), ("Increase adjustment", "="), ("Before view", "\\"), ("Toggle Before twice", "\\ × 2")]
    case .lightroomBrush:
        return [("Smaller Remove size", "["), ("Larger Remove size", "]"), ("Remove tool", "Q"), ("Toggle tool twice", "Q × 2")]
    case .editwallSequence:
        return [("Previous candidate", "↑"), ("Next candidate", "↓"), ("Next slot", "→"), ("Previous slot", "←")]
    }
}
