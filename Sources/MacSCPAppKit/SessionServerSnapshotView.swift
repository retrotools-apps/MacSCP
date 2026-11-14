import SwiftUI
import macSCPCore

struct SnapshotNetworkColumn: Identifiable, Equatable {
    let id: String
    let title: String
    let addresses: [String]

    var bodyHeight: CGFloat {
        var height: CGFloat = 16
        for address in addresses { height += address.contains(":") ? 13 : 15 }
        return height + CGFloat(max(addresses.count - 1, 0)) * 2
    }

    var minimumWidth: CGFloat {
        var width: CGFloat = 150
        for address in addresses {
            let characterWidth: CGFloat = address.contains(":") ? 6.2 : 7.3
            width = max(width, CGFloat(address.count) * characterWidth + 20)
        }
        return width
    }

    static func columns(for snapshot: SessionServerSnapshot) -> [Self] {
        let grouped = Dictionary(grouping: snapshot.addresses, by: \.interface)
        var columns = grouped.keys.sorted().map { name in
            var seen: Set<String> = []
            let addresses = grouped[name, default: []].map(\.address).filter { seen.insert($0).inserted }
            return Self(id: "interface.\(name)", title: name, addresses: addresses)
        }
        let publicAddresses = [snapshot.publicIPv4, snapshot.publicIPv6].compactMap { $0 }
        if !publicAddresses.isEmpty {
            columns.append(Self(id: "public", title: L10n.string("overview.snapshot.public", "Public addresses"),
                                addresses: publicAddresses))
        }
        return columns
    }
}

struct SessionServerSnapshotView: View {
    let snapshot: SessionServerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SessionOverviewSectionHeading(
                title: L10n.string("overview.snapshot.title", "Last known server information"),
                note: String(format: L10n.string("overview.snapshot.date", "Saved %@ · not live"),
                    snapshot.collectedAt.formatted(date: .abbreviated, time: .shortened)))

            HStack(alignment: .top, spacing: 24) {
                fact(L10n.string("diagnostics.system.os", "Operating system"), value: snapshot.os ?? "—")
                    .frame(maxWidth: .infinity, alignment: .leading)
                fact(L10n.string("overview.snapshot.ram", "RAM"),
                     value: snapshot.memoryBytes.map(SessionServerSnapshot.capacityText) ?? "—")
                    .frame(width: 120, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    caption(L10n.string("overview.snapshot.storage", "Storage"))
                    storage
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let accounts = snapshot.accounts {
                HStack(spacing: 8) {
                    caption(snapshot.accountScope == "regular-local"
                        ? L10n.string("overview.snapshot.accounts", "Local user accounts")
                        : L10n.string("overview.snapshot.accounts.raw", "Login accounts"))
                    Text(String(accounts)).font(.callout.monospacedDigit())
                }
            }
            network
            if !snapshot.storageDevices.isEmpty {
                DisclosureGroup {
                    ForEach(Array(snapshot.storageDevices.enumerated()), id: \.offset) { _, device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Text(SessionServerSnapshot.capacityText(device.totalBytes))
                        }.font(.caption.monospaced()).textSelection(.enabled)
                    }
                } label: {
                    L10n.text("diagnostics.system.devices", "Disks and partitions").font(.caption)
                }
            }
        }
    }

    private var storage: some View {
        Text(snapshot.volumes.isEmpty ? "—" : storageText(snapshot.volumes))
            .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func storageText(_ volumes: [SessionServerSnapshot.Capacity]) -> String {
        volumes.map { "\($0.mount) · \(SessionServerSnapshot.capacityText($0.totalBytes))" }.joined(separator: "\n")
    }

    @ViewBuilder private var network: some View {
        let columns = SnapshotNetworkColumn.columns(for: snapshot)
        if !columns.isEmpty {
            let bodyHeight = columns.map(\.bodyHeight).max() ?? 31
            let minimumWidth = columns.map(\.minimumWidth).reduce(CGFloat(0), +)
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(columns) { column in
                            let width = column.minimumWidth + max(0, geometry.size.width - minimumWidth) / CGFloat(columns.count)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(column.title).font(.caption.weight(.semibold))
                                    .lineLimit(1).help(column.title)
                                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                    .background(DesignTokens.remoteSoft.opacity(0.6))
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(column.addresses, id: \.self) { address in
                                        Text(address)
                                            .font(.system(size: address.contains(":") ? 10 : 12, design: .monospaced))
                                            .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(height: bodyHeight, alignment: .topLeading)
                            }.frame(width: width, alignment: .leading)
                                .overlay(alignment: .trailing) { DesignTokens.hairline.frame(width: 1) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(DesignTokens.hairline, lineWidth: 1) }
            }.frame(height: bodyHeight + 32)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(DesignTokens.inkTertiary)
    }

    private func fact(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            caption(label)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
