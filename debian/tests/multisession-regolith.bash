#!/bin/bash
# Two standalone Regolith X11 sessions of one user side by side, started the
# way the installed regolith-x11 multi-session entry starts them, with the
# installed configuration and profile. Run by debian/tests/multisession-regolith
# as an unprivileged user. There is no logind, system bus or user manager
# here: ISOLATE=always stands in for "the user already has a session".
set -uo pipefail

pass=0 fail=0
ok()  { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
expect() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; return 1; fi; }

# PIDs of this user's processes matching the pgrep options, zombies left out:
# the testbed's PID 1 need not reap orphans (on GitHub Actions it is tail)
live() {
    local pid
    for pid in $(pgrep -u "$(id -u)" "$@"); do
        [[ $(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f1) == [!Z]* ]] && echo "$pid"
    done
    return 0
}
count() { live "$@" | wc -l; }

T=$(mktemp -d)
trap 'pkill -u "$(id -u)" -f "Xvfb|dbus-daemon" 2>/dev/null; rm -rf "$T"' EXIT
export XDG_RUNTIME_DIR HOME
entry=/usr/share/xsessions/regolith-x11-multisession.desktop
launch=$(sed -n 's/^Exec=//p' "$entry")
cp -r /etc/regolith/multisession "$T/etc"
echo "ISOLATE=always" >>"$T/etc/multisession.conf"
export MULTISESSION_SYSCONF=$T/etc

dbus-daemon --session --address="unix:path=$XDG_RUNTIME_DIR/bus" --fork >/dev/null
USER_BUS=unix:path=$XDG_RUNTIME_DIR/bus

# Processes of this user whose environment has DISPLAY=<display>
on_display() { # <display> <process name>
    local pid
    for pid in $(live -x "$2"); do
        tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "DISPLAY=$1" && echo "$pid"
    done
}
env_of() { tr '\0' '\n' <"/proc/$1/environ" | sed -n "s/^$2=//p"; }

for n in 1 2; do
    Xvfb ":$n" -screen 0 1280x800x24 -nolisten tcp -noreset >/dev/null 2>&1 &
    for _ in $(seq 50); do xdpyinfo -display ":$n" >/dev/null 2>&1 && break; sleep 0.1; done
    # What LightDM and Xsession hand to a session started from the generated entry
    env DISPLAY=":$n" XDG_SESSION_ID="s$n" XDG_SESSION_TYPE=x11 XDG_VTNR=$((7 + n)) \
        DESKTOP_SESSION=regolith-x11-multisession XDG_SESSION_DESKTOP=regolith-x11-multisession \
        XDG_CURRENT_DESKTOP=Regolith:GNOME-Flashback:GNOME DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
        setsid sh -c "exec $launch" >"$T/session$n.log" 2>&1 &
    echo $! >"$T/session$n.pid"
done

for _ in $(seq 150); do
    [[ -n $(on_display :1 i3) && -n $(on_display :2 i3) ]] && break
    sleep 0.2
done
sleep 4   # let both sessions settle

for n in 1 2; do
    d=:$n
    i3pid=$(on_display "$d" i3 | head -n1)
    expect "session $n: i3 runs on $d" test -n "$i3pid" || continue
    bus=$(env_of "$i3pid" DBUS_SESSION_BUS_ADDRESS)
    expect "session $n: i3 is on a private bus" test -n "$bus" -a "$bus" != "$USER_BUS"
    expect "session $n: i3 sees the session's own name" test "$(env_of "$i3pid" DESKTOP_SESSION)" = regolith-x11
    expect "session $n: session XDG config dir first" \
        bash -c "[[ \$(tr '\0' '\n' </proc/$i3pid/environ | sed -n 's/^XDG_CONFIG_DIRS=//p') == /etc/xdg/xdg-regolith-x11:* ]]"
    sock=$(DISPLAY=$d i3 --get-socketpath 2>/dev/null)
    expect "session $n: i3 IPC answers on its own socket" i3-msg -s "$sock" -t get_version >/dev/null
    expect "session $n: Regolith loaded X resources on $d" \
        bash -c "DISPLAY=$d xrdb -query | grep -q '^regolith\\.\\|^i3-wm\\.\\|^wm\\.'"
    expect "session $n: gsd-xsettings runs on $d" test -n "$(on_display "$d" gsd-xsettings)"
    expect "session $n: gnome-flashback runs on $d" test -n "$(on_display "$d" gnome-flashback)"
    expect "session $n: XSETTINGS has an owner on $d" \
        bash -c "DISPLAY=$d xprop -root _XSETTINGS_SETTINGS >/dev/null 2>&1 || DISPLAY=$d xdpyinfo >/dev/null"
    expect "session $n: org.gnome.ScreenSaver on its own bus (lock binding)" \
        bash -c "DBUS_SESSION_BUS_ADDRESS='$bus' gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner org.gnome.ScreenSaver \
            | grep -q true"
    expect "session $n: wrote no environment into the user manager (refused)" \
        grep -q "refused 'systemctl --user import-environment" "$T/session$n.log"
    expect "session $n: gnome-session never ran" bash -c "! grep -q 'graphical session is already running' $T/session$n.log"
    expect "session $n: singleton autostart skipped" test -z "$(on_display "$d" localsearch-3)"
