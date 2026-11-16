#!/usr/bin/env bash
# Looks on the network this machine is on for machines with SSH switched on, and prints each as a line for
# machines.txt. Run it on Linux or macOS.
#
#   ./find.sh                   look, and print the lines
#   ./find.sh >> machines.txt   add them to the list; then check the system and user columns by hand
#
# Looks at the 254 addresses around each address this machine has (x.y.z.1 to x.y.z.254), which is the whole
# network at home and in most small offices. A machine it does not find is off or asleep, on another network,
# or has SSH off or firewalled: see "Getting a machine ready" in README.md.
# The system is read from how the machine's SSH greets: Windows says so, Ubuntu and Debian say so, a Mac and
# other Linux systems do not, and get "macos" with a note to check. Routers and the like are left out, and so
# are machines already in machines.txt.
set -u
here=$(cd "$(dirname "$0")" && pwd)
case ${1:-} in -*) sed -n '2,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# //' -e 's/^#//'; exit 1 ;; esac
mac=
[ "$(uname -s)" != Darwin ] || mac=1
command -v nc >/dev/null || { echo "needs nc (sudo apt install netcat-openbsd)" >&2; exit 1; }

if [ -n "$mac" ]; then mine=$(ifconfig | awk '$1 == "inet" && $2 !~ /^127\./ { print $2 }')
else mine=$(ip -4 -o addr show scope global | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap|wg)/ { sub(/\/.*/, "", $4); print $4 }')   # not the networks of containers, virtual machines and VPNs
fi
[ -n "$mine" ] || { echo "this machine has no network address" >&2; exit 1; }

greeting() {   # the first line a machine's SSH sends, which names its software
    if [ -n "$mac" ]; then nc -G 2 -w 2 "$1" 22 < /dev/null 2>/dev/null | head -n 1
    else nc -w 2 "$1" 22 < /dev/null 2>/dev/null | head -n 1
    fi
}

name_of() {   # the name the network knows an address by, without its domain; nothing when it knows none
    if [ -n "$mac" ]; then dig +short +time=1 +tries=1 -x "$1" 2>/dev/null | head -n 1
    else getent hosts "$1" | awk '{ print $2 }'
    fi | sed 's/\..*//'
}

found=$(mktemp -d) || exit 1
for address in $mine; do
    net=${address%.*}
    echo "looking at $net.1 to $net.254..." >&2
    for n in $(seq 1 254); do
        other=$net.$n
        case " $(echo $mine) " in *" $other "*) continue ;; esac
        ( hello=$(greeting "$other" | tr -d '\r'); case $hello in SSH-*) echo "$hello" > "$found/$other" ;; esac ) &
    done
    wait
done

count=0
for file in $(ls "$found" | sort -t . -k 4 -n); do
    address=$file
    if [ -f "$here/machines.txt" ] && grep -vE '^[[:space:]]*#' "$here/machines.txt" | awk '{ print $2 }' | grep -qxF "$address"; then continue; fi
    hello=$(cat "$found/$file")
    note=
    case $hello in
    *dropbear*) continue ;;   # a router, an access point, a NAS: not a desktop
    *Windows*) system=windows ;;
    *Ubuntu*|*Debian*|*Raspbian*) system=linux ;;
    *) system=macos note="# check the next one: a Mac, or a Linux that does not say so (then: linux), or no desktop at all (then: delete)" ;;
    esac
    name=$(name_of "$address")
    [ -n "$name" ] || name=machine-${address##*.}
    [ -z "$note" ] || echo "$note"
    printf '%-17s %-16s %-9s %s\n' "$name" "$address" "$system" -
    count=$((count + 1))
done
rm -rf -- "${found:?}"
echo "$count new machines with SSH on. The last column is the user name: - means the same as on this machine." >&2
