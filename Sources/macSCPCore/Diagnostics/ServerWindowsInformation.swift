import Foundation

extension ServerNetworkAddresses {
    /// Encoded PowerShell avoids interpretation by either cmd.exe or a
    /// PowerShell OpenSSH default shell. Paths remain literal data, not code.
    static func windowsCommand(includePublic: Bool, includeSystem: Bool, directory: String) -> String {
        let path = directory.hasPrefix("/") && directory.dropFirst().dropFirst().first == ":"
            ? String(directory.dropFirst()) : directory
        var script = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'SilentlyContinue';\n"
        if includeSystem {
            script += #"""
            try {
              $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
              'os ' + $os.Caption + ' ' + $os.Version
              'kernel Windows ' + $os.Version + ' (build ' + $os.BuildNumber + ')'
              'uptime ' + [math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalSeconds)
              'memory ' + ([uint64]$os.FreePhysicalMemory * 1024) + ' ' + ([uint64]$os.TotalVisibleMemorySize * 1024)
              $accounts = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True AND Disabled=False' -ErrorAction Stop).Count
              if ($null -ne $os.NumberOfUsers) { 'users ' + $os.NumberOfUsers + ' ' + $accounts }
            } catch {}
            try {
              Get-NetIPAddress -AddressState Preferred -ErrorAction Stop | ForEach-Object {
                $alias = $_.InterfaceAlias
                $ip = $_.IPAddress
                if ($alias -notmatch '(?i)loopback|docker|container|veth|cni|podman|wsl' -and $ip -ne '::1' -and $ip -notmatch '^127\.') {
                  'local ' + ($alias -replace '[^a-zA-Z0-9_.-]', '_') + ' ' + $ip
                }
              }
            } catch {}
            """#
            script += "\ntry { $drive = (Get-Item -LiteralPath '" + path.replacingOccurrences(of: "'", with: "''")
                + "' -ErrorAction Stop).PSDrive; if ($null -ne $drive.Free -and $null -ne $drive.Used) { 'disk ' + $drive.Free + ' ' + ($drive.Free + $drive.Used) } } catch {}\n"
        }
        if includePublic {
            script += #"""
            foreach ($uri in @('https://api.ipify.org', 'https://api6.ipify.org')) {
              try { 'public ' + (Invoke-RestMethod -Uri $uri -TimeoutSec 3 -ErrorAction Stop).ToString().Trim() } catch {}
            }
            """#
        }
        script += "\nexit 0"
        let encoded = script.data(using: .utf16LittleEndian)!.base64EncodedString()
        return "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded
    }

    var hasInformation: Bool {
        !system.isEmpty || !local.isEmpty || publicIPv4 != nil || publicIPv6 != nil
    }
}
