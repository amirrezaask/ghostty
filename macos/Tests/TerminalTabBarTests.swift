import Foundation
import XCTest
#if VERTICAL_TAB_STANDALONE
@testable import VerticalTabsHarness
#else
@testable import Ghostty
#endif
#if canImport(AppKit)
import AppKit
#endif

final class TerminalTabBarGeometryTests: XCTestCase {
    func testPositionDefaultsAndRoundTrip() {
        XCTAssertEqual(TerminalTabBarPosition(storedValue: nil), .top)
        XCTAssertEqual(TerminalTabBarPosition(storedValue: "invalid"), .top)
        XCTAssertEqual(TerminalTabBarPosition(storedValue: ""), .top)
        for position in TerminalTabBarPosition.allCases {
            XCTAssertEqual(TerminalTabBarPosition(storedValue: position.rawValue), position)
            XCTAssertEqual(position.isVertical, position != .top)
        }
    }

    func testPreferredWidthRejectsInvalidValuesAndClamps() {
        for value: Double? in [nil, .nan, .infinity, -.infinity] {
            XCTAssertEqual(TerminalTabBarGeometry.preferredWidth(value), 220)
        }
        XCTAssertEqual(TerminalTabBarGeometry.preferredWidth(-1), 140)
        XCTAssertEqual(TerminalTabBarGeometry.preferredWidth(0), 140)
        XCTAssertEqual(TerminalTabBarGeometry.preferredWidth(240), 240)
        XCTAssertEqual(TerminalTabBarGeometry.preferredWidth(10000), 400)
    }

    func testWidthAlwaysLeavesTerminalSpace() {
        for available in stride(from: 0, through: 1600, by: 5) {
            for preferred: CGFloat in [-10, 140, 220, 400, 900, .nan, .infinity] {
                let width = TerminalTabBarGeometry.width(preferred: preferred, available: CGFloat(available))
                XCTAssertTrue(width.isFinite)
                XCTAssertGreaterThanOrEqual(width, 0)
                XCTAssertLessThanOrEqual(width, 400)
                XCTAssertLessThanOrEqual(width, max(0, CGFloat(available) - 160))
            }
        }
        for available: CGFloat in [-1, .nan, .infinity] {
            XCTAssertEqual(TerminalTabBarGeometry.width(preferred: 220, available: available), 0)
        }
    }

    func testDropBoundariesAndNoOps() {
        XCTAssertEqual(TerminalTabBarGeometry.destinationIndex(source: 0, dropRow: 4, count: 4), 3)
        XCTAssertEqual(TerminalTabBarGeometry.destinationIndex(source: 3, dropRow: 0, count: 4), 0)
        XCTAssertNil(TerminalTabBarGeometry.destinationIndex(source: 1, dropRow: 1, count: 4))
        XCTAssertNil(TerminalTabBarGeometry.destinationIndex(source: 1, dropRow: 2, count: 4))
        XCTAssertNil(TerminalTabBarGeometry.destinationIndex(source: 0, dropRow: 1, count: 1))
        for (source, row, count) in [(-1, 0, 4), (4, 0, 4), (0, -1, 4), (0, 5, 4), (0, 0, 0), (0, 0, -1)] {
            XCTAssertNil(TerminalTabBarGeometry.destinationIndex(source: source, dropRow: row, count: count))
        }
    }

    func testEveryDropPreservesOrderOfOtherTabs() {
        for count in 1...25 {
            for source in 0..<count {
                for boundary in 0...count {
                    let original = Array(0..<count)
                    // Independent reference: insert a copy at the boundary,
                    // then filter out the original source by its tagged index.
                    var tagged = original.map { (id: $0, original: true) }
                    tagged.insert((id: source, original: false), at: boundary)
                    let expected = tagged.filter { !($0.id == source && $0.original) }.map(\.id)
                    var actual = original
                    if let destination = TerminalTabBarGeometry.destinationIndex(
                        source: source, dropRow: boundary, count: count
                    ) {
                        actual.insert(actual.remove(at: source), at: destination)
                    }
                    XCTAssertEqual(actual, expected, "count=\(count), source=\(source), boundary=\(boundary)")
                }
            }
        }
    }
}

