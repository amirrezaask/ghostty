import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView
    private var terminalLeftConstraint: NSLayoutConstraint!
    private var terminalRightConstraint: NSLayoutConstraint!
    private var tabSidebar: TerminalTabSidebar?
    private var tabPreferenceObserver: NSObjectProtocol?
    private var tabCloseObserver: NSObjectProtocol?
    private var terminalIsClosing = false

    /// Restore the previous visibility, rather than assuming every native
    /// accessory was visible before vertical tabs were enabled.
    private struct HiddenTabAccessory {
        weak var controller: NSTitlebarAccessoryViewController?
        let wasHidden: Bool
    }
    private var hiddenTabAccessories: [HiddenTabAccessory] = []

    /// Background color applied with glass effect
    private(set) var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        var hostingSize = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            hostingSize = initialContentSize
        }
        if supportedTabBarPosition.isVertical, hostingSize.width >= 0 {
            hostingSize.width += TerminalTabBarPreferences.shared.width
        }
        return hostingSize
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalLeftConstraint = terminalView.leftAnchor.constraint(equalTo: leftAnchor)
        terminalRightConstraint = terminalView.rightAnchor.constraint(equalTo: rightAnchor)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalLeftConstraint,
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalRightConstraint,
        ])
        tabPreferenceObserver = NotificationCenter.default.addObserver(
            forName: TerminalTabBarPreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.invalidateIntrinsicContentSize()
            self?.needsLayout = true
        }
        tabCloseObserver = NotificationCenter.default.addObserver(
            forName: TerminalWindow.terminalWillCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let closingWindow = notification.object as? NSWindow,
                  closingWindow === self.window else { return }
            self.terminalIsClosing = true
            self.tabSidebar?.attach(to: nil)
        }
    }

    deinit {
        if let tabPreferenceObserver { NotificationCenter.default.removeObserver(tabPreferenceObserver) }
        if let tabCloseObserver { NotificationCenter.default.removeObserver(tabCloseObserver) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            tabSidebar?.attach(to: nil)
            restoreNativeTabBar()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        TerminalTabBarPreferences.shared.installMenuIfNeeded()
        updateTabBarPresentation()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        updateTabBarPresentation()
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
    }

    /// Do not access tabGroup on the default/top path: that lazily initializes
    /// relatively expensive native tabbing machinery even for a single window.
    private var supportedTabBarPosition: TerminalTabBarPosition {
        let position = TerminalTabBarPreferences.shared.position
        guard position.isVertical, !terminalIsClosing,
              let window = window as? TerminalWindow,
              window.styleMask.contains(.titled), window.tabbingMode != .disallowed else { return .top }
        if let fullscreen = window.terminalController?.fullscreenStyle,
           fullscreen.isFullscreen && !fullscreen.supportsTabs { return .top }
        return position
    }

    private func updateTabBarPresentation() {
        let position = supportedTabBarPosition
        let width = position.isVertical ? TerminalTabBarGeometry.width(
            preferred: TerminalTabBarPreferences.shared.width, available: bounds.width) : 0
        // Fall back to native tabs in a very narrow window. Keep the preference
        // so widening the window brings back the sidebar automatically.
        guard position.isVertical, width >= TerminalTabBarGeometry.minimumWidth,
              let window = window as? TerminalWindow else {
            tabSidebar?.isHidden = true
            tabSidebar?.attach(to: nil)
            terminalLeftConstraint.constant = 0
            terminalRightConstraint.constant = 0
            restoreNativeTabBar()
            return
        }

        let sidebar: TerminalTabSidebar
        if let existing = tabSidebar {
            sidebar = existing
        } else {
            sidebar = makeTabSidebar()
            tabSidebar = sidebar
            addSubview(sidebar)
        }
        sidebar.isHidden = false
        sidebar.position = position
        sidebar.frame = NSRect(
            x: position == .left ? 0 : bounds.width - width,
            y: 0, width: width, height: max(0, bounds.height - safeAreaInsets.top))
        terminalLeftConstraint.constant = position == .left ? width : 0
        terminalRightConstraint.constant = position == .right ? -width : 0
        sidebar.attach(to: window)

        hiddenTabAccessories.removeAll { $0.controller == nil }
        for accessory in window.titlebarAccessoryViewControllers where window.isTabBar(accessory) {
            if !hiddenTabAccessories.contains(where: { $0.controller === accessory }) {
                hiddenTabAccessories.append(.init(controller: accessory, wasHidden: accessory.isHidden))
            }
            // Collapsing the accessory hides the native bar without dismantling
            // the tab group, session restoration or keyboard navigation.
            if !accessory.isHidden { accessory.isHidden = true }
        }
    }

    private func restoreNativeTabBar() {
        for item in hiddenTabAccessories {
            item.controller?.isHidden = item.wasHidden
        }
        hiddenTabAccessories.removeAll()
    }

    private func makeTabSidebar() -> TerminalTabSidebar {
        let sidebar = TerminalTabSidebar(frame: .zero)
        sidebar.onSelect = { window in
            guard let controller = window.windowController as? TerminalController,
                  controller.showWindowSafely(nil), let surface = controller.focusedSurface else { return }
            DispatchQueue.main.async { [weak surface] in
                guard let surface, surface.window?.isKeyWindow == true else { return }
                Ghostty.moveFocus(to: surface, from: nil)
            }
        }
        sidebar.onClose = { window in
            (window.windowController as? TerminalController)?.closeTab(nil)
        }
        sidebar.onRename = { window in
            guard let controller = window.windowController as? TerminalController,
                  controller.showWindowSafely(nil) else { return }
            controller.promptTabTitle()
        }
        sidebar.onMove = { window, amount in
            guard let controller = window.windowController as? TerminalController,
                  controller.showWindowSafely(nil), let surface = controller.focusedSurface else { return }
            // Reuse the existing action, including the Tahoe tabbing workaround.
            controller.performAction("move_tab:\(amount)", on: surface)
        }
        sidebar.onNewTab = { [weak self] in
            (self?.window?.windowController as? TerminalController)?.newWindowForTab(nil)
        }
        sidebar.onTabsChanged = { [weak self] in
            (self?.window?.windowController as? TerminalController)?.relabelTabs()
            self?.needsLayout = true
        }
        sidebar.onResize = { width in TerminalTabBarPreferences.shared.setWidth(width) }
        return sidebar
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach the glass effect synchronously if missing to prevent flicker when a new tab appears.
        // Existing updates remain deferred, as they can occur during SwiftUI rendering.
        if glassEffectView == nil {
            updateGlassEffectIfNeeded()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}
#endif // compiler(>=6.2)

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    private func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }

        effectView.configure(
            glass: derivedConfig.glass.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
        )
#endif // compiler(>=6.2)
    }

    private func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = windowThemeFrameView
        else {
            return
        }
        effectView.updateTopInset(-themeFrameView.safeAreaInsets.top)
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        let glass: BackportGlass
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                glass = .regular
            case .macosGlassClear:
                glass = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
