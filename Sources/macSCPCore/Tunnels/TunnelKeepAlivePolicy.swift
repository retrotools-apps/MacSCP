/// TLS gateways can have shorter idle limits than SSH servers. Keep the
/// encrypted stream moving even while no local client is using a tunnel.
public enum TunnelKeepAlivePolicy {
    public static func interval(usesTLS: Bool) -> Int { usesTLS ? 10 : 30 }
}
