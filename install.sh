#!/usr/bin/env bash
# Matrix screensaver after 5 idle minutes (IDLE_MIN below), for every user of a Kubuntu machine: KDE Plasma 5 or 6,
# X11 or Wayland, on Ubuntu or Debian.
#
#   sudo bash install.sh            install or update; starts it in sessions that are already logged in
#   sudo bash install.sh --remove   undo, including the KDE settings it changed
#
# Plasma has no screensavers of its own, so a session script, started at login, runs one:
#   X11       xscreensaver showing matrix-rain, the 3D rain built from matrix-rain.c (./build.sh)
#   Wayland   xscreensaver cannot blank the screen there, so swayidle watches for idleness and starts
#             matrix-rain full-screen itself, closing it on the first key press or mouse movement
# matrix-rain is installed when it sits next to this script. Without it, or where it cannot start, the
# stand-ins are xscreensaver's glmatrix on X11 and cmatrix in a full-screen Konsole on Wayland.
# Per user, the session script also moves two KDE settings out of the way, because either would cover or
# blank the screen before the screensaver has had its turn:
#   - KDE's idle auto-lock is switched off, and the screensaver locks instead: on X11 xscreensaver asks for
#     the password, on Wayland KDE's lock screen comes up as the screensaver is dismissed
#     (only for users who had auto-lock on; the lock then comes with the screensaver)
#   - on mains power, screen-off and auto-suspend that would come within 10 minutes of the screensaver
#     starting are moved to 30 minutes after it
set -euo pipefail

IDLE_MIN=5
SESSION=/usr/local/bin/matrix-screensaver-session
RAIN=/usr/local/bin/matrix-rain
here=$(cd "$(dirname "$0")" && pwd)
AUTOSTART=/etc/xdg/autostart/matrix-screensaver.desktop

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 1; }
command -v apt-get >/dev/null || { echo "this installer is for Kubuntu: KDE Plasma on Ubuntu or Debian (no apt-get here)" >&2; exit 1; }

# Runs "$@" as the owner of each running Plasma session, inside that session's environment.
in_each_session() {
    local pid user vars
    for pid in $(pgrep -x plasmashell || true); do
        user=$(stat -c %U "/proc/$pid") || continue
        mapfile -d '' -t vars < <(grep -zE '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|XDG_SESSION_ID|XDG_RUNTIME_DIR|XDG_CONFIG_HOME|HOME)=' "/proc/$pid/environ")
        echo "  session of $user"
        runuser -u "$user" -- env "${vars[@]}" "$@" || true
    done
}

stop_running() {
    local pid
    # its children first: a sleep left behind would hold the session script's lock, and keep the new one from starting
    for pid in $(pgrep -f "$SESSION" || true); do pkill -P "$pid" || true; done
    pkill -f "$SESSION" || true
    pkill -x xscreensaver || true
    pkill -x matrix-rain || true
    # wait for them to be gone: a session script started while the old one still exists would back off
    for _ in $(seq 25); do
        pgrep -f "$SESSION" >/dev/null || pgrep -x xscreensaver >/dev/null || break
        sleep 0.2
    done
}

