# MacSCP user guide

Use MacSCP to browse remote files, transfer documents and manage SSH tunnels.
It requires macOS 15 or later and runs on Apple Silicon and Intel Macs.
The interface is available in seven languages. This guide uses the English
names of buttons and menus.

## Connect to a server

1. Choose **New connection**.
2. Select **SSH/SFTP**, **S3** or **WebDAV**, then enter the server address
   and the authentication details for your account.
3. Save the connection so you can find it again in the sidebar or
   **All connections**.
4. Double-click its card to connect.

For SSH, you can use a password, a private key or your local SSH agent.
Passwords and key passphrases are saved in macOS Keychain.

The first time you connect to an SSH server, MacSCP asks you to confirm its
host key. Check the fingerprint with the server administrator before accepting.
If a previously saved key has changed, MacSCP stops the connection. Verify why
it changed before updating the saved key.

To reuse connections from another client, open the **Sessions** menu and choose
the appropriate import action. You can import supported OpenSSH configuration
entries, Cyberduck SFTP/S3 bookmarks, WinSCP INI files and MacSCP exports.
Review the imported settings before connecting: some options from other clients
are not supported.

## Organize your connections

Use groups and subgroups to keep related connections together. Click a group's
chevron to expand or collapse it, and use its color dot to choose a color.
Dissolving a group keeps the connections it contains.

Open several connections to work in separate tabs. Choose **Disconnect** to
end a file session while keeping its tab available, or press **⌘W** to close
the tab. Use **⌘1–9** to select a tab, or **⌃Tab** and **⌃⇧Tab** to move between tabs.

## Browse and transfer files

The file workspace shows your Mac on the left and the remote server on the right.
Open folders or use the path bar to navigate. **Home**, **Root** and **Up** take
you to common locations.

To upload, drag files or folders from the local pane to the remote pane.
To download, drag them in the opposite direction. You can also select items
and press **Space**, or choose a transfer action from the context menu.
To download directly into a Finder folder, drag remote files to Finder.

Follow progress in the source tab's transfer queue. If a file already exists,
choose whether to overwrite it, skip it or use another name. You can cancel
transfers and set bandwidth limits. Resuming an interrupted transfer is
available only for supported protocols and operations.

### View or edit a file

Select a file, then choose **File → View** (**F3**) or **File → Edit** (**F4**).
Depending on your keyboard settings, you may need to hold **Fn** as well.

The viewer lets you inspect text or hexadecimal data, including parts of large
remote files. The editor is intended for UTF-8 text. Both open in separate
windows, so you can keep a document open while switching tabs.

- Press **⌘S** to save changes in the editor.
- In the viewer, press **⌘F** to search, then **⌘G** or **⇧⌘G** to move between matches.
- Press **⌘W** to close the document window. If it contains unsaved edits,
  MacSCP asks before discarding them.

Save your edits before disconnecting: disconnecting a session closes its viewer
and editor windows. If you use an external editor, saving can upload the modified
file back to the server.

For SSH connections, directory search can find files by name or look for literal
text in their contents. You can also request a checksum to help compare files;
check the displayed checksum type before comparing values.

### Copy between two remote servers

1. Open two SCP sessions.
2. Drag one tab onto the **center** of the other tab. The dragged session
   appears in the left pane. Dropping near a tab's edge reorders tabs instead.
3. Select files and transfer them using drag and drop, **Space**, the context
   menu or the pane's arrow.

The paired header shows the copy route. Between different servers, files pass
through your Mac. When both panes use the same SSH server, account and connection
route, MacSCP can copy directly on that server. Direct copies require a POSIX
shell with `cp`; if the server cannot perform the operation, the copy fails.
Using the same jump host for two different servers does not enable a direct copy.
Different host aliases are not automatically treated as the same server.

Choose **Local / remote view** to return to the usual layout. Both connections
stay open and queued copies continue. Closing a destination tab cancels copies
being sent to it. You cannot copy a file onto itself or a folder into itself.

## Open an SSH terminal

With an SSH connection selected, click **SSH** or press **⌘T**.
MacSCP opens the terminal application configured in Settings, such as Terminal
or iTerm. The terminal has its own SSH session, separate from the file browser.

## Create and manage tunnels

SSH tunnels forward traffic through a saved SSH connection. Switch to
**Tunnels** and choose **New tunnel**.

1. Choose the forwarding type:
   - **Local forwarding** makes a service reachable through a port on your Mac.
   - **Remote forwarding** opens a listening port on the SSH server.
   - **SOCKS5** provides a local proxy for applications configured to use it.
2. Select the saved SSH connection and enter the required ports and destination.
3. Save the tunnel, then choose **Start**.

For local and SOCKS tunnels, use `127.0.0.1` as the listening address to keep
access limited to your Mac. Use another address only if you intend other
machines to reach the port.

