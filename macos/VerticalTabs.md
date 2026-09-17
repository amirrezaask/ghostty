# Vertical tabs (macOS fork feature)

Choose **Window → Tab Bar Position → Left** or **Right**. Choose **Top** to
restore the normal native tab bar. The choice applies to open terminal windows
and is saved across launches. No terminal sessions are restarted when switching.

The sidebar has scrolling tab titles, selection, close buttons, **New Tab**, and
rename through double-click or the context menu. Drag a row between other rows
to reorder within the same window. Drag the inner divider to resize the sidebar;
its preferred width is saved globally (140–400 points, default 220).

These are macOS application preferences, not Ghostty configuration-file keys.
For a release bundle with the standard bundle identifier, quit the app before
changing them from a shell:

```sh
defaults write com.mitchellh.ghostty TerminalTabBarPosition -string left
defaults write com.mitchellh.ghostty TerminalTabBarWidth -float 240
```

`TerminalTabBarPosition` accepts `top`, `left`, and `right`. An absent or unknown
value falls back to `top`. Debug builds using `GHOSTTY_USER_DEFAULTS_SUITE` use
that isolated suite, just like the rest of the fork. The menu is the preferred
way to update a running app.

## Scope and behavior

This change is for the macOS AppKit application, not the GTK frontend. Quick
Terminal, undecorated windows, the hidden-titlebar style (which disallows native
tabs), and non-native fullscreen retain their existing presentation. In a window
narrower than 300 points, the normal native bar is used temporarily to leave the
terminal usable. Widening the window restores the selected vertical position.

Native `NSWindowTabGroup` remains the source of truth. Existing tab keybindings,
new-tab configuration inheritance, close confirmation, undo, and session
restoration are not replaced. The sidebar routes actions to the existing
controllers, including the fork's protected show-window and tab-movement paths.
Cross-window row dragging is intentionally not accepted. Use the existing window
menu for moving tabs between windows. Native tab colors and the native tab
accessory controls are not reproduced in sidebar rows in this first version.

The terminal's hosting view and split tree are never rebuilt when placement
changes. The default `top` path does not create a sidebar or eagerly access
`tabGroup`. Updates are coalesced from native KVO/notifications, not polled;
only the displayed tab observes the group's titles. Tab/window references in
sidebar snapshots and action closures are weak.

## Tests

The standalone suite compiles the actual sidebar and preferences against AppKit
on macOS. It checks preference persistence and invalid values, idempotent menu
installation, single-tab actions, title updates, observer detachment, and native
tab-group membership. Geometry tests exhaustively cover all insertion boundaries
for groups of 1–25 tabs and ensure resizing leaves terminal space.

```sh
bash macos/Scripts/test-vertical-tabs.sh
```

On Linux, this runs only the five Foundation/geometry tests and explicitly reports
that AppKit tests are skipped. The `Vertical tabs regression tests` workflow runs
the AppKit suite on a macOS runner. It is not a full application build or an
end-to-end GUI test. Tests are also included in the existing Xcode test target.

Build and test the complete application on macOS using the repository's normal
instructions (`macos/AGENTS.md`), including building GhosttyKit first when needed:

```sh
macos/build.nu --action build
macos/build.nu --action test
```

## Manual acceptance checklist

Before merging, validate on the macOS versions and titlebar styles you use:

- Switch Top → Left → Right → Top with one tab and many tabs. Verify only one
  tab bar is visible, the terminal keeps its content, and typing reaches it after
  selecting a row. Check native, transparent, and tabs titlebar styles separately.
- Create, rename, close, undo-close, reorder upward/downward, and use numbered,
  next, and previous tab keybindings. Drag an inactive row without accidentally
  switching tabs before the drag starts. Cancel a drag and verify selection.
- Close a tab with a running process; cancellation must preserve it. Close the
  last tab, merge/detach windows, quit/relaunch with restoration, and verify tab
  ordering. Try both active and inactive rows' close buttons.
- Resize the sidebar on either edge, resize a window below/above 300 points,
  test multiple windows, and enter/exit native fullscreen. Check titlebar buttons,
  split zoom, transparency, and live theme changes for regressions.
- Exercise keyboard-only navigation and VoiceOver labels; verify the sidebar does
  not intercept terminal clicks through the collapsed horizontal bar. Confirm
  Quick Terminal and hidden/undecorated windows remain unchanged.