if [ "${1:-}" = --remove ]; then
    stop_running
    if [ -x "$SESSION" ]; then
        in_each_session "$SESSION" --restore
        # users who are not logged in right now
        for home in /home/*; do
            [ -d "$home/.config/matrix-screensaver" ] || continue
            user=$(stat -c %U "$home")
            echo "  settings of $user"
            runuser -u "$user" -- env HOME="$home" "$SESSION" --restore || true
        done
    fi
    rm -f "$SESSION" "$AUTOSTART" "$RAIN"
    echo "removed. The packages are still installed (apt remove xscreensaver swayidle cmatrix to drop them)."
    exit 0
fi

echo "installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq xscreensaver xscreensaver-gl xscreensaver-data-extra swayidle cmatrix konsole libgl1 libxrandr2

if [ -f "$here/matrix-rain" ] && [ "$(uname -m)" != x86_64 ]; then
    echo "  matrix-rain is built for x86_64 and this machine is $(uname -m): using the stand-in screensavers" >&2
    rm -f "$RAIN"
elif [ -f "$here/matrix-rain" ]; then
    install -m 755 "$here/matrix-rain" "$RAIN"
else
    echo "  no matrix-rain next to this script: using the stand-in screensavers" >&2
fi

cat > "$SESSION" <<SESSION_EOF
#!/usr/bin/env bash
# Installed by matrix-screensaver/install.sh; started at login by $AUTOSTART.
IDLE_MIN=$IDLE_MIN
rain=$RAIN
SESSION_EOF
cat >> "$SESSION" <<'SESSION_EOF'
self=$(readlink -f "$0")
uid=$(id -u)
state=${XDG_CONFIG_HOME:-$HOME/.config}/matrix-screensaver
rc=$HOME/.xscreensaver
log=$state/xscreensaver.log
running() { xscreensaver-command --time >/dev/null 2>&1; }  # is xscreensaver up on this display
marker="# managed by matrix-screensaver: delete this line to keep your own changes to this file"
kread=$(command -v kreadconfig6 || command -v kreadconfig5)
kwrite=$(command -v kwriteconfig6 || command -v kwriteconfig5)

kde_reload() {
    dbus-send --session --dest=org.freedesktop.ScreenSaver /ScreenSaver org.kde.screensaver.configure 2>/dev/null
    dbus-send --session --dest=org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement \
        org.kde.Solid.PowerManagement.reparseConfiguration 2>/dev/null
    dbus-send --session --dest=org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement \
        org.kde.Solid.PowerManagement.refreshStatus 2>/dev/null
}

# Moves an idle action of the mains (AC) power profile that would fire before the screensaver has had
# 10 minutes to 30 minutes after it starts, and notes the old value in $state for --restore.
# $1 config file, $2 group, $3 key, $4 how many of its units make a minute, $5 what it is when not set
push_back() {
    local now was
    now=$("$kread" --file "$1" --group AC --group "$2" --key "$3")
    was=$now
    if [ -z "$now" ]; then now=$5 was=unset; fi
    case $now in ''|*[!0-9]*|0) return ;; esac
    if [ "$now" -lt $(( (IDLE_MIN + 10) * $4 )) ]; then
        [ -e "$state/$2" ] || echo "$1 $2 $3 $was" > "$state/$2"
        "$kwrite" --file "$1" --group AC --group "$2" --key "$3" $(( (IDLE_MIN + 30) * $4 ))
    fi
}

# True while something is asking KDE to keep the screen on (a video, a call). A Plasma activity set to
# "never turn off the screen" also shows up there, permanently; that one is ignored, or the screensaver
# would never start on such a machine. KDE lists who is asking but not for what, so a browser download
# (which only asks for no sleep) is told apart by its wording.
agent() {
    dbus-send --session --print-reply --dest=org.kde.Solid.PowerManagement.PolicyAgent \
        /org/kde/Solid/PowerManagement/PolicyAgent "org.kde.Solid.PowerManagement.PolicyAgent.$1" "${@:2}" 2>/dev/null
}
held_off() {
    agent HasInhibition uint32:4 | grep -q 'boolean true' &&
        agent ListInhibitions | grep 'string "' | paste - - | grep -v '"Activity Manager"' | grep -qiv 'download'
}

case ${1:-} in
--restore)
    [ -n "$kwrite" ] || exit 0
    [ -e "$state/autolock" ] && "$kwrite" --file kscreenlockerrc --group Daemon --key Autolock true
    for saved in "$state"/*; do
        read -r file group key was < "$saved" 2>/dev/null || continue
        [ -n "$was" ] || continue
        if [ "$was" = unset ]; then
            "$kwrite" --file "$file" --group AC --group "$group" --key "$key" --delete
        else
            "$kwrite" --file "$file" --group AC --group "$group" --key "$key" "$was"
        fi
    done
    grep -qxF "$marker" "$rc" 2>/dev/null && rm -f "$rc"
    rm -rf "$state"
    kde_reload
    exit 0 ;;
--test)  # show it now in every desktop session this user has on this machine; for $2 seconds if given, else until dismissed
    pids=()
    for pid in $(pgrep -u "$uid" -x plasmashell); do
        mapfile -d '' -t vars < <(grep -zE '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|XDG_SESSION_ID|XDG_RUNTIME_DIR)=' "/proc/$pid/environ")
        env "${vars[@]}" "$self" --test-here "${2:-}" &
        pids+=($!)
    done
    [ ${#pids[@]} -gt 0 ] || { echo "nobody is logged in to a desktop" >&2; exit 1; }
    status=0
    for pid in "${pids[@]}"; do wait "$pid" || status=1; done
    exit $status ;;
--test-here)
    where="${WAYLAND_DISPLAY:-$DISPLAY} (${XDG_SESSION_TYPE:-?})"
    if [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
        pgrep -u "$uid" -f "$self --(rain|term)" >/dev/null || setsid -f "$self" --rain >/dev/null 2>&1
        sleep "${2:-3}"
        pgrep -u "$uid" -f "$self --term|^$rain --fullscreen" >/dev/null || { echo "nothing came up on $where" >&2; exit 1; }
        if [ -n "${2:-}" ]; then
            pkill -u "$uid" -f "$self --(rain|term)"
            pkill -u "$uid" -f "^$rain --fullscreen"
        else  # closed like the real thing, on the first key press or mouse movement, by a watcher of its own
            pgrep -u "$uid" -f "resume $self --hide-test" >/dev/null ||
                setsid -f swayidle -w timeout 2 true resume "$self --hide-test" >/dev/null 2>&1
        fi
        pgrep -u "$uid" -f "swayidle.* $self --show" >/dev/null || { echo "shown on $where, but the idle watcher is not running, so it will not start by itself" >&2; exit 1; }
    else
        if ! running; then  # not up: start it as a login would, and say why if that does not work either
            setsid -f "$self" >/dev/null 2>&1
            sleep 8
        fi
        # idle long enough to be showing it already (a remote desktop nobody is looking at, say): nothing to do
        if xscreensaver-command --time 2>/dev/null | grep -q 'screen blanked'; then echo "already showing on $where"; exit 0; fi
        xscreensaver-command --activate >/dev/null 2>&1 || {
            echo "xscreensaver will not start on $where: $(grep -v '^$' "$log" 2>/dev/null | tail -n 4 | tr '\n' ' ')" >&2
            exit 1
        }
        if [ -n "${2:-}" ]; then
            sleep "$2"
            xscreensaver-command --deactivate >/dev/null 2>&1
        fi
    fi
    if [ -n "${2:-}" ]; then echo "shown on $where"; else echo "started on $where"; fi
    exit 0 ;;
--hide-test)  # Wayland: the end of a --test that was left running
    "$self" --hide
    pkill -u "$uid" -f "resume $self --hide-test"
    exit 0 ;;
--show)  # Wayland, from swayidle: idle for IDLE_MIN minutes
    held_off && exit 0
    pgrep -u "$uid" -f "$self --(rain|term)" >/dev/null && exit 0
    setsid -f "$self" --rain 9>&- >/dev/null 2>&1
    exit 0 ;;
--rain)  # the 3D rain, through XWayland; where that cannot start, cmatrix in a full-screen Konsole
    [ -x "$rain" ] && "$rain" --fullscreen && exit 0
    exec konsole --separate --fullscreen --hide-menubar --hide-tabbar --notransparency \
        -p ColorScheme=GreenOnBlack -p ScrollBarPosition=2 -e "$self" --term ;;
--term)  # inside that Konsole; restarted if a key press quits it, since only --hide may close the window
    trap '' INT
    while :; do cmatrix -b; sleep 0.2; done ;;
--hide)  # Wayland, from swayidle: first key press or mouse movement
    pgrep -u "$uid" -f "$self --(rain|term)" >/dev/null || exit 0
    if [ -e "$state/autolock" ]; then loginctl lock-session; sleep 1; fi
    pkill -u "$uid" -f "$self --(rain|term)"
    pkill -u "$uid" -f "^$rain --fullscreen"
    exit 0 ;;
esac

case ${XDG_SESSION_TYPE:-} in
x11) command -v xscreensaver >/dev/null || exit 0 ;;
wayland) command -v swayidle >/dev/null && command -v cmatrix >/dev/null && command -v konsole >/dev/null || exit 0 ;;
*) exit 0 ;;
esac
mkdir -p "$state"
# one per display: a machine can have several sessions of one user (the screen, a remote desktop)
display=${WAYLAND_DISPLAY:-$DISPLAY}
exec 9> "$state/running-${display//[^A-Za-z0-9]/_}"
flock -w 5 9 || exit 0

if [ -n "$kwrite" ]; then
    if [ "$("$kread" --file kscreenlockerrc --group Daemon --key Autolock --default true)" = true ]; then
        "$kwrite" --file kscreenlockerrc --group Daemon --key Autolock false
        touch "$state/autolock"
    fi
    if [ "${kwrite##*/}" = kwriteconfig6 ]; then  # Plasma 6: seconds, and 10 and 15 minutes when never changed
        push_back powerdevilrc Display TurnOffDisplayIdleTimeoutSec 60 600
        push_back powerdevilrc SuspendAndShutdown AutoSuspendIdleTimeoutSec 60 900
    else                                          # Plasma 5: seconds for screen-off, milliseconds for suspend
        push_back powermanagementprofilesrc DPMSControl idleTime 60 ''
        push_back powermanagementprofilesrc SuspendSession idleTime 60000 ''
    fi
    kde_reload
