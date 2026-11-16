#!/bin/bash
# Shows the screensaver now on this Linux machine; test.sh and test.ps1 run it on each one.
#   bash show-linux.sh        stays until someone touches the machine
#   bash show-linux.sh 15     for 15 seconds
s=$(command -v matrix-screensaver-session) || { echo "not installed: deploy to this machine first" >&2; exit 1; }
grep -q -- --test-here "$s" || { echo "the installed copy is out of date: deploy to this machine again" >&2; exit 1; }
exec "$s" --test "${1:-}"
