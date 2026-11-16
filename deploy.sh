#!/usr/bin/env bash
# Installs the Matrix screensaver on this machine and on the others, over SSH. Run it on Linux or macOS
# (on Windows: deploy.cmd).
#
#   ./deploy.sh                  this machine and every machine in machines.txt
#   ./deploy.sh nuc Main-PC      only these (this machine goes by its own name, as hostname -s prints it)
#   ./deploy.sh --remove [...]   undo
#   ./deploy.sh --forget         drop the remembered passwords
#
# The first time, asks for the user name and password of each machine as it gets to it, and remembers them
# (see common.sh): later runs ask nothing. On Linux the same password is given to sudo. A machine that does
# not answer is skipped, with what to do on it. README.md has the whole story.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"

remove= forget=
case ${1:-} in
--remove) remove=1; shift ;;
--forget) forget=1; shift ;;
-*) usage ;;
esac

if [ -n "$forget" ]; then
    for name in "$this" $(machines | awk '{ print $1 }'); do forget "$name"; done
    echo "forgot the remembered passwords"
    exit 0
fi

# sudo_password NAME USER COMMAND...: makes sure password is one that sudo takes on that machine. COMMAND is
# "sudo -k -S -p '' true" as run there. Starts from the password connect found; asks when there is none or sudo
# refuses it, and remembers what worked.
sudo_password() {
    local name=$1 user=$2 try
    shift 2
    [ -z "$password" ] || ! printf '%s\n' "$password" | "$@" 2>/dev/null || return 0
    [ -z "$password" ] || echo "    sudo does not take the remembered password"
    for try in 1 2 3; do
        ask_password "$name" "$user, for sudo" || return 1
        if printf '%s\n' "$password" | "$@" 2>/dev/null; then remember "$name" "$password"; return 0; fi
        echo "    sudo did not take it"
    done
    return 1
}

wanted() {   # wanted NAME ARGS...: was this machine asked for (every machine is, when no names were given)
    local name=$1
    shift
    [ $# -eq 0 ] || [[ " $* " == *" $name "* ]]
}

finished=() skipped=() failed=()

if wanted "$this" "$@"; then
    echo "=== $this (this machine, $this_system)"
    if [ "$this_system" = macos ]; then
        bash "$here/install-macos.sh" ${remove:+--remove}
    else
        password=$(remembered "$this") || password=
        sudo_password "$this" "$(id -un)" sudo -k -S -p '' true &&
            printf '%s\n' "$password" | sudo -S -p '' bash "$here/install.sh" ${remove:+--remove}
    fi && finished+=("$this") || failed+=("$this")
fi

[ -f "$machines_file" ] || echo "(no machines.txt, so no other machines: copy machines.example.txt to machines.txt and fill it in)"
while read -r name address system user <&3; do
    wanted "$name" "$@" || continue
    echo "=== $name ($address, $system)"
    case $system in
    linux|windows|macos) ;;
    *) echo "    machines.txt: the system must be linux, windows or macos"; failed+=("$name"); continue ;;
    esac
    if ! reachable "$address"; then
        not_reachable "$system"
        skipped+=("$name")
        continue
    fi
    if ! connect "$name" "$address" "$user"; then
        echo "    could not log in"
        failed+=("$name")
        continue
    fi
    # the files go to a folder of their own on the machine, which the last command there removes again
    case $system in
    linux)
        on "$target" ssh "$target" 'mkdir -p /tmp/matrix-screensaver' &&
            on "$target" scp -q "$here/install.sh" "$here/matrix-rain" "$target:/tmp/matrix-screensaver/" &&
            sudo_password "$name" "${target%@*}" on "$target" ssh "$target" "sudo -k -S -p '' true" &&
            printf '%s\n' "$password" | on "$target" ssh "$target" \
                "sudo -S -p '' bash /tmp/matrix-screensaver/install.sh ${remove:+--remove}; s=\$?; rm -rf /tmp/matrix-screensaver; exit \$s" ;;
    macos)
        on "$target" ssh "$target" 'mkdir -p /tmp/matrix-screensaver' &&
            on "$target" scp -q "$here/install-macos.sh" "$here/matrix-rain.c" "$here/glyphs.h" "$target:/tmp/matrix-screensaver/" &&
            on "$target" ssh "$target" \
                "bash /tmp/matrix-screensaver/install-macos.sh ${remove:+--remove}; s=\$?; rm -rf /tmp/matrix-screensaver; exit \$s" < /dev/null ;;
    windows)
        on "$target" scp -q "$here/install.ps1" "$target:matrix-install.ps1" &&
            { [ -n "$remove" ] || on "$target" scp -q "$here/Matrix.scr" "$target:matrix-rain.scr"; } &&
            on "$target" ssh "$target" "powershell -NoProfile -ExecutionPolicy Bypass -File matrix-install.ps1 ${remove:+-Remove}" < /dev/null ;;
    esac && finished+=("$name") || failed+=("$name")
done 3< <(machines)

echo
echo "${remove:+removed}${remove:-installed}: ${finished[*]:-none}"
[ ${#skipped[@]} -eq 0 ] || echo "skipped, no answer: ${skipped[*]}"
[ ${#failed[@]} -eq 0 ] || { echo "failed: ${failed[*]}" >&2; exit 1; }
