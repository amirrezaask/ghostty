#!/usr/bin/env bash
# Standalone regression suite: real AppKit on macOS; pure geometry on Linux.
# This does not replace building/testing the complete Ghostty application.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/VerticalTabsHarness" "$work/Tests/VerticalTabsHarnessTests"
cp "$root/macos/Sources/Features/Terminal/TerminalTabBarConfiguration.swift" "$work/Sources/VerticalTabsHarness/"
cp "$root/macos/Tests/TerminalTabBarTests.swift" "$work/Tests/VerticalTabsHarnessTests/"
if [[ "$(uname -s)" == Darwin ]]; then
    cp "$root/macos/Sources/Features/Terminal/TerminalTabSidebar.swift" "$work/Sources/VerticalTabsHarness/"
    cp "$root/macos/Sources/Features/Terminal/TerminalTabBarPreferences.swift" "$work/Sources/VerticalTabsHarness/"
    cp "$root/macos/Sources/Helpers/Extensions/UserDefaults+Extension.swift" "$work/Sources/VerticalTabsHarness/"
else
    echo 'AppKit tests are not available on this platform; running geometry tests only.' >&2
fi
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "VerticalTabsHarness",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VerticalTabsHarness"),
        .testTarget(name: "VerticalTabsHarnessTests", dependencies: ["VerticalTabsHarness"],
                    swiftSettings: [.define("VERTICAL_TAB_STANDALONE")]),
    ]
)
PACKAGE
swift test --package-path "$work"
