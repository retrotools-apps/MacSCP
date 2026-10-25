import Foundation

/// A read-only capability on an already authenticated connection. No extra
/// connection, credential lookup or host-key decision is made by this probe.
public protocol ServerInformationProvider: Sendable {
    func serverInformation(includePublic: Bool, includeSystem: Bool, directory: String) async throws -> ServerNetworkAddresses
}

public struct ServerNetworkAddresses: Sendable, Equatable {
    public struct InterfaceAddress: Sendable, Hashable {
        public let interface: String
        public let address: String
    }

    public let local: [InterfaceAddress]
    public let publicIPv4: String?
    public let publicIPv6: String?
    public let system: [String: String]

    static func parse(_ output: String) -> Self {
        var local: [InterfaceAddress] = []
        var ipv4: String?
        var ipv6: String?
        var system: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if let key = fields.first,
               ["os", "kernel", "uptime", "load", "memory", "disk", "users"].contains(key) {
                let value = fields.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty, value.utf8.count <= 512,
                   !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                    system[key] = value
                }
                continue
            }
            if fields.count == 3, fields[0] == "local" {
                let interface = fields[1].split(separator: "@").first.map(String.init) ?? fields[1]
                guard !["lo", "lo0"].contains(interface),
                      !["docker", "br-", "veth", "virbr", "cni", "flannel", "podman"].contains(where: interface.hasPrefix)
                else { continue }
                let address = fields[2].split(separator: "/").first.map(String.init) ?? ""
                let literal = address.split(separator: "%").first.map(String.init) ?? ""
                guard JumpProbeHost.addressKind(of: literal) != nil,
                      address.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ":.%_-".unicodeScalars.contains($0) }),
                      literal != "::1", !literal.hasPrefix("127."),
                      interface.utf8.count <= 64,
                      interface.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) })
                else { continue }
                let item = InterfaceAddress(interface: interface, address: address)
                if !local.contains(item) { local.append(item) }
            } else if fields.count == 2, fields[0] == "public" {
                switch JumpProbeHost.addressKind(of: fields[1]) {
                case .ipv4: if ipv4 == nil { ipv4 = fields[1] }
                case .ipv6: if ipv6 == nil { ipv6 = fields[1] }
                default: break
                }
            }
        }
        return Self(local: local, publicIPv4: ipv4, publicIPv6: ipv6, system: system)
    }

    /// Fixed commands; the selected directory is passed as one shell-quoted argument.
    /// HTTPS is preferred, with bounded DNS fallbacks. Missing tools/families
    /// leave that result unavailable rather than suggesting the SSH link failed.
    static func command(includePublic: Bool, includeSystem: Bool = false, directory: String = ".") -> String {
        let interfaces = #"""
        export LC_ALL=C
        if command -v ip >/dev/null 2>&1; then
          ip -o addr show up 2>/dev/null | awk '$3 == "inet" || $3 == "inet6" {print "local", $2, $4}'
        elif command -v ifconfig >/dev/null 2>&1; then
          ifconfig -a 2>/dev/null | awk '/^[^ \t]/ {i=$1; sub(/:$/, "", i)} $1 == "inet" || $1 == "inet6" {print "local", i, $2}'
        fi
        """#
        let system = #"""
        if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
          printf 'os macOS '; sw_vers -productVersion 2>/dev/null
          sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print "load", $0}'
          boot=$(sysctl -n kern.boottime 2>/dev/null | awk '{gsub(/,/, "", $4); print $4}')
          now=$(date +%s)
          case "$boot" in ''|*[!0-9]*) ;; *) printf 'uptime %s\n' "$((now-boot))";; esac
          total=$(sysctl -n hw.memsize 2>/dev/null)
          vm_stat 2>/dev/null | awk -v total="$total" '
            /page size of/ {for (i=1;i<=NF;i++) if ($i=="of") page=$(i+1)}
            /^Pages (free|inactive|speculative):/ {gsub(/\./, "", $NF); available+=$NF}
            END {if (page>0 && total>0) printf "memory %.0f %.0f\n", available*page, total}'
          accounts=
          if entries=$(dscl . -list /Users UniqueID 2>/dev/null); then
            accounts=$(printf '%s\n' "$entries" | awk '$2>=500 && $1!="nobody" {n++} END {print n+0}')
          fi
        else
          for f in /etc/os-release /usr/lib/os-release; do
            if [ -r "$f" ]; then awk -F= '$1=="PRETTY_NAME" {sub(/^[^=]*=/, ""); print "os", $0; exit}' "$f"; break; fi
          done
          [ ! -r /proc/uptime ] || awk '{print "uptime", int($1)}' /proc/uptime
          [ ! -r /proc/loadavg ] || awk '{print "load", $1, $2, $3}' /proc/loadavg
          if [ -r /proc/meminfo ]; then
            mem=$(awk '/^MemTotal:/ {t=$2*1024} /^MemAvailable:/ {a=$2*1024}
              END {if(t>0) printf "%.0f %.0f", a, t}' /proc/meminfo)
            set -- $mem; available=$1; total=$2
            for cg in /sys/fs/cgroup /sys/fs/cgroup/memory; do
              limit=; used=
              if [ -r "$cg/memory.max" ] && [ -r "$cg/memory.current" ]; then
                limit=$(cat "$cg/memory.max"); used=$(cat "$cg/memory.current")
              elif [ -r "$cg/memory.limit_in_bytes" ] && [ -r "$cg/memory.usage_in_bytes" ]; then
                limit=$(cat "$cg/memory.limit_in_bytes"); used=$(cat "$cg/memory.usage_in_bytes")
              fi
              case "$limit:$used" in *[!0-9:]*|:|*:) continue;; esac
              mem=$(awk -v a="$available" -v t="$total" -v l="$limit" -v u="$used" 'BEGIN{
                if(l>0 && l<t) {t=l; a=l-u; if(a<0)a=0} printf "%.0f %.0f", a, t}')
              set -- $mem; available=$1; total=$2
            done
            [ -z "$total" ] || printf 'memory %s %s\n' "$available" "$total"
          fi
          accounts=
          if command -v getent >/dev/null 2>&1 && entries=$(getent passwd 2>/dev/null); then
            accounts=$(printf '%s\n' "$entries" | awk -F: '$7!="" && $7!~/\/(nologin|false|sync|shutdown|halt)$/ {n++} END {print n+0}')
          elif [ -r /etc/passwd ]; then
            accounts=$(awk -F: '$7!="" && $7!~/\/(nologin|false|sync|shutdown|halt)$/ {n++} END {print n+0}' /etc/passwd)
          fi
        fi
        printf 'kernel '; uname -sr 2>/dev/null
        if command -v who >/dev/null 2>&1 && people=$(who 2>/dev/null); then
          printf '%s\n' "$people" | awk -v accounts="$accounts" 'NF && !seen[$1]++ {n++} END {print "users", n+0, accounts}'
        fi
        """#
        let path = PosixQuoting.singleQuoted(directory.hasPrefix("/") ? directory : "./" + directory)
        let disk = "\ndf -Pk \(path) 2>/dev/null | awk 'NR==2 {printf \"disk %.0f %.0f\\n\", $4*1024, $2*1024}'\n"
        let local = interfaces + (includeSystem ? "\n" + system + disk : "")
        guard includePublic else { return local }
        return local + "\n" + #"""
        v4=; v6=
        if command -v curl >/dev/null 2>&1; then
          v4=$(curl -q -4 -fsS --noproxy '*' --connect-timeout 2 --max-time 3 --max-filesize 256 --proto '=https' https://api.ipify.org 2>/dev/null)
          v6=$(curl -q -6 -fsS --noproxy '*' --connect-timeout 2 --max-time 3 --max-filesize 256 --proto '=https' https://api6.ipify.org 2>/dev/null)
          [ -z "$v4" ] || printf 'public %s\n' "$v4"
          [ -z "$v6" ] || printf 'public %s\n' "$v6"
        fi
        if [ -z "$v4" ] && command -v host >/dev/null 2>&1; then
          host -W 2 -t A myip.opendns.com resolver1.opendns.com 2>/dev/null | awk '/has address/ {print "public", $NF}'
        fi
        if { [ -z "$v4" ] || [ -z "$v6" ]; } && command -v nslookup >/dev/null 2>&1; then
          nslookup -timeout=2 -retry=1 -type=TXT o-o.myaddr.l.google.com ns1.google.com 2>/dev/null | awk '/text =/ {gsub(/"/, "", $NF); print "public", $NF}'
        fi
        :
        """#
    }
}
