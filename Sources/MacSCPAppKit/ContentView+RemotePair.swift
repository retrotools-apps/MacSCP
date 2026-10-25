import Foundation
import macSCPCore

extension ContentView {
    /// Import cross-window tabs through the existing ownership-transfer path first.
    /// A pair itself is never registered globally and never creates a connection.
    func pairDroppedTab(_ payload: TabDragPayload, with target: SessionTab) -> Bool {
        let sourceModel = payload.sourceWindowID == windowID
            ? tabsModel : TabRegistry.shared.model(for: payload.sourceWindowID)
        guard tabsModel.tabs.contains(where: { $0 === target }),
              let source = sourceModel?.tabs.first(where: { $0.id == payload.tabID }),
              RemotePanePair.canJoin(source, target) else { return false }
        if payload.sourceWindowID != windowID { acceptDroppedTab(payload) }
        guard tabsModel.tabs.contains(where: { $0 === source }),
              RemotePanePair.join(left: source, right: target) != nil else { return false }
        activate(target.id)
        return true
    }
}
