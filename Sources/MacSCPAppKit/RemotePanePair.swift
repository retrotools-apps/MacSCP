import Foundation
import Observation
import macSCPCore

/// Window-local presentation of two existing SSH sessions; never owns a connection.
@MainActor
final class RemotePanePair: Identifiable {
    let id = UUID()
    weak var left: SessionTab?
    weak var right: SessionTab?
    private let leftSessionID: UUID
    private let rightSessionID: UUID

    private init(left: SessionTab, right: SessionTab, leftSessionID: UUID, rightSessionID: UUID) {
        self.left = left
        self.right = right
        self.leftSessionID = leftSessionID
        self.rightSessionID = rightSessionID
    }

    static func canJoin(_ left: SessionTab, _ right: SessionTab) -> Bool {
        left !== right && left.connectionViewModel.kind == .ssh && right.connectionViewModel.kind == .ssh
            && left.session != nil && right.session != nil && !left.isDisconnecting && !right.isDisconnecting
    }

    @discardableResult
    static func join(left: SessionTab, right: SessionTab) -> RemotePanePair? {
        guard canJoin(left, right), let leftSession = left.session, let rightSession = right.session else { return nil }
        left.remotePair?.detach()
        right.remotePair?.detach()
        let pair = RemotePanePair(left: left, right: right,
            leftSessionID: leftSession.id, rightSessionID: rightSession.id)
        left.remotePair = pair
        right.remotePair = pair
        return pair
    }

    var liveTabs: (left: SessionTab, right: SessionTab)? {
        guard let left, let right, Self.canJoin(left, right),
              left.session?.id == leftSessionID, right.session?.id == rightSessionID,
              left.remotePair === self, right.remotePair === self else { return nil }
        return (left, right)
    }

    /// Unlinking changes presentation only; already queued copies keep their endpoints.
    func detach() {
        if left?.remotePair === self { left?.remotePair = nil }
        if right?.remotePair === self { right?.remotePair = nil }
    }

    @discardableResult
    func transfer(_ selection: [RemoteFileItem], from source: SessionTab) -> Bool {
        guard let tabs = liveTabs else { return false }
        let destination: SessionTab
        if source === tabs.left { destination = tabs.right }
        else if source === tabs.right { destination = tabs.left }
        else { return false }
        guard let path = destination.session?.remote.currentPath else { return false }
        return RemoteSessionTransfer.enqueue(selection, from: source, to: destination, directory: path)
    }
}

/// The middle of a tab pairs sessions; its edges retain the existing reorder/move gesture.
enum RemotePairDropZone {
    static func isCenter(x: Double, width: Double) -> Bool {
        width.isFinite && x.isFinite && width > 0 && x >= width * 0.22 && x <= width * 0.78
    }
}
