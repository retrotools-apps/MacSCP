import Foundation
import Testing
@testable import macSCPCore

@Suite("Connected server network addresses")
struct ServerNetworkAddressesTests {
    @Test func linuxSummaryGroupsMountedPartitionsAndOmitsLoopsAndDuplicateMounts() async throws {
        let fixture = #"""
        uname() { printf 'Linux\n'; }
        ip() { :; }
        df() {
          case "$1" in
            -B1) printf 'Filesystem 1B-blocks Used\n/dev/sda1 1000 200\n/dev/sda2 2000 800\n/dev/sda1 1000 200\n/dev/md0 9000 4500\n/dev/mapper/fixture-data 8000 4000\n/dev/loop0 100 100\ntmpfs 100 10\n';;
            *) printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/sda1 1000 200 800 20%% /\n';;
          esac
        }
        lsblk_calls=0
        lsblk() {
          lsblk_calls=$((lsblk_calls+1))
          printf '%s\n' '{"blockdevices":[{"name":"/dev/sda1","type":"part","size":1000,"pkname":"/dev/sda"},{"name":"/dev/sda2","type":"part","size":2000,"pkname":"/dev/sda"},{"name":"/dev/md0","type":"raid1","size":9000},{"name":"/dev/mapper/fixture-data","type":"lvm","size":8000},{"name":"/dev/loop0","type":"loop","size":100}]}'
        }
        """#
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(includePublic: false, includeSystem: true)
            + "\nprintf 'lsblk-calls %s\\n' \"$lsblk_calls\"\n")
        let summary = try #require(ServerNetworkAddresses.parse(output).storageSummary)
        #expect(summary.map(\.name) == ["fixture-data", "md0", "sda"])
        #expect(summary.map(\.totalBytes) == [8000, 9000, 3000])
        #expect(summary.map(\.usedBytes) == [4000, 4500, 1000])
        #expect(summary.last?.diagnosticText == "2.9 KiB · 33.3%")
        #expect(output.contains("lsblk-calls 1"))
    }

    @Test func linuxSummaryFallsBackToPosixDfAndKeepsPartitionsWhenParentsAreUnavailable() async throws {
        let fixture = #"""
        uname() { printf 'Linux\n'; }
        ip() { :; }
        df() {
          [ "$1" != -B1 ] || return 1
          printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/fixture1 1000 200 750 20%% /\n'
        }
        lsblk() { return 1; }
        """#
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(includePublic: false, includeSystem: true))
        let summary = try #require(ServerNetworkAddresses.parse(output).storageSummary)
        #expect(summary.map(\.name) == ["fixture1"])
        #expect(summary.first?.totalBytes == 1024000)
        #expect(summary.first?.usedBytes == 204800)
    }

    @Test func groupedStorageDropsInvalidMeasurementsAndKeepsStableOrdering() {
        let output = """
        storage-summary-begin
        storage-group\tsdb\t1000\t100
        storage-group\tsda\t2000\t500
        storage-group\tsda\t1000\t100
        storage-group\tbad\t100\t200
        storage-group\tbad\t-10\t5
        storage-summary-end
        """
        let summary = ServerNetworkAddresses.parse(output).storageSummary
        #expect(summary?.map(\.name) == ["sda", "sdb"])
        #expect(summary?.map(\.totalBytes) == [3000, 1000])
        #expect(summary?.map(\.usedBytes) == [600, 100])
    }

    @Test func preservesMultipleArraysAndUnmountedDevicesWithoutDoubleCountingDuplicates() {
        let output = #"""
        blocks-json-begin
        {"blockdevices":[
          {"name":"/dev/fixture0","type":"disk","size":1000000000000},
          {"name":"/dev/md-fixture1","type":"raid1","size":"2000000000000"},
          {"name":"/dev/md-fixture2","type":"raid5","size":4000000000000},
          {"name":"/dev/fixture0p1","type":"part","size":900000000000},
          {"name":"/dev/md-fixture1","type":"raid1","size":2000000000000}]}
        blocks-json-end
        """#
        let devices = ServerNetworkAddresses.parse(output).storageDevices
        #expect(devices.count == 4)
        #expect(devices.map(\.totalBytes) == [1000000000000, 2000000000000, 4000000000000, 900000000000])
        #expect(devices.map(\.kind) == ["disk", "raid1", "raid5", "part"])
    }

    @Test func readsNativeDiskInventoryIncludingPartitions() throws {
        let plist: [String: Any] = ["AllDisksAndPartitions": [["DeviceIdentifier": "disk0", "Size": 1000000,
            "Partitions": [["DeviceIdentifier": "disk0s1", "Size": 900000]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let output = "blocks-plist-begin\n" + String(decoding: data, as: UTF8.self) + "\nblocks-plist-end"
        #expect(ServerNetworkAddresses.parse(output).storageDevices.map(\.name) == ["/dev/disk0", "/dev/disk0s1"])
    }

    @Test func enumeratesAllMountedVolumesIncludingSeparateStorageArrays() async throws {
        let fixture = #"""
        ip() { :; }
        df() {
          printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          printf '/dev/fixture-root 1000 100 900 10%% /\n'
          printf '/dev/fixture-array1 900000 100000 800000 12%% /data/array one\n'
          printf '/dev/fixture-array2 1800000 200000 1600000 12%% /database\n'
          printf 'tmpfs 100 10 90 10%% /run\n'
        }
        """#
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(includePublic: false, includeSystem: true))
        let result = ServerNetworkAddresses.parse(output)
        #expect(result.volumes.map(\.mount) == ["/", "/data/array one", "/database"])
        #expect(result.volumes.map(\.totalBytes) == [1024000, 921600000, 1843200000])
        #expect(result.volumes.map(\.availableBytes) == [921600, 819200000, 1638400000])
    }

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
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(Set(lines) == Set(["public 203.0.113.4", "public 2001:db8::4"]))
    }

    @Test func publicFamiliesStartIndependentlyRatherThanWaitingForEachOther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = "probe_directory=" + PosixQuoting.singleQuoted(directory.path) + "\n" + #"""
        ip() { :; }
        host() { :; }
        nslookup() { :; }
        curl() {
          case "$2" in
            -4) mine=4; other=6; address=203.0.113.4;;
            -6) mine=6; other=4; address=2001:db8::4;;
          esac
          : > "$probe_directory/$mine"
          attempts=0
          while [ ! -f "$probe_directory/$other" ] && [ "$attempts" -lt 1000 ]; do
            attempts=$((attempts+1)); sleep 0.01
          done
          [ -f "$probe_directory/$other" ] || return 1
          printf '%s' "$address"
        }
        """#
        let output = try await shell(fixture + "\n" + ServerNetworkAddresses.command(includePublic: true))
        let information = ServerNetworkAddresses.parse(output)
        #expect(information.publicIPv4 == "203.0.113.4")
        #expect(information.publicIPv6 == "2001:db8::4")
    }

    private func shell(_ script: String) async throws -> String {
        let result = try await SubprocessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        #expect(result.status == 0)
        return result.stdoutText
    }
}