#if canImport(AppKit)
@MainActor
final class TerminalTabBarAppKitTests: XCTestCase {
    func testPreferencesPersistAndRecoverFromMalformedStorage() async throws {
        let suite = "VerticalTabsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("nonsense", forKey: TerminalTabBarPreferences.positionKey)
        defaults.set("wide", forKey: TerminalTabBarPreferences.widthKey)
        let preferences = TerminalTabBarPreferences(defaults: defaults)
        XCTAssertEqual(preferences.position, .top)
        XCTAssertEqual(preferences.width, 220)
        preferences.setPosition(.right)
        preferences.setWidth(280)
        let restored = TerminalTabBarPreferences(defaults: defaults)
        XCTAssertEqual(restored.position, .right)
        XCTAssertEqual(restored.width, 280)
        preferences.setWidth(10000)
        XCTAssertEqual(preferences.width, 400)
    }

    func testMenuInstallationIsIdempotentAndReflectsSelection() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.windowsMenu
        let menu = NSMenu(title: "Window")
        NSApp.windowsMenu = menu
        defer { NSApp.windowsMenu = previousMenu }
        let suite = "VerticalTabsMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalTabBarPreferences(defaults: defaults)
        preferences.installMenuIfNeeded()
        preferences.installMenuIfNeeded()
        XCTAssertEqual(menu.items.filter { $0.title == "Tab Bar Position" }.count, 1)
        let choices = menu.items.first?.submenu?.items ?? []
        XCTAssertEqual(choices.map(\.title), ["Top", "Left", "Right"])
        preferences.setPosition(.left)
        for item in choices {
            XCTAssertTrue(preferences.validateMenuItem(item))
            XCTAssertEqual(item.state, item.title == "Left" ? .on : .off)
        }
    }

    func testSingleTabActionsTitleUpdatesAndDetach() async throws {
        _ = NSApplication.shared
        let window = makeWindow(title: "First")
        defer { window.close() }
        let sidebar = TerminalTabSidebar(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        window.contentView = sidebar
        sidebar.attach(to: window)
        sidebar.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendant(NSTableView.self, in: sidebar))
        XCTAssertEqual(table.numberOfRows, 1)
        var selected: NSWindow?
        var closed: NSWindow?
        var created = 0
        sidebar.onSelect = { selected = $0 }
        sidebar.onClose = { closed = $0 }
        sidebar.onNewTab = { created += 1 }
        sidebar.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        XCTAssertTrue(selected === window)
        let cell = try XCTUnwrap(sidebar.tableView(table, viewFor: table.tableColumns.first, row: 0))
        let close = try XCTUnwrap(descendant(NSButton.self, in: cell))
        close.performClick(nil)
        XCTAssertTrue(closed === window)
        let newButton = try XCTUnwrap(sidebar.subviews.compactMap { $0 as? NSButton }.first)
        newButton.performClick(nil)
        XCTAssertEqual(created, 1)
        window.title = "Updated title 🔔"
        drainEvents()
        let updatedCell = try XCTUnwrap(sidebar.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSTableCellView)
        XCTAssertEqual(updatedCell.textField?.stringValue, "Updated title 🔔")
        sidebar.attach(to: nil)
        XCTAssertEqual(table.numberOfRows, 0)
        window.title = "Closed"
        drainEvents()
        XCTAssertEqual(table.numberOfRows, 0)
        // A recycled close-button callback must no longer act on a detached tab.
        closed = nil
        close.performClick(nil)
        XCTAssertNil(closed)
    }

    func testNativeGroupMembershipAndSelectionStayInSync() async throws {
        _ = NSApplication.shared
        let first = makeWindow(title: "First")
        let second = makeWindow(title: "Second")
        let identifier = NSWindow.TabbingIdentifier("VerticalTabsTests.\(UUID().uuidString)")
        first.tabbingIdentifier = identifier
        second.tabbingIdentifier = identifier
        defer {
            second.close()
            first.close()
        }
        let sidebar = TerminalTabSidebar(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        first.contentView = sidebar
        first.makeKeyAndOrderFront(nil)
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        sidebar.attach(to: first)
        drainEvents()
        let table = try XCTUnwrap(descendant(NSTableView.self, in: sidebar))
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 0)
        first.tabGroup?.removeWindow(second)
        drainEvents()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, 0)
        sidebar.attach(to: nil)
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        return window
    }

    private func drainEvents() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        for view in root.subviews {
            if let match = view as? T { return match }
            if let match = descendant(type, in: view) { return match }
        }
        return nil
    }
}
#endif
