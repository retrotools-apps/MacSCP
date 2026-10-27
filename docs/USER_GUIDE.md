# MacSCP user guide

MacSCP 1.0 requires macOS 15 or later. Its interface is available in seven
languages; this guide uses the English control names.

## Connections

Choose **New connection** and select SSH/SFTP, S3-compatible storage or WebDAV.
Save a connection to reuse it from the sidebar or **All connections**.
Double-click a connection card to connect. Tabs own independent file sessions.

SSH supports passwords, private keys and your local SSH agent. Unknown host keys
require explicit confirmation. A changed key is a hard stop: verify the server
identity through a trusted channel before updating a saved key.

Saved connections and tunnels support groups and subgroups. Dissolving a group
keeps its entries. Use the group's color dot to change its color. The sidebar's
group-overview action keeps subgroup headings and ungrouped entries visible.

Import supported OpenSSH configuration entries, Cyberduck SFTP/S3 bookmarks,
WinSCP INI files or MacSCP exports from the Sessions menu. Imports do not reproduce
every OpenSSH directive or every other client's connection setting.

## Files and transfers

The usual workspace shows local files on the left and remote files on the right.
Navigate with the path bar, folder rows or Home/Root/Up actions. Drag files and
folders between panes, use Space, or choose a transfer action from the context menu.
Remote files can also be dragged to Finder.

Each source tab owns its transfer queue. Conflicts offer overwrite, skip or rename.
Bandwidth limits, cancellation and protocol-dependent resume are available.
Resume is not supported for every backend or cross-session operation.

The built-in editor edits UTF-8 text. The viewer reads text or hexadecimal data in
bounded windows rather than downloading a complete remote file. Both open in
independent windows that can be moved, resized and minimized; switching session
tabs leaves them open. Select a file and use **File → View** (F3) or **File → Edit**
(F4). Depending on your keyboard settings, hold Fn to use the function keys.
Use Command-S to save in the editor, Command-F to focus the viewer's search,
Command-G / Shift-Command-G for the next / previous match, and Command-W to close.
Closing a modified editor asks before discarding changes. Disconnecting its
session closes its document windows, so save changes before disconnecting.
SSH directory
search supports literal file-name and content searches. External-editor saves
can upload changes back to the server. Request checksums when needed; their
provenance is shown rather than presenting every available tag as a file hash.

## Pair two remote sessions

Open two SCP sessions, then drag one tab onto the center of the other.
The dragged session becomes the left pane. Edge drops still reorder tabs.
Cross-window pairing first moves the dragged session into the receiving window.

Copy files or folders in either direction using drag and drop, Space, the context
menu or the pane's arrow. The paired header identifies the route:

- **Different endpoints:** contents stream through this Mac using the existing
  connections, without staging a complete local file or sharing credentials.
- **Same SSH endpoint, account and jump/TLS route:** contents are copied on the
  server using its POSIX shell and `cp`. Metadata and folder planning still
  use SFTP. Unsupported server-side operations fail without client fallback.

A common bastion alone does not enable a server-side copy between different
destinations. Different host aliases or shared filesystems are not automatically
recognized as one endpoint. Copies onto the source file, or of a folder into its
own tree, are refused.

**Local / remote view** separates the views without disconnecting or cancelling
queued copies. Closing a destination cancels incoming copies before disconnecting.
Moving a tab or replacing its connection separates the views.

## SSH terminals and tabs

Use **SSH** or **⌘T** to open an external terminal. Terminal, iTerm and other
configured terminal applications run their own SSH connection.

**Disconnect** ends the session while keeping its tab. **⌘W** closes the tab.
**⌘1–9** selects a session tab; **⌃Tab** and **⌃⇧Tab** cycle through them.

## Tunnels

Switch to **Tunnels** and choose **New tunnel**. Select local forwarding,
remote forwarding or SOCKS5, then choose the saved SSH connection and destination.
Keep local listeners on `127.0.0.1` unless wider exposure is deliberate.
Active local HTTP/HTTPS tunnels can open in a browser.

A saved connection can use one jump host and supported TLS-gateway settings.
Each tunnel owns its connection and can remain active independently of file tabs.
Use groups to start or stop related tunnels. Saving a tunnel's changes stops it;
start it again to apply the new configuration.

**Settings → Startup** separates opening MacSCP at login, restoring disconnected
windows and starting configured tunnels. Reconnection is a separate tunnel option.
The menu bar reports status and provides bulk start/stop actions.

## Updates

**Settings → General → Updates** adapts to the installed build:

- GitHub packages offer automatic checks and **Check for Updates**, using signed
  Sparkle feeds and archives. Installation and relaunch require confirmation.
