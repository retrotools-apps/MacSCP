import Foundation

/// Actual bytes consumed by the transfer pipeline, never simulated progress.
public struct DiagnosticThroughputProgress: Sendable, Equatable {
    public enum Phase: Int, Sendable { case preparing, upload, download, cleanup }
    public let phase: Phase
    public let bytes: UInt64
    public let total: UInt64
    public let elapsed: Double
    public var fraction: Double { total == 0 ? 0 : min(1, Double(bytes) / Double(total)) }
    public var megabitsPerSecond: Double { elapsed > 0 ? Double(bytes) * 8 / elapsed / 1_000_000 : 0 }

    public init(phase: Phase, bytes: UInt64 = 0, total: UInt64 = 0, elapsed: Double = 0) {
        self.phase = phase; self.bytes = bytes; self.total = total; self.elapsed = elapsed
    }
}

/// Limits UI delivery to ten samples per second while preserving phase edges.
final class DiagnosticThroughputSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    private let started = ContinuousClock.now
    private let phase: DiagnosticThroughputProgress.Phase
    private let total: UInt64
    private let publish: @Sendable (DiagnosticThroughputProgress) -> Void

    init(_ phase: DiagnosticThroughputProgress.Phase, total: Int,
         publish: @escaping @Sendable (DiagnosticThroughputProgress) -> Void) {
        self.phase = phase; self.total = UInt64(max(0, total)); self.publish = publish
        publish(.init(phase: phase, total: self.total))
    }

    func update(_ progress: TransferProgress) {
        let now = ContinuousClock.now
        let shouldPublish = lock.withLock {
            guard last.duration(to: now) >= .milliseconds(100) || progress.bytesTransferred >= total else { return false }
            last = now
            return true
        }
        if shouldPublish {
            publish(.init(phase: phase, bytes: progress.bytesTransferred, total: total,
                          elapsed: started.duration(to: now).secondsAsDouble))
        }
    }
}
