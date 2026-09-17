import AppKit

/// Presentation is an app preference, not a per-surface terminal configuration.
/// Keeping it here avoids changing the core configuration ABI for a macOS-only UI.
final class TerminalTabBarPreferences: NSObject, NSMenuItemValidation {
    static let shared = TerminalTabBarPreferences()
    static let didChange = Notification.Name("TerminalTabBarPreferencesDidChange")
    static let positionKey = "TerminalTabBarPosition"
    static let widthKey = "TerminalTabBarWidth"

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?
    private weak var positionMenu: NSMenu?
    private(set) var position: TerminalTabBarPosition
    private(set) var width: CGFloat

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
        position = .init(storedValue: defaults.string(forKey: Self.positionKey))
        width = TerminalTabBarGeometry.preferredWidth(
            (defaults.object(forKey: Self.widthKey) as? NSNumber)?.doubleValue)
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func setPosition(_ value: TerminalTabBarPosition) {
        guard value != position else { return }
        defaults.set(value.rawValue, forKey: Self.positionKey)
        reload()
    }

    func setWidth(_ value: CGFloat) {
        let value = TerminalTabBarGeometry.preferredWidth(Double(value))
        guard value != width else { return }
        defaults.set(Double(value), forKey: Self.widthKey)
        reload()
    }

    private func reload() {
        let newPosition = TerminalTabBarPosition(storedValue: defaults.string(forKey: Self.positionKey))
        let newWidth = TerminalTabBarGeometry.preferredWidth(
            (defaults.object(forKey: Self.widthKey) as? NSNumber)?.doubleValue)
        guard newPosition != position || newWidth != width else { return }
        position = newPosition
        width = newWidth
        positionMenu?.update()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Called after a terminal attaches, when MainMenu.xib has been loaded.
    func installMenuIfNeeded() {
        guard positionMenu == nil, let windowMenu = NSApp.windowsMenu else { return }
        let menu = NSMenu(title: "Tab Bar Position")
        for position in TerminalTabBarPosition.allCases {
            let title: String
            switch position {
            case .top: title = "Top"
            case .left: title = "Left"
            case .right: title = "Right"
            }
            let item = NSMenuItem(title: title, action: #selector(selectPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
            menu.addItem(item)
        }
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        windowMenu.insertItem(item, at: 0)
        windowMenu.insertItem(.separator(), at: 1)
        positionMenu = menu
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = TerminalTabBarPosition(rawValue: raw) else { return }
        setPosition(position)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = (menuItem.representedObject as? String) == position.rawValue ? .on : .off
        return true
    }
}
