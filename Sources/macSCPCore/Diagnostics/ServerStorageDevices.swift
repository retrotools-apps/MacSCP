import Foundation

extension ServerNetworkAddresses {
    public struct StorageDevice: Sendable, Equatable, Codable {
        public let name: String
        public let kind: String
        public let totalBytes: UInt64
        public var parent: String? = nil
    }

    static func storageDevices(in output: String) -> [StorageDevice] {
        var found: [StorageDevice] = []
        func append(name: String?, kind: String?, size: Any?, parent: String? = nil) {
            guard let name, let kind, name.utf8.count <= 1024, !name.isEmpty,
                  kind.utf8.count <= 64, !kind.isEmpty,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !kind.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let size, let bytes = UInt64("\(size)"), bytes > 0,
                  !found.contains(where: { $0.name == name }) else { return }
            found.append(StorageDevice(name: name, kind: kind, totalBytes: bytes, parent: parent))
        }
        func section(_ marker: String) -> Data? {
            guard let start = output.range(of: "\(marker)-begin\n"),
                  let end = output.range(of: "\n\(marker)-end", range: start.upperBound..<output.endIndex)
            else { return nil }
            return String(output[start.upperBound..<end.lowerBound]).data(using: .utf8)
        }
        if let data = section("blocks-json"),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = root["blockdevices"] as? [[String: Any]] {
            for device in devices {
                append(name: device["name"] as? String, kind: device["type"] as? String, size: device["size"], parent: device["pkname"] as? String)
            }
        }
        if let data = section("blocks-plist"),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let disks = root["AllDisksAndPartitions"] as? [[String: Any]] {
            func visit(_ entry: [String: Any], kind: String) {
                append(name: (entry["DeviceIdentifier"] as? String).map { "/dev/" + $0 },
                       kind: kind, size: entry["Size"])
                for child in entry["Partitions"] as? [[String: Any]] ?? [] { visit(child, kind: "partition") }
                for child in entry["APFSVolumes"] as? [[String: Any]] ?? [] { visit(child, kind: "apfs") }
            }
            for disk in disks { visit(disk, kind: "disk") }
        }
        return found
    }

    public struct StorageGroup: Sendable, Equatable {
        public let name: String
        public let totalBytes: UInt64
        public let usedBytes: UInt64

        public var diagnosticText: String {
            let percent = totalBytes > 0 ? 100 * Double(usedBytes) / Double(totalBytes) : 0
            return SessionServerSnapshot.capacityText(totalBytes) + " · " + String(format: "%.1f%%", percent)
        }
    }

    static func storageSummary(in output: String) -> [StorageGroup]? {
        guard output.contains("storage-summary-begin\n"), output.contains("\nstorage-summary-end") else { return nil }
        let metadata = Dictionary(storageDevices(in: output).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seenFilesystems: Set<String> = []
        var totals: [String: (size: UInt64, used: UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, ["storage-group", "storage-filesystem"].contains(fields[0]),
                  !fields[1].isEmpty, fields[1].utf8.count <= 1024,
                  !fields[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let size = UInt64(fields[2]), size > 0, let used = UInt64(fields[3]), used <= size else { continue }
            var name = String(fields[1])
            if fields[0] == "storage-filesystem" {
                guard name.hasPrefix("/dev/"), !name.hasPrefix("/dev/loop"), seenFilesystems.insert(name).inserted else { continue }
                let device = metadata[name]
                guard device?.kind != "loop" else { continue }
                if device?.kind == "part", let parent = device?.parent, !parent.isEmpty {
                    name = (parent as NSString).lastPathComponent
                } else {
                    name = (name as NSString).lastPathComponent
                }
            }
            let previous = totals[name] ?? (0, 0)
            let sum = previous.size.addingReportingOverflow(size)
            let consumption = previous.used.addingReportingOverflow(used)
            guard !sum.overflow, !consumption.overflow else { continue }
            totals[name] = (sum.partialValue, consumption.partialValue)
        }
        return totals.keys.sorted().map {
            StorageGroup(name: $0, totalBytes: totals[$0]!.size, usedBytes: totals[$0]!.used)
        }
    }

    static let storageCommand = #"""
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
      printf 'blocks-plist-begin\n'
      diskutil list -plist 2>/dev/null
      printf '\nblocks-plist-end\n'
    elif [ "$(uname -s 2>/dev/null)" = Linux ]; then
      printf 'storage-summary-begin\n'
      # One metadata pass regardless of the number of mounted filesystems.
      printf 'blocks-json-begin\n'
      lsblk --bytes --paths --json --list --output NAME,TYPE,SIZE,PKNAME 2>/dev/null
      printf '\nblocks-json-end\n'
      if measurements=$(df -B1 --output=source,size,used 2>/dev/null); then
        printf '%s\n' "$measurements" | awk 'NR>1 && $1 ~ /^\/dev\// {printf "storage-filesystem\t%s\t%s\t%s\n", $1, $2, $3}'
      else
        df -Pk 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// {printf "storage-filesystem\t%s\t%.0f\t%.0f\n", $1, $2*1024, $3*1024}'
      fi
      printf '\nstorage-summary-end\n'
    fi
    """#
}
