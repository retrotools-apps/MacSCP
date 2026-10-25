import AppKit
import SwiftUI
import macSCPCore

/// AppKit-driven menu-bar status item (M11n, re-landed as an `NSStatusItem`).
///
/// The original implementation used SwiftUI's `MenuBarExtra`, which on
/// macOS 26 drives SwiftUI into an infinite `_sizeThatFits` layout loop at
/// launch (100% CPU, unresponsive window) regardless of `.window`/`.menu`
/// style or content — an OS-level SwiftUI regression that cannot be worked
/// around from inside `MenuBarExtra`. This controller drives an
/// `NSStatusItem` with a plain `NSMenu` instead: no SwiftUI in the menu bar,
/// so that bug class can't recur.
///
/// It holds no connection state of its own — it reads everything from the
/// app-wide `MenuBarStatusModel` bridge (which `ContentView` keeps in sync),
/// exactly like the SwiftUI panel did. The menu is rebuilt on every open
/// (`menuNeedsUpdate`). Tunnel state is observed separately so the icon
/// changes color even while the menu is closed.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: MenuBarStatusModel
    private let settingsStore: SettingsStore
    private var statusItem: NSStatusItem?
    /// Process-wide tunnel state; no window-owned connection is moved here.
    private let tunnels = TunnelManager.shared
    private var tunnelActionRunning = false

    init(model: MenuBarStatusModel, settingsStore: SettingsStore) {
        self.model = model
        self.settingsStore = settingsStore
        super.init()
        // Defer the first status-item creation off `App.init` (the status bar
        // is not reliably ready that early) onto the next main-actor turn.
        Task { @MainActor in
            self.applyVisibility()
            self.observe()
        }
    }

    // MARK: - Observation

    /// Tracks the Settings toggle outside of a menu open. Re-armed
    /// after each fire, per the `withObservationTracking` contract.
    private func observe() {
        withObservationTracking {
            _ = settingsStore.menuBarEnabled
            _ = tunnels.states
            _ = tunnels.allProfiles
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyVisibility()
                self.updateIcon()
                self.observe()
            }
        }
    }

    private func applyVisibility() {
        if settingsStore.menuBarEnabled {
            if statusItem == nil { install() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        // The status item is a hit target (clicking it opens the menu below),
        // and the icon is its only label. `accessibilityDescription` is for
        // VoiceOver and produces no hover text, so the button carries its own
        // tooltip. Preserve the application geometry; tint only tunnel state.
        button.image = ApplicationIcon.menuBarImage()
        switch TunnelMenuSummary.tone(states: tunnels.allProfiles.map { tunnels.state(of: $0.id) }) {
        case .neutral: break
        case .healthy: button.image = ApplicationIcon.tintedMenuBarImage(.systemGreen)
        case .warning: button.image = ApplicationIcon.tintedMenuBarImage(.systemOrange)
        }
        button.setAccessibilityLabel("MacSCP")
        button.toolTip = L10n.string("menubar.tooltip", "MacSCP — connections and tunnels")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let scpCount = model.scpCount

        let header = disabledItem(
            L10n.string("menubar.scp.count", "%d SCP connections")
                .replacingOccurrences(of: "%d", with: "\(scpCount)"))
        menu.addItem(header)
        let count = tunnels.allProfiles.filter { if case .active = tunnels.state(of: $0.id) { true } else { false } }.count
        menu.addItem(disabledItem(L10n.string("menubar.tunnels.count", "%d active tunnels")
            .replacingOccurrences(of: "%d", with: "\(count)")))

        menu.addItem(.separator())
        menu.addItem(actionItem(L10n.string("menubar.tunnels.stopAll", "Stop all tunnels"),
            action: #selector(stopAllTunnels), enabled: !tunnelActionRunning
                && TunnelPresentationState.canStopAll(tunnels.allProfiles.map { tunnels.state(of: $0.id) })))
        menu.addItem(actionItem(L10n.string("menubar.connections.stopAll", "Stop all connections"),
            action: #selector(stopAllConnections), enabled: model.canStopConnections))
        menu.addItem(actionItem(L10n.string("menubar.tunnels.startAutomated", "Start all automated tunnels"),
            action: #selector(startAllAutomatedTunnels), enabled: !tunnelActionRunning
                && tunnels.allProfiles.contains { $0.autoStart != .off && !TunnelManager.Aggregate.isRunning(tunnels.state(of: $0.id)) }))
        menu.addItem(.separator())
        let show = NSMenuItem(
            title: L10n.string("menubar.show.window", "Show MacSCP"),
            action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
    }

    private func actionItem(_ title: String, action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func stopAllTunnels() {
        guard !tunnelActionRunning else { return }
        tunnelActionRunning = true
        Task {
            defer { tunnelActionRunning = false }
            await tunnels.stopAll()
        }
    }

    @objc private func startAllAutomatedTunnels() {
        guard !tunnelActionRunning else { return }
        tunnelActionRunning = true
        Task {
            defer { tunnelActionRunning = false }
            await tunnels.startAllAutomated()
        }
    }

    @objc private func stopAllConnections() {
        Task { await model.stopAllConnections() }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }


    @objc private func showMainWindow() {
        MainWindowPresentation.shared.show()
    }
}
