#!/bin/bash
# Shows the screensaver now on this Mac; test.sh and test.ps1 run it on each one.
#   bash show-macos.sh        stays until someone touches the machine
#   bash show-macos.sh 15     for 15 seconds
# An SSH login may not open windows on the screen, so this asks the watcher, which runs in the desktop
# session of the logged-in user (see install-macos.sh), to do it.
dir="$HOME/Library/Application Support/MatrixScreensaver"
[ -x "$dir/matrix-rain" ] || { echo "not installed for $(id -un): deploy to this machine first" >&2; exit 1; }
pgrep -U "$(id -u)" -f "$dir/watch.sh" >/dev/null || { echo "installed, but $(id -un) is not logged in at the screen" >&2; exit 1; }
if pgrep -U "$(id -u)" -x matrix-rain >/dev/null; then
    [ -n "${1:-}" ] || { echo "already showing"; exit 0; }
    pkill -U "$(id -u)" -x matrix-rain
    sleep 3
fi
echo "${1:-}" > "$dir/show-now"
sleep 5
pgrep -U "$(id -u)" -x matrix-rain >/dev/null || { echo "it did not come up" >&2; exit 1; }
[ -n "${1:-}" ] || { echo "started"; exit 0; }
sleep "$1"
echo "shown"
