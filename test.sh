#!/usr/bin/env bash
# Starts the screensaver on this machine and every machine in machines.txt at the same moment. Run it on
# Linux or macOS (on Windows: test.cmd).
#
#   ./test.sh                 start it and leave it: it stays until someone touches that machine
#   ./test.sh 15              show it for 15 seconds, then close it again
#   ./test.sh Main-PC nuc     only on these machines (also after a number of seconds); this machine goes by
#                             its own name, as hostname -s prints it
#
# First logs in to each machine in turn, asking for its user name and password where they are not remembered
# yet (see common.sh), then starts them all together. Each machine needs the screensaver installed
# (./deploy.sh) and someone logged in to the desktop.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
seconds=
case ${1:-} in [0-9]*) seconds=$1; shift ;; -*) usage ;; esac
case $seconds in *[!0-9]*) usage ;; esac
logs=$control/logs   # removed with the rest of $control when the script ends (common.sh)
mkdir "$logs" || exit 1

# What runs on each machine is in show-linux.sh, show-macos.sh and show-windows.ps1.
windows=$(powershell_command "\$seconds = \"$seconds\"
$(grep -v '^#' "$here/show-windows.ps1")")

names=() targets=() systems=()
if [ $# -eq 0 ] || [[ " $* " == *" $this "* ]]; then names+=("this machine") targets+=("") systems+=("$this_system"); fi
while read -r name address system user <&3; do
    if [ $# -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
    if ! reachable "$address"; then
        printf '%-18s %-7s %s\n' "$name" skipped "no answer on the SSH port (see README.md)"
    elif connect "$name" "$address" "$user"; then
        names+=("$name") targets+=("$target") systems+=("$system")
    else
        printf '%-18s %-7s %s\n' "$name" skipped "could not log in"
    fi
done 3< <(machines)
[ ${#names[@]} -gt 0 ] || { echo "no machine to start it on"; exit 1; }

pids=()
for i in "${!names[@]}"; do
    t=${targets[$i]}
    if [ -z "$t" ]; then
        bash "$here/show-$this_system.sh" $seconds > "$logs/$i" 2>&1 < /dev/null &
    elif [ "${systems[$i]}" = windows ]; then
        on "$t" ssh -o BatchMode=yes "$t" "$windows" > "$logs/$i" 2>&1 < /dev/null &
    else
        on "$t" ssh -o BatchMode=yes "$t" "bash -s -- $seconds" < "$here/show-${systems[$i]}.sh" > "$logs/$i" 2>&1 &
    fi
    pids+=($!)
done

if [ -n "$seconds" ]; then
    echo "showing the screensaver for $seconds seconds on ${#names[@]} machines..."
else
    echo "starting the screensaver on ${#names[@]} machines; it stays until someone touches the machine..."
fi
failed=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then result=ok; else result=FAILED; failed=1; fi
    printf '%-18s %-7s %s\n' "${names[$i]}" "$result" "$(grep -av -e '^#< CLIXML' -e '^<Objs ' "$logs/$i" | tr '\r\n' '  ' | cut -c1-400)"
done
exit $failed
