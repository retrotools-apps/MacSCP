import AppKit
import SwiftUI

/// UI-only ownership: windows stay weak and no connection state lives here.
@MainActor
final class WindowPresentation<Window: AnyObject> {
    private struct Entry {
        weak var window: Window?
    }

    private var windows: [Entry] = []
    private weak var preferred: Window?
    private var pending = false
    private var mayOpen = false
    private var opening = false
    private var scheduled = false
    private var openWindow: (() -> Void)?
    private let reveal: (Window) -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    init(
        reveal: @escaping (Window) -> Void,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            Task { @MainActor in action() }
        }
    ) {
        self.reveal = reveal
        self.schedule = schedule
    }

    func setOpener(_ action: @escaping () -> Void) {
        openWindow = action
        resolve()
    }

    func register(_ window: Window) {
        windows.removeAll { $0.window == nil }
        if !windows.contains(where: { $0.window === window }) {
            windows.append(Entry(window: window))
            opening = false
        }
        resolve()
    }

    func didBecomeKey(_ window: Window) {
        if windows.contains(where: { $0.window === window }) { preferred = window }
    }

    func unregister(_ window: Window) {
        windows.removeAll { $0.window == nil || $0.window === window }
        if preferred === window { preferred = nil }
    }

    /// Launch waits for SwiftUI's initial window; it never opens a duplicate.
    func foregroundAtLaunch() {
        pending = true
        resolve()
    }

    func show(preferred window: Window? = nil) {
        if let window { didBecomeKey(window) }
        pending = true
        mayOpen = true
        resolve()
    }

    /// A deliberate Hide overrides an initial foreground request.
    func didHide() {
        pending = false
        mayOpen = false
    }

    private var target: Window? {
        preferred ?? windows.compactMap(\.window).last
    }

    private func resolve() {
        guard pending, !scheduled else { return }
        if target != nil {
            scheduled = true
            schedule { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.pending else { return }
                guard let window = self.target else { self.resolve(); return }
                self.pending = false
                self.mayOpen = false
                self.reveal(window)
            }
        } else if mayOpen, !opening, let openWindow {
            opening = true
            openWindow()
        }
    }
}

@MainActor
enum MainWindowPresentation {
    static let sceneID = "main-sessions"
    static let shared = WindowPresentation<NSWindow> { window in
        let app = NSApplication.shared
        app.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Installed outside credential loading so even the initial unlock UI is raised.
struct MainWindowPresentationHost<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(WindowAccessor { window in
                if let window {
                    MainWindowPresentation.shared.register(window)
                    if window.isKeyWindow { MainWindowPresentation.shared.didBecomeKey(window) }
                }
            })
            .onAppear {
                let opener = openWindow
                MainWindowPresentation.shared.setOpener {
                    opener(id: MainWindowPresentation.sceneID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
                if let window = $0.object as? NSWindow {
                    MainWindowPresentation.shared.didBecomeKey(window)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
                if let window = $0.object as? NSWindow {
                    MainWindowPresentation.shared.unregister(window)
                }
            }
    }
}
