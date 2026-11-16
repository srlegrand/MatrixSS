#!/bin/bash
# Matrix screensaver after 5 idle minutes (IDLE_MIN below) on macOS, for the user who runs this. No admin needed.
#
#   bash install-macos.sh            install or update; starts straight away when that user is logged in
#   bash install-macos.sh --remove   undo
#
# Needs matrix-rain.c and glyphs.h next to this script (deploy.sh and deploy.ps1 put them there), and Apple's
# command line tools to compile them, once per Mac:  xcode-select --install
#
# macOS only takes screen savers built as signed bundles with Xcode, and has moved where the chosen one is
# kept with almost every release. So this does not go through System Settings at all: a small watcher, started
# at login (a LaunchAgent), starts the rain full-screen after IDLE_MIN idle minutes and closes it on the first
# key press or mouse movement. It holds off while a video or a call keeps the screen awake, and it keeps the
# screen on for 30 minutes of rain, after which macOS turns the screen off as it always did. The screen saver
# and lock settings of macOS itself are left alone; set its own screen saver to start later than IDLE_MIN, or
# never, so the two do not take turns.
set -eu

IDLE_MIN=5
dir="$HOME/Library/Application Support/MatrixScreensaver"
label=local.matrix-screensaver
agent="$HOME/Library/LaunchAgents/$label.plist"
here=$(cd "$(dirname "$0")" && pwd)
uid=$(id -u)

[ "$(uname -s)" = Darwin ] || { echo "this installer is for macOS (install.sh is the one for Linux)" >&2; exit 1; }
[ "$uid" != 0 ] || { echo "run this as the user who wants the screensaver, without sudo" >&2; exit 1; }

stop() {
    launchctl bootout "gui/$uid/$label" 2>/dev/null || launchctl unload "$agent" 2>/dev/null || true
    pkill -U "$uid" -x matrix-rain 2>/dev/null || true
}

if [ "${1:-}" = --remove ]; then
    stop
    rm -f "$agent"
    rm -rf "$dir"
    echo "removed."
    exit 0
fi

# /usr/bin/clang exists on every Mac, but without the command line tools it only opens a window offering to
# install them. xcode-select -p says whether they are there without opening anything.
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple's command line tools are missing on $(hostname -s), and the rain is compiled with them." >&2
    echo "On that Mac, run:  xcode-select --install   (confirm in the window that opens; it takes a few minutes)" >&2
    echo "then install again." >&2
    exit 1
fi
[ -f "$here/matrix-rain.c" ] && [ -f "$here/glyphs.h" ] || { echo "matrix-rain.c and glyphs.h must be next to this script" >&2; exit 1; }

mkdir -p "$dir" "$HOME/Library/LaunchAgents"
echo "compiling the rain..."
clang -x objective-c -fobjc-arc -O2 -o "$dir/matrix-rain.new" "$here/matrix-rain.c" -framework Cocoa -framework OpenGL
stop
mv -f "$dir/matrix-rain.new" "$dir/matrix-rain"

cat > "$dir/watch.sh" <<WATCH_EOF
#!/bin/bash
# Installed by install-macos.sh; started at login by $agent.
IDLE_MIN=$IDLE_MIN
WATCH_EOF
cat >> "$dir/watch.sh" <<'WATCH_EOF'
dir=$(cd "$(dirname "$0")" && pwd)
rain=$dir/matrix-rain
now=$dir/show-now        # test.sh and test.ps1 write this to show it at once: empty, or a number of seconds
uid=$(id -u)
keep=
shown=0
armed=1

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'; }   # seconds without input
# true while something asks macOS to keep the screen awake: a video, a call, a presentation
held_off() { pmset -g assertions 2>/dev/null | grep -qE '^ *PreventUserIdleDisplaySleep +[1-9]'; }
showing() { pgrep -U "$uid" -x matrix-rain >/dev/null; }

show() {   # show [SECONDS]
    if [ -n "${1:-}" ]; then "$rain" --fullscreen --seconds "$1" >/dev/null 2>&1 &
    else "$rain" --fullscreen >/dev/null 2>&1 &
    fi
    caffeinate -d -t 1800 &
    keep=$!
    shown=$SECONDS
}

hide() {
    pkill -U "$uid" -x matrix-rain
    [ -z "$keep" ] || kill "$keep" 2>/dev/null
    keep=
}

rm -f "$now"
while :; do
    idle_for=$(idle)
    case $idle_for in ''|*[!0-9]*) sleep 5; continue ;; esac
    if showing; then
        # input since it came up: the idle time is shorter than the time it has been showing
        if [ "$idle_for" -lt $((SECONDS - shown - 1)) ]; then hide; fi
        sleep 0.5
        continue
    fi
    if [ -n "$keep" ]; then   # it ended by itself (--seconds, or it could not start)
        kill "$keep" 2>/dev/null
        keep=
        armed=   # not again until someone has used the machine, or a rain that cannot start would be retried forever
    fi
    if [ "$idle_for" -lt $((IDLE_MIN * 60)) ]; then armed=1; fi
    if [ -e "$now" ]; then
        seconds=$(tr -cd 0-9 < "$now")
        rm -f "$now"
        show "$seconds"
    elif [ -n "$armed" ] && [ "$idle_for" -ge $((IDLE_MIN * 60)) ] && ! held_off; then
        show
    fi
    sleep 2
done
WATCH_EOF
chmod 755 "$dir/watch.sh"

cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$dir/watch.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

if launchctl bootstrap "gui/$uid" "$agent" 2>/dev/null || launchctl load -w "$agent" 2>/dev/null; then
    echo "done: matrix screensaver after $IDLE_MIN idle minutes on $(hostname -s), for $(id -un)."
else
    echo "done: installed on $(hostname -s) for $(id -un). Nobody is logged in at the screen, so it starts at the next login."
fi
