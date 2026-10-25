import Darwin
import Foundation
import macSCPCore

/// A suggestion is not a reservation: the tunnel's real bind remains authoritative.
enum TunnelPortSuggestion {
    static func firstAvailable(excluding ports: Set<Int>,
                               canBind: (Int) -> Bool) -> Int? {
        for port in stride(from: 65534, through: 1, by: -1) {
            guard !Task.isCancelled else { return nil }
            if !ports.contains(port), canBind(port) { return port }
        }
        return nil
    }

    static func suggest(bind: String, profiles: [TunnelProfile]) async -> Int? {
        let excluded = Set(profiles.map { TunnelEndpoints.listener($0).port })
        let worker = Task.detached(priority: .userInitiated) {
            // Numeric addresses only: opening the editor must not resolve remote hosts.
            let address = bind.trimmingCharacters(in: .whitespacesAndNewlines)
            let hosts = address == "localhost" ? ["127.0.0.1", "::1"]
                : [address.isEmpty ? "127.0.0.1" : address]
            var endpoints: [Data] = []
            for host in hosts {
                var hints = addrinfo()
                hints.ai_flags = AI_NUMERICHOST
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, "0", &hints, &result) == 0, let result else { return nil as Int? }
                defer { freeaddrinfo(result) }
                var next: UnsafeMutablePointer<addrinfo>? = result
                while let entry = next {
                    if let addr = entry.pointee.ai_addr {
                        endpoints.append(Data(bytes: addr, count: Int(entry.pointee.ai_addrlen)))
                    }
                    next = entry.pointee.ai_next
                }
            }
            guard !endpoints.isEmpty else { return nil as Int? }
            return firstAvailable(excluding: excluded) { port in
                endpoints.allSatisfy { endpoint in
                    var storage = sockaddr_storage()
                    _ = withUnsafeMutableBytes(of: &storage) { destination in
                        endpoint.copyBytes(to: destination)
                    }
                    let family = Int32(storage.ss_family)
                    let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
                    guard descriptor >= 0 else { return false }
                    defer { Darwin.close(descriptor) }
                    return withUnsafeMutablePointer(to: &storage) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                            if family == AF_INET {
                                UnsafeMutableRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
                                    .pointee.sin_port = UInt16(port).bigEndian
                            } else if family == AF_INET6 {
                                UnsafeMutableRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self)
                                    .pointee.sin6_port = UInt16(port).bigEndian
                            } else { return false }
                            return Darwin.bind(descriptor, address, socklen_t(endpoint.count)) == 0
                        }
                    }
                }
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