Tunnels run independently of file tabs: disconnecting a file session does not
stop its tunnels. Use **Stop** when you no longer need a tunnel. Active local
HTTP and HTTPS tunnels can be opened in your browser.

### Find and change a tunnel

In **All tunnels**, turn on **Active only** to show established tunnels,
including those reporting a degraded connection. Turn it off to see stopped,
connecting and reconnecting tunnels too. **Start all** and **Stop all** apply
to all tunnels, even when the filter is enabled. Use groups to start or stop
related tunnels together.

Right-click a tunnel, or open its **…** menu, to rename, duplicate, edit, move
or delete it. Renaming leaves a running tunnel active. Saving changes in the
editor stops the tunnel; start it again to apply the new settings.

Duplicating opens a new tunnel for you to review before saving. Automatic start
is disabled on the copy. For local tunnels, MacSCP suggests a free port; for
remote forwarding, choose another remote listening port yourself.
Deleting a tunnel asks for confirmation and stops it.

### If a port is already in use

Another application, or an earlier SSH process, may already be using the port.
You can choose a different listening port in the tunnel editor.

For a local or SOCKS tunnel, you can also open **… → Free port and restart…**.
Review the listed application names and process IDs before confirming. This
action terminates those processes, forcibly if necessary, and their unsaved
work may be lost. macOS asks for administrator authorization when needed.
MacSCP restarts the tunnel only after successfully freeing the port.
This action cannot free a port on a remote server.

### Start tunnels automatically

In **Settings → Startup**, choose whether to open MacSCP at login, restore
windows or start configured tunnels. Restored file tabs are disconnected until
you connect them. Configure automatic reconnection separately for each tunnel.
The menu bar icon also provides tunnel status and start/stop actions.

## Customize the display

Open **Settings → View** to adjust the sidebar and contrast.

- Choose **Low contrast** for subtle group backgrounds, or **High contrast**
  for stronger colors and more distinct text and icons.
- Use **Color group backgrounds** to show or hide group colors. Turning it off
  keeps your saved colors available for later.
- Enable **Compact sidebar** for a simpler list. Connection rows hide status
  dots, protocol labels and tunnel indicators. Tunnel rows hide status dots
  and generated port suffixes. Group color dots are also hidden; your chosen
  identity icons remain visible.

Drag the divider to resize the sidebar. Hiding and showing it keeps the width
you chose in that window.

To personalize a connection or tunnel, open its editor and choose a color and
an icon. Pick from the circular palette or use the color picker for a custom
color. The icon grid combines system symbols, Tabler Outline icons and
application logos. Search by name or keyword, or choose a **Family** to narrow
the selection.

## Diagnose a connection problem

Right-click a connection and choose **Diagnose…**, then **Run check**.
You can run checks before connecting to investigate name resolution or server
reachability. If the connection fails, route tracing can help locate the problem;
a router that does not reply does not necessarily indicate an outage.

For connected SSH sessions, diagnostics can also show server information such
as the operating system, uptime, memory, disk space and network addresses.
Available details depend on the server. Linux and macOS are supported; Windows
results may be incomplete. These checks require no administrator privileges.

Public-IP discovery is optional and disabled by default. If you enable it in
Settings, the server may contact ipify, OpenDNS or Google DNS to identify its
public address.

Use **Throughput test** to measure upload and download speeds between your Mac
and the server. The test creates a temporary file on the server, downloads it
and removes it. You need permission to write there, and your configured bandwidth
limits still apply. The result is not a measurement of your Mac's Internet speed.

Use **Copy report** to share the results with an administrator. Review reports
and logs first: they can include server names and paths. Never share passwords
or private keys. Diagnostic logging is disabled by default and can be enabled
in Settings when troubleshooting.

## Keep MacSCP up to date

For GitHub installations, open **Settings → General → Updates** or choose
**Check for Updates** from the application menu. MacSCP asks before installing
an update and relaunching. If automatic updates are unavailable, download a
package from [GitHub Releases](https://github.com/retrotools-apps/MacSCP/releases).
GitHub packages are not Apple-notarized.

Mac App Store installations are updated through the Store. If you built MacSCP
from source, rebuild it to update, or install a GitHub package.

## Compatibility and help

MacSCP supports SFTP over SSH, S3-compatible storage and WebDAV. FTP, SMB and AFP
are not supported. SSH connections can use one jump host and supported TLS-gateway
settings; multi-hop jump chains are not supported. RSA authentication requires
SHA-512 signature support. If SSH agent authentication is rejected after several
attempts, reduce the identities offered by your agent. Route tracing supports
IPv4 only.

When exporting saved connections, follow the export dialog's encryption options
to protect credentials. WinSCP export requires a master password.

Report ordinary bugs through [GitHub Issues](https://github.com/retrotools-apps/MacSCP/issues).
Include the MacSCP version and steps to reproduce the problem, with sensitive
information removed. For a suspected vulnerability, follow the
[security policy](../SECURITY.md).
