# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through the repository's
[Security tab → Report a vulnerability](https://github.com/retrotools-apps/MacSCP/security/advisories/new).
Do not disclose exploitable details in public issues or send MacSCP reports
to upstream projects.

Include the MacSCP version, steps to reproduce, observed behavior and potential
impact. A minimal proof of concept is helpful but not required. If you are
unsure whether an issue is a vulnerability, use the private reporting channel.

Do not include passwords, passphrases, private keys or credentials embedded in
URLs. Replace sensitive values with placeholders.

## Supported versions

Only the latest published release receives security fixes. Before reporting,
update MacSCP and check whether the issue still occurs. Include the version
shown in MacSCP → About MacSCP.

There are no separately maintained release branches or backports to older
versions. Security fixes are delivered in subsequent releases.

## Reportable issues

Report vulnerabilities affecting MacSCP's handling of credentials, connections
or updates, including:

- **Credential exposure:** secrets leaked through session or tunnel JSON,
  files, logs, error messages or diagnostic reports instead of being protected
  by macOS Keychain. Explicit exports must follow their documented encryption
  policy; WinSCP INI export requires a master password.
- **SSH host-key bypass:** connecting despite a changed host key or trusting
  an unknown key without explicit confirmation.
- **Transport validation bypass:** accepting an invalid TLS certificate or
  silently downgrading connection security.
- **Update integrity failures:** bypassing Sparkle's feed or archive signature
  checks, or installing an update without confirmation.
- **Unexpected network activity:** undisclosed telemetry or transmission of
  credentials to unintended recipients.

## Exclusions

- Vulnerabilities in a remote server rather than MacSCP, identified only by
  testing a server you do not control.
- Certificates or host keys that MacSCP correctly rejects.
- Attacks requiring existing local access to the user's unlocked macOS account.
  Protection of that account and its Keychain is a macOS security boundary.
- Automated scanner results without a reproducible issue.

## Security reviews

Maintainers periodically review the public source for credential handling,
transport trust, update integrity, unexpected network activity and dependency
risk. Reviews may use static analysis and AI-assisted code review.

These reviews must not be interpreted as an independent certification or as a
substitute for independent penetration testing, runtime testing or review of a
specific deployment.

## Disclosure

Coordinate public disclosure and any requested attribution through the private
report. Validated fixes should include regression tests and a changelog entry.
