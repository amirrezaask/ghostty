import AppKit

/// A presentation of NSWindowTabGroup, never a second owner of terminal sessions.
/// All terminal actions are supplied by the container and use its existing controller.
final class TerminalTabSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((NSWindow) -> Void)?
    var onClose: ((NSWindow) -> Void)?
    var onRename: ((NSWindow) -> Void)?
    var onMove: ((NSWindow, Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onTabsChanged: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?

    var position: TerminalTabBarPosition = .left {
        didSet { if position != oldValue { needsLayout = true } }
    }

    private struct Tab {
        weak var window: NSWindow?
        let id: ObjectIdentifier
        init(_ window: NSWindow) {
            self.window = window
            id = ObjectIdentifier(window)
        }
    }

    private weak var host: NSWindow?
    private weak var observedGroup: NSWindowTabGroup?
    private var windowObservation: NSKeyValueObservation?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var tabs: [Tab] = []
    private var refreshScheduled = false
    private var updatingSelection = false
    private var resizeStartWidth: CGFloat = 0

    private let table = TerminalTabTableView()
    private let scrollView = NSScrollView()
    private let newTabButton = NSButton(title: "New Tab", target: nil, action: nil)
    private let resizeHandle = TerminalTabResizeHandle()
    private static let dragType = NSPasteboard.PasteboardType("com.ghostty.vertical-tab")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .sourceList
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.onClickSelection = { [weak self] in self?.selectCurrentTab() }
        table.target = self
        table.doubleAction = #selector(renameSelectedTab(_:))
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityLabel("Terminal tabs")
        table.identifier = .init("vertical-tab-list")

        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        newTabButton.bezelStyle = .rounded
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newTabButton.imagePosition = .imageLeading
        newTabButton.identifier = .init("vertical-tab-new")
        addSubview(newTabButton)

        resizeHandle.onStart = { [weak self] in
            guard let self else { return }
            self.resizeStartWidth = self.bounds.width
        }
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            let direction: CGFloat = self.position == .right ? -1 : 1
            self.onResize?(self.resizeStartWidth + direction * delta)
        }
        addSubview(resizeHandle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }

    override func layout() {
        super.layout()
        let handleWidth = min(bounds.width, TerminalTabBarGeometry.resizeHandleWidth)
        let contentX = position == .right ? handleWidth : 0
        let contentWidth = max(0, bounds.width - handleWidth)
        scrollView.frame = NSRect(x: contentX, y: 44, width: contentWidth, height: max(0, bounds.height - 44))
        newTabButton.frame = NSRect(x: contentX + 8, y: 8, width: max(0, contentWidth - 16), height: 28)
        resizeHandle.frame = NSRect(
            x: position == .right ? 0 : contentWidth, y: 0, width: handleWidth, height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    /// Detaching clears all observations and weak snapshots. Hidden/top-mode
    /// windows don't materialize tabGroup or keep title observers alive.
    func attach(to window: NSWindow?) {
        guard host !== window else { return }
        windowObservation = nil
        groupObservations.removeAll()
        titleObservations.removeAll()
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        observedGroup = nil
        tabs.removeAll()
        host = window
        guard let window else {
            table.reloadData()
            return
        }
        windowObservation = window.observe(\.tabGroup, options: [.new]) { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.willCloseNotification] {
            notifications.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self, let changed = notification.object as? NSWindow else { return }
                if changed === self.host || self.tabs.contains(where: { $0.window === changed }) {
                    self.scheduleRefresh()
                }
            })
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let host else { return }
        let group = host.tabGroup
        if observedGroup !== group {
            groupObservations.removeAll()
            observedGroup = group
            if let group {
                groupObservations = [
                    group.observe(\.windows, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
                    group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
                ]
            }
        }
        // Only the displayed tab needs title observers and a rendered table.
        guard group?.selectedWindow == nil || group?.selectedWindow === host else {
            titleObservations.removeAll()
            return
        }
        let windows = group?.windows ?? [host]
        let identities = windows.map(ObjectIdentifier.init)
        if tabs.map(\.id) != identities || titleObservations.isEmpty {
            tabs = windows.map(Tab.init)
            titleObservations = windows.map { window in
                window.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() }
            }
        }
        updatingSelection = true
        table.reloadData()
        if let selected = windows.firstIndex(where: { $0 === (group?.selectedWindow ?? host) }) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        }
        updatingSelection = false
        onTabsChanged?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tabs.indices.contains(row), let window = tabs[row].window else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("vertical-tab-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TerminalTabCell) ?? TerminalTabCell()
        cell.identifier = identifier
        cell.configure(title: window.title)
        cell.onClose = { [weak self, weak window] in
            guard let self, let window, self.contains(window) else { return }
            self.onClose?(window)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // During a drag we must not select another native window: doing so
        // replaces the content view that owns the drag source halfway through it.
        guard !table.isTrackingMouse else { return }
        selectCurrentTab()
    }

    private func selectCurrentTab() {
        guard !updatingSelection, let window = window(at: table.selectedRow), contains(window) else { return }
        onSelect?(window)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        table.didBeginDrag = true
    }

    private func window(at row: Int) -> NSWindow? {
        guard tabs.indices.contains(row) else { return nil }
        return tabs[row].window
    }

    private func contains(_ window: NSWindow) -> Bool {
        guard let host else { return false }
        return (host.tabGroup?.windows ?? [host]).contains { $0 === window }
    }

    @objc private func newTab(_ sender: Any?) { onNewTab?() }

    @objc private func renameSelectedTab(_ sender: Any?) {
        guard let window = window(at: table.clickedRow), contains(window) else { return }
        onRename?(window)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let window = window(at: table.clickedRow), contains(window) else { return }
        // The represented value is an identity, not a retained window or stale row.
        for (title, action) in [("Rename Tab…", #selector(renameTabFromMenu(_:))),
                                ("Close Tab", #selector(closeTabFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = String(describing: ObjectIdentifier(window))
            menu.addItem(item)
        }
    }

    private func menuWindow(_ sender: NSMenuItem) -> NSWindow? {
        guard let identity = sender.representedObject as? String,
              let window = tabs.first(where: { String(describing: $0.id) == identity })?.window,
              contains(window) else { return nil }
        return window
    }

    @objc private func renameTabFromMenu(_ sender: NSMenuItem) {
        if let window = menuWindow(sender) { onRename?(window) }
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        if let window = menuWindow(sender) { onClose?(window) }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let window = window(at: row), contains(window) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(describing: ObjectIdentifier(window)), forType: Self.dragType)
        return item
    }

    private func move(for info: NSDraggingInfo, row: Int) -> (NSWindow, Int)? {
        guard let source = info.draggingSource as? NSTableView, source === table,
              let identity = info.draggingPasteboard.string(forType: Self.dragType),
              let host else { return nil }
        let windows = host.tabGroup?.windows ?? [host]
        // Reject a drop after the displayed ordering changed during the drag.
        guard windows.map(ObjectIdentifier.init) == tabs.map(\.id),
              let index = windows.firstIndex(where: { String(describing: ObjectIdentifier($0)) == identity }),
              let destination = TerminalTabBarGeometry.destinationIndex(source: index, dropRow: row, count: windows.count)
        else { return nil }
        return (windows[index], destination - index)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard operation == .above, move(for: info, row: row) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard operation == .above, let (window, amount) = move(for: info, row: row) else { return false }
        onMove?(window, amount)
        scheduleRefresh()
        return true
    }
}

private final class TerminalTabCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        textField = label
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        for view in [label, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        let title = title.isEmpty ? "Terminal" : title
        label.stringValue = title
        toolTip = title
        closeButton.setAccessibilityLabel("Close tab: \(title)")
        closeButton.toolTip = "Close tab: \(title)"
    }

    @objc private func closeTab(_ sender: Any?) { onClose?() }
}

private final class TerminalTabResizeHandle: NSView {
    var onStart: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private var startX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        onStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - startX)
    }
}

/// Defers click selection until AppKit knows the gesture wasn't a row drag.
private final class TerminalTabTableView: NSTableView {
    var onClickSelection: (() -> Void)?
    private(set) var isTrackingMouse = false
    var didBeginDrag = false

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        didBeginDrag = false
        super.mouseDown(with: event)
        isTrackingMouse = false
        if !didBeginDrag && event.clickCount == 1 { onClickSelection?() }
    }
}