- Store builds leave updates to the Store and show no Sparkle controls.
- Local source builds explain how to rebuild or install a GitHub package instead
  of displaying inactive update controls. A packaged build whose updater cannot
  start offers the GitHub releases page as a manual fallback.

The application menu shows **Check for Updates** only when its updater is
configured. GitHub ad-hoc signatures and provenance attestations do not require
an Apple membership, but do not provide Apple notarization.

## Diagnostics

Disconnected checks cover DNS, ping and the configured TCP endpoint, with separate
jump and destination checks where applicable. Route tracing runs when the
protocol connection fails, not after a successful SSH connection. Silent routers
do not by themselves establish a server outage.

Connected SSH sessions reuse the existing connection for server information:
OS/version, uptime, load, available/total memory and disk, user/account counts and
IPv4/IPv6 addresses where the remote OS exposes them. Recognizable container
interfaces are omitted. Linux container memory limits are respected.

System probes are read-only and require no administrator privileges. Linux and
macOS are supported; the Windows PowerShell fallback still needs live Windows
qualification. Account counts differ by OS and do not uniformly include domains.

Public-IP discovery is optional and off by default. It runs on the server and
may contact ipify, OpenDNS or Google DNS without sending MacSCP credentials.
Enable it explicitly in Settings if appropriate.

**Throughput test** measures upload and download in Mbit/s. It writes, reads back
and removes a temporary server file; configured bandwidth limits apply. Cleanup
errors are reported. This is not an Internet speed test of the Mac.

## Limits and safe sharing

SFTP over SSH, S3 and WebDAV are supported; FTP, SMB and AFP are not. SSH supports
one jump, not an arbitrary multi-hop chain. Route tracing is IPv4-only.
RSA authentication uses SHA-512 signatures; RSA-SHA-256-only servers are not
supported. Multiple agent identities may consume server authentication attempts.

Passwords and passphrases are stored in Keychain. Only one running instance may
own the credential vault for writing; closing that instance releases ownership
for the next one. Portable exports may carry
secrets only under their documented encryption policy; WinSCP export requires a
master password. Diagnostic logs are off by default. Reports can contain hostnames
and paths: inspect them before sharing.

Use GitHub Issues for ordinary bugs and [SECURITY.md](../SECURITY.md) for
suspected vulnerabilities. Do not post credentials or private infrastructure data.


### Contrast and appearance

In Settings → View, choose Low contrast for the original appearance or High
contrast for stronger group surfaces, clearer row separation and filled icon
badges. High contrast uses solid chosen group colors in both the sidebar and
cards, with black or white text and tunnel indicators selected for readability;
selection uses an outline. Group blocks leave space below their last entry, and parent groups
enclose their subgroups with a separate inset. Collapsed group labels stay
vertically centered. The preference is saved and applies to every macSCP window.
Connection and tunnel editors offer
a circular color palette and an icon grid inspired by Reminders. Custom colors
remain available through the color picker.

### Managing tunnels

All tunnels has an Active only switch beneath its heading, separated from
Start all and Stop all. It shows established tunnels, including degraded ones;
connecting and reconnecting tunnels remain visible when the filter is off.
Filtering does not change the scope of the batch start and stop commands.
Right-click a tunnel in the workspace or sidebar to rename, duplicate, edit,
move or delete it. Renaming preserves the running connection. Duplicating opens
an editor with automatic start disabled and proposes a free local port; remote
forwardings require choosing another remote listen port. Saving an edit stops
the edited tunnel; deleting asks for confirmation and stops it.

When Terminal is closed, SSH uses the macOS fresh-launch option to skip saved
windows. When Terminal is already running, the requested session opens in the
existing application. Global preferences and existing windows are preserved.

When a local or SOCKS tunnel fails because its port is occupied, its More actions
(…) and context menus offer **Free port and restart…**. Review the process names
and PIDs before confirming: this terminates those processes, forcibly if needed,
and may discard their unsaved work. macOS requests administrator authorization
when required. If ownership changes or release fails, MacSCP does not restart the
tunnel. Remote forwarding ports cannot be released from the local Mac.

Hiding and showing the connections/tunnels sidebar preserves its current width
within each window, including after switching between these workspaces.

Compact sidebar in Appearance hides group color dots, connection status dots,
protocol badges and associated-tunnel indicators in the connections sidebar.
In the tunnels sidebar it hides group and status dots and the matching generated
“ · port” suffix from tunnel names. Custom identity icons remain visible; full
names, endpoint details and status remain available through tooltips and the
workspace. Switching this preference never renames or edits a saved profile.