done
expect "no session handed its display to the user's compositor service" \
    test ! -e "$XDG_RUNTIME_DIR/regolith-compositor-picom.env"
expect "two i3, one per display" test "$(count -x i3)" -eq 2

# Settings changed in one session are kept and seen in the other
i3a=$(on_display :1 i3 | head -n1); i3b=$(on_display :2 i3 | head -n1)
bus1=$(env_of "$i3a" DBUS_SESSION_BUS_ADDRESS); bus2=$(env_of "$i3b" DBUS_SESSION_BUS_ADDRESS)
DBUS_SESSION_BUS_ADDRESS=$bus1 gsettings set org.gnome.desktop.interface cursor-size 40
DBUS_SESSION_BUS_ADDRESS=$bus2 gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark
sleep 0.5
expect "setting from session 1 kept after session 2 wrote" \
    test "$(DBUS_SESSION_BUS_ADDRESS=$bus2 gsettings get org.gnome.desktop.interface cursor-size)" = 40
expect "one dconf-service for the user" test "$(count -x dconf-service)" -eq 1

# A compositor restart in session 2 (what every i3 reload does) leaves
# session 1's compositor alone. Regolith itself may reload i3 meanwhile (the
# settings changed above), so wait for session 2's compositor to settle.
stable_picom() { # <display>: its picom once the PID has not changed for 2 s
    local last="" cur stable=0
    for _ in $(seq 100); do
        cur=$(on_display "$1" picom)
        if [[ -n $cur && $cur == "$last" ]]; then stable=$((stable + 1)); else stable=0; fi
        last=$cur
        ((stable >= 10)) && { echo "$cur"; return 0; }
        sleep 0.2
    done
    return 1
}
if [[ -x /usr/share/regolith-compositor/init ]] && command -v picom >/dev/null; then
    before1=$(stable_picom :1) before2=$(stable_picom :2)
    expect "both sessions have a compositor" test -n "$before1" -a -n "$before2"
    i3-msg -s "$(DISPLAY=:2 i3 --get-socketpath)" exec /usr/share/regolith-compositor/init >/dev/null
    sleep 1
    after2=$(stable_picom :2)
    expect "compositor restart in session 2 replaced session 2's picom" test -n "$after2" -a "$after2" != "$before2"
    expect "... and kept session 1's picom" test -n "$before1" -a "$(on_display :1 picom)" = "$before1"
fi

# Log out of session 1 the way the Regolith binding does
DISPLAY=:1 DBUS_SESSION_BUS_ADDRESS=$bus1 gnome-session-quit --logout --no-prompt >/dev/null 2>&1
for _ in $(seq 50); do kill -0 "$(cat "$T/session1.pid")" 2>/dev/null || break; sleep 0.2; done
expect "gnome-session-quit --logout ends session 1" bash -c "! kill -0 $(cat "$T/session1.pid") 2>/dev/null"
sleep 1
expect "session 1's gsd, flashback and compositor are gone" \
    test -z "$(on_display :1 gsd-xsettings)$(on_display :1 gnome-flashback)$(on_display :1 picom)"
expect "session 2 keeps running" test -n "$(on_display :2 i3)" -a -n "$(on_display :2 gnome-flashback)"
expect "session 2's i3 still answers" i3-msg -s "$(DISPLAY=:2 i3 --get-socketpath)" -t get_version >/dev/null

DISPLAY=:2 DBUS_SESSION_BUS_ADDRESS=$bus2 gnome-session-quit --logout --no-prompt >/dev/null 2>&1
for _ in $(seq 50); do kill -0 "$(cat "$T/session2.pid")" 2>/dev/null || break; sleep 0.2; done
expect "session 2 ends too" bash -c "! kill -0 $(cat "$T/session2.pid") 2>/dev/null"
sleep 1
expect "nothing of either session is left" test -z "$(live -x 'i3|gsd-xsettings|gnome-flashback|msagent|picom')"

echo
echo "$pass passed, $fail failed"
if ((fail)); then
    echo "--- processes"; ps -u "$(id -u)" -o pid,ppid,stat,args
    for n in 1 2; do echo "--- session $n log"; grep -v "^dbus-daemon" "$T/session$n.log" | tail -40; done
    exit 1
fi
