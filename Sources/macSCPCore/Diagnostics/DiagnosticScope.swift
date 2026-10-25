/// Diagnostic scopes supported by the engine.
/// The application offers a standard diagnostic and a separate transfer test.
public enum DiagnosticScope: String, CaseIterable, Sendable {
    case complete
    case ping
    case trace
    case dial
    case contributions
    case throughput

    enum OptionalStep {
        case tcp, icmp, dial, trace, contributions, throughput
    }

    public var resolvesASecret: Bool {
        runs(.dial) || runs(.contributions) || runs(.throughput)
    }

    func runs(_ step: OptionalStep) -> Bool {
        switch self {
        case .complete: return step != .throughput
        case .ping: return step == .tcp || step == .icmp
        case .trace: return step == .trace
        case .dial: return step == .dial
        case .contributions: return step == .contributions
        case .throughput: return step == .throughput
        }
    }
}