fi

if [ "$XDG_SESSION_TYPE" = wayland ]; then
    exec swayidle -w timeout $(( IDLE_MIN * 60 )) "$self --show" resume "$self --hide"
fi

lock=False
[ -e "$state/autolock" ] && lock=True
first=
[ -x "$rain" ] && first="GL: 				$rain --root				    \\n\\
		"
if [ ! -e "$rc" ] || grep -qxF "$marker" "$rc"; then
    cat > "$rc" <<EOF
$marker
timeout:	0:$(printf %02d "$IDLE_MIN"):00
cycle:		0
lock:		$lock
lockTimeout:	0:00:00
passwdTimeout:	0:00:30
dpmsEnabled:	False
splash:		False
fade:		True
unfade:		False
fadeSeconds:	0:00:03
mode:		one
selected:	0
programs:								      \\
		${first}GL: 				glmatrix --root				    \\n\\
				xmatrix --root				    \\n\\

EOF
fi


# KDE owns the D-Bus name that browsers and video players use to hold the screensaver off, so xscreensaver
# never hears them. Pass it on.
# xscreensaver is restarted if it dies, a few times at most: at logout it cannot start any more, and this ends.
: > "$log"
starts=0
while :; do
    if ! running; then
        [ $starts -lt 5 ] || exit 1
        starts=$((starts + 1))
        xscreensaver --no-splash 9>&- >> "$log" 2>&1 &
        sleep 5 9>&-
        continue
    fi
    held_off && xscreensaver-command --deactivate >/dev/null 2>&1
    sleep 60 9>&-   # without the lock, which is this script's alone
done
SESSION_EOF
chmod 755 "$SESSION"

cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Matrix screensaver
Exec=$SESSION
OnlyShowIn=KDE;
NoDisplay=true
EOF

echo "starting it in logged-in sessions..."
stop_running
in_each_session setsid -f "$SESSION" > /dev/null 2>&1
if ! pgrep -x plasmashell >/dev/null; then
    echo "  nobody is logged in; it starts at the next login"
else
    sleep 8   # on X11 the session script takes a few seconds to get xscreensaver up
    pgrep -x 'xscreensaver|swayidle' >/dev/null || echo "  it did not start; it should at the next login" >&2
fi
echo "done: matrix screensaver after $IDLE_MIN idle minutes on $(hostname)."
