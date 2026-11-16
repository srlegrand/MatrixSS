# Shared by deploy.sh and test.sh: the list of machines, and reaching them over SSH.
# Runs on Linux and on macOS (whose bash is version 3.2, and whose tools are the BSD ones: nothing newer is used).
#
# connect opens one SSH connection to a machine; everything else the script does there goes through it.
# The first time, it asks for the machine's user name and password. The user name is then remembered in
# machines.txt and the password in the password store of this machine, so later runs ask nothing:
#   macOS            the login keychain
#   Linux with KDE   the KDE wallet (wallet.py)
#   other Linux      the desktop keyring, where secret-tool is installed (sudo apt install libsecret-tools)
# Passwords are never written to a file or put on a command line. Without a password store they are asked
# for on every run. A password that has stopped working is asked for again.
# Machines that have this machine's SSH key (ssh-copy-id user@address) need no password to log in.
# ./deploy.sh --forget drops the remembered passwords.

machines_file=$here/machines.txt
service=matrix-screensaver
this=$(hostname -s 2>/dev/null || hostname)
case $(uname -s) in Darwin) this_system=macos ;; *) this_system=linux ;; esac
control=$(mktemp -d) || exit 1
ssh_options=(-o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -o ControlPath="$control/%C")
connected=()

# The lines of machines.txt: name, address, system (linux, windows or macos), user.
machines() {
    [ -f "$machines_file" ] || return 0
    tr -d '\r' < "$machines_file" | sed 's/[[:space:]]*#.*//' | awk 'NF >= 4 { if ($3 == "kubuntu") $3 = "linux"; print $1, $2, $3, $4 }'
}

usage() { sed -n '2,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# //' -e 's/^#//'; exit 1; }   # the comment at the top of the script

reachable() {   # is anything answering on the SSH port of this address
    if ! command -v nc >/dev/null; then timeout 3 bash -c "exec 3<>/dev/tcp/$1/22" 2>/dev/null
    elif [ "$this_system" = macos ]; then nc -z -G 3 -w 3 "$1" 22 >/dev/null 2>&1
    else nc -z -w 3 "$1" 22 >/dev/null 2>&1
    fi
}

# What to do on a machine that does not answer; README.md has the long version.
not_reachable() {   # not_reachable SYSTEM
    echo "    no answer on the SSH port. The machine is off or asleep, on another network, or SSH is off or firewalled."
    case $1 in
    linux)   echo "    On it, run:  sudo apt install -y openssh-server   (and, with ufw on:  sudo ufw allow ssh)" ;;
    macos)   echo "    On it: System Settings > General > Sharing > Remote Login, on.  Or:  sudo systemsetup -setremotelogin on" ;;
    windows) echo "    On it, in PowerShell as administrator, run:"
             echo "      Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service sshd -StartupType Automatic" ;;
    esac
    echo "    More, and how to install without SSH: README.md, \"Getting a machine ready\"."
}

powershell_command() {   # the command line that runs the PowerShell script $1 on a Windows machine
    printf 'powershell -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand %s' \
        "$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
}

remember_user() {  # remember_user NAME USER: puts the user name that worked in the machine's line of machines.txt
    awk -v name="$1" -v user="$2" '$1 == name && $0 !~ /^[ \t]*#/ { printf "%-17s %-16s %-9s %s\n", $1, $2, $3, user; next } { print }' \
        "$machines_file" > "$machines_file.new" && mv "$machines_file.new" "$machines_file"
}

# ---- remembered passwords ----

remembered() {   # remembered NAME: prints its password, or fails
    if [ "$this_system" = macos ]; then
        security find-generic-password -s "$service" -a "$1" -w 2>/dev/null
    else
        "$here/wallet.py" get "$1" 2>/dev/null ||
            { command -v secret-tool >/dev/null && secret-tool lookup service "$service" machine "$1" 2>/dev/null | grep .; }
    fi
}

remember() {   # remember NAME PASSWORD
    if [ "$this_system" = macos ]; then
        # through security's own command reader, as hexadecimal: so it is on no command line, and needs no quoting
        printf 'add-generic-password -U -s %s -a %s -X %s\n' "$service" "$1" "$(printf '%s' "$2" | xxd -p | tr -d '\n')" |
            security -i >/dev/null 2>&1 && remembered "$1" >/dev/null
    else
        printf '%s\n' "$2" | "$here/wallet.py" set "$1" 2>/dev/null ||
            { command -v secret-tool >/dev/null &&
                printf '%s' "$2" | secret-tool store --label="Matrix screensaver: $1" service "$service" machine "$1" 2>/dev/null; }
    fi || echo "    (no password store to keep it in: it will be asked for again next time)" >&2
}

forget() {   # forget NAME
    if [ "$this_system" = macos ]; then
        security delete-generic-password -s "$service" -a "$1" >/dev/null 2>&1
    else
        "$here/wallet.py" forget "$1" 2>/dev/null
        ! command -v secret-tool >/dev/null || secret-tool clear service "$service" machine "$1" 2>/dev/null
    fi
    return 0
}

# ask_password NAME WHOSE: sets password from the keyboard
ask_password() { read -rsp "    $1: password of $2: " password < /dev/tty && echo > /dev/tty; }

# ---- connections ----

# SSH takes a password from a program, not from a variable: this one hands over $MATRIX_PASSWORD.
askpass=$control/askpass
printf '#!/bin/sh\nprintf "%%s\\n" "$MATRIX_PASSWORD"\n' > "$askpass"
chmod 700 "$askpass"

open_with_password() {  # open_with_password TARGET PASSWORD
    [ -n "$2" ] && MATRIX_PASSWORD=$2 SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force \
        ssh "${ssh_options[@]}" -o ControlMaster=yes -o ControlPersist=900 -o NumberOfPasswordPrompts=1 \
        -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -fN "$1" < /dev/null 2>/dev/null
}

# connect NAME ADDRESS USER: sets target (user@address) with a connection open to it, or fails.
# Also sets password to the machine's password, or to nothing when the login went by SSH key and none is remembered.
connect() {
    local name=$1 address=$2 user=$3 answer
    [ "$user" != - ] || user=$(id -un)
    target=$user@$address
    password=$(remembered "$name") || password=
    if ssh "${ssh_options[@]}" -o BatchMode=yes -o ControlMaster=yes -o ControlPersist=900 -fN "$target" 2>/dev/null ||
        open_with_password "$target" "$password"; then
        connected+=("$target")
        return 0
    fi
    [ -z "$password" ] || echo "    the remembered password no longer works"
    read -rp "    $name: user name [$user]: " answer < /dev/tty || return 1
    user=${answer:-$user}
    target=$user@$address
    ask_password "$name" "$user" || return 1
    open_with_password "$target" "$password" || return 1
    connected+=("$target")
    remember_user "$name" "$user"
    remember "$name" "$password"
}

# on TARGET ssh|scp ARGS...: runs ssh or scp through the connection that connect opened
on() {
    local tool=$2
    shift 2
    "$tool" "${ssh_options[@]}" "$@"
}

disconnect_all() {
    local t
    for t in ${connected[@]+"${connected[@]}"}; do ssh "${ssh_options[@]}" -O exit "$t" 2>/dev/null; done
    [ ! -d "${control:-}" ] || rm -rf -- "${control:?}"
}
trap disconnect_all EXIT
