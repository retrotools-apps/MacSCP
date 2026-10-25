import Foundation
import Testing
@testable import macSCPCore

@Suite("Connected server network addresses")
struct ServerNetworkAddressesTests {
    @Test func keepsIPv4AndIPv6WithoutContainerNoiseOrDuplicateAddresses() {
        let result = ServerNetworkAddresses.parse("""
            local eth0 192.0.2.8/24
            local eth0 2001:db8::8/64
            local eth0 fe80::8%eth0/64
            local eth0 192.0.2.8/24
            local docker0 172.17.0.1/16
            local br-123abc 172.18.0.1/16
            local veth99@if4 fe80::3/64
            local lo 127.0.0.1/8
            local lo0 ::1/128
            local br0 198.51.100.2/24
            """)
        #expect(result.local.map(\.interface) == ["eth0", "eth0", "eth0", "br0"])
        #expect(result.local.map(\.address) == ["192.0.2.8", "2001:db8::8", "fe80::8%eth0", "198.51.100.2"])
    }

    @Test func acceptsOnlyAddressRecordsNotBannersOrDNSResolverAddresses() {
        let result = ServerNetworkAddresses.parse("""
            Server: 8.8.8.8
            local eth0 invalid
            public <html>error</html>
            public 203.0.113.4
            public 2001:db8::4
            public invalid%zone
            """)
        #expect(result.local.isEmpty)
        #expect(result.publicIPv4 == "203.0.113.4")
        #expect(result.publicIPv6 == "2001:db8::4")
    }

    @Test func parsesDistributionAndSystemValuesAsData() {
        let result = ServerNetworkAddresses.parse("""
            os "Debian GNU/Linux 13 (trixie)"
            kernel Linux 6.12.0-amd64
            architecture x86_64
            memory 102400
            disk 204800
            users 7
            ignored unrelated banner
            """)
        #expect(result.system["os"] == "Debian GNU/Linux 13 (trixie)")
        #expect(result.system["kernel"] == "Linux 6.12.0-amd64")
        #expect(result.system["memory"] == "102400")
        #expect(result.system["disk"] == "204800")
        #expect(result.system["users"] == "7")
        #expect(result.system["ignored"] == nil)
    }

    @Test func systemCommandsQuoteTheDirectoryAndDoNotInterpretItAsShellCode() async throws {
        let directory = "/tmp/folder'; printf 'INJECTED\\n'; : '"
        let fixture = """
            ip() { :; }
            df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 10 2 8 20%% /\\n'; }
            uname() { printf 'test-kernel\\n'; }
            """
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(
            includePublic: false, includeSystem: true, directory: directory))
        #expect(output.contains("kernel test-kernel"))
        #expect(!output.split(separator: "\n").contains("INJECTED"))
        #expect(ServerNetworkAddresses.parse(output).system["disk"] == "8192 10240")
    }

    @Test func privateLookupDoesNotContactAnyPublicService() async throws {
        let fixture = """
            ip() { printf '2: eth0 inet 192.0.2.8/24 scope global eth0\\n'; }
            curl() { printf 'public 203.0.113.99\\n'; }
            host() { printf 'unexpected-public-call\\n'; }
            nslookup() { printf 'unexpected-public-call\\n'; }
            """
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(includePublic: false))
        let result = ServerNetworkAddresses.parse(output)
        #expect(result.local.map(\.address) == ["192.0.2.8"])
        #expect(output == "local eth0 192.0.2.8/24\n")
        #expect(result.publicIPv4 == nil && result.publicIPv6 == nil)
    }

    @Test func publicLookupFallsBackToDNSWhenHTTPSIsUnavailable() async throws {
        let fixture = """
            ip() { :; }
            curl() { return 1; }
            host() { printf 'myip.opendns.com has address 203.0.113.4\\n'; }
            nslookup() { printf 'o-o.myaddr.l.google.com text = "2001:db8::4"\\n'; }
            """
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(includePublic: true))
        let result = ServerNetworkAddresses.parse(output)
        #expect(result.publicIPv4 == "203.0.113.4")
        #expect(result.publicIPv6 == "2001:db8::4")
    }

    @Test func publicLookupKeepsBothHTTPSFamiliesWithoutInvokingDNSFallback() async throws {
        let fixture = """
            ip() { :; }
            curl() { case "$2" in -4) printf '203.0.113.4';; -6) printf '2001:db8::4';; esac; }
            host() { printf 'unexpected-dns-call\\n'; }
            nslookup() { printf 'unexpected-dns-call\\n'; }
            """
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(includePublic: true))
        #expect(output == "public 203.0.113.4\npublic 2001:db8::4\n")
    }

    private func shell(_ script: String) async throws -> String {
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        #expect(result.status == 0)
        return result.stdoutText
    }
}
