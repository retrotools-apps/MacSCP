import AppKit
import SwiftUI

/// Opacity and SwiftUI hit testing do not unregister native List tooltips.
/// Keep each workspace mounted, but hide its hosting subtree in AppKit.
struct SidebarWorkspaceVisibility: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        SidebarWorkspaceHost(content: content, isVisible: isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarWorkspaceRoot<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    let colorScheme: ColorScheme
    let isVisible: Bool

    var body: some View {
        content
            .environment(\.self, environment)
            .environment(\.colorScheme, colorScheme)
            .disabled(!isVisible)
            .accessibilityHidden(!isVisible)
    }
}

private struct SidebarWorkspaceHost<Content: View>: NSViewRepresentable {
    let content: Content
    let isVisible: Bool

    func makeNSView(context: Context) -> NSHostingView<SidebarWorkspaceRoot<Content>> {
        let host = NSHostingView(rootView: root(environment: context.environment))
        host.sizingOptions = []
        host.isHidden = !isVisible
        return host
    }

    func updateNSView(_ host: NSHostingView<SidebarWorkspaceRoot<Content>>, context: Context) {
        if !isVisible, let responder = host.window?.firstResponder as? NSView,
           responder.isDescendant(of: host) {
            host.window?.makeFirstResponder(nil)
        }
        host.rootView = root(environment: context.environment)
        host.isHidden = !isVisible
    }

    private func root(environment: EnvironmentValues) -> SidebarWorkspaceRoot<Content> {
        SidebarWorkspaceRoot(content: content, environment: environment, colorScheme: environment.colorScheme, isVisible: isVisible)
    }
}
