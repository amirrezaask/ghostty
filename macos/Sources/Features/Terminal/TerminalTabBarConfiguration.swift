import Foundation

/// Native tab groups remain the source of truth; only their presentation changes.
enum TerminalTabBarPosition: String, CaseIterable {
    case top
    case left
    case right

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .top
    }

    var isVertical: Bool { self != .top }
}

/// Pure layout/drop calculations shared by the AppKit sidebar and its tests.
enum TerminalTabBarGeometry {
    static let defaultWidth: CGFloat = 220
    static let minimumWidth: CGFloat = 140
    static let maximumWidth: CGFloat = 400
    static let minimumTerminalWidth: CGFloat = 160
    static let resizeHandleWidth: CGFloat = 5

    static func preferredWidth(_ value: Double?) -> CGFloat {
        guard let value, value.isFinite else { return defaultWidth }
        return min(maximumWidth, max(minimumWidth, CGFloat(value)))
    }

    /// Small windows may temporarily shrink below the preferred minimum, but
    /// never produce negative constraints or consume the terminal's entire width.
    static func width(preferred: CGFloat, available: CGFloat) -> CGFloat {
        guard available.isFinite, available > 0 else { return 0 }
        return min(preferredWidth(Double(preferred)), max(0, available - minimumTerminalWidth))
    }

    /// NSTableView's drop row is an insertion boundary *before* removal.
    /// Return nil for stale/out-of-range payloads and drops that do not move a tab.
    static func destinationIndex(source: Int, dropRow: Int, count: Int) -> Int? {
        guard count > 0, (0..<count).contains(source), (0...count).contains(dropRow) else { return nil }
        let destination = dropRow > source ? dropRow - 1 : dropRow
        return destination == source ? nil : destination
    }
}
