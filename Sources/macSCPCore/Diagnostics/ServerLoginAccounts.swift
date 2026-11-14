import Foundation

/// Local regular users, rather than every passwd entry with an interactive shell.
/// NSS directory enumeration can be slow and includes service and root accounts.
enum ServerLoginAccounts {
    static let linuxCommand = command(passwd: "/etc/passwd", loginDefs: "/etc/login.defs")

    static func command(passwd: String, loginDefs: String) -> String {
        "passwd_file=" + PosixQuoting.singleQuoted(passwd) + "\nlogin_defs=" + PosixQuoting.singleQuoted(loginDefs) + "\n" + #"""
    accounts=
    if [ -r "$passwd_file" ]; then
      uid_min=1000; uid_max=60000
      if [ -r "$login_defs" ]; then
        configured=$(awk '$1=="UID_MIN" {lo=$2} $1=="UID_MAX" {hi=$2} END {print lo, hi}' "$login_defs")
        set -- $configured
        case "$1" in ''|*[!0-9]*) ;; *) uid_min=$1;; esac
        case "$2" in ''|*[!0-9]*) ;; *) uid_max=$2;; esac
      fi
      accounts=$(awk -F: -v lo="$uid_min" -v hi="$uid_max" '
        $3>=lo && $3<=hi && $3!=0 && $3!=65534 && $7!="" && $7!~/\/(nologin|false|sync|shutdown|halt)$/ {n++}
        END {print n+0}' "$passwd_file")
    fi
    """#
    }
}
