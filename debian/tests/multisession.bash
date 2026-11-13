#!/bin/bash
# regolith-multisession, as installed. Run by debian/tests/multisession as an
# unprivileged user with XDG_RUNTIME_DIR set. There is no logind, LightDM or
# systemd here: a fake loginctl drives the decision table, and the sessions
# force ISOLATE=always and start the way the display manager's Xsession would
# start them, on Xvfb displays.
set -uo pipefail

pass=0 fail=0
ok()   { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
expect() { # <description> <command...>
    local what=$1; shift
    if "$@"; then ok "$what"; else bad "$what"; return 1; fi
}

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
trap 'kill $(jobs -p) 2>/dev/null; pkill -u "$(id -u)" -f "dbus-daemon|Xvfb|dconf-service|i3" 2>/dev/null; rm -rf "$T"' EXIT
export HOME=${HOME:?} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:?}
export MULTISESSION_SYSCONF=$T/etc
export XDG_DATA_DIRS=$T/share:/usr/local/share:/usr/share XDG_CONFIG_DIRS=$T/xdg:/etc/xdg
MS=/usr/bin/regolith-multisession
LIB=/usr/lib/regolith/multisession
HOOK=/etc/X11/Xsession.d/94regolith-multisession

expect "msagent check" "$LIB/msagent" check

# ---- fixtures -----------------------------------------------------------------
mkdir -p "$T/etc/profiles" "$T/xsessions" "$T/share/applications" "$T/share/gnome-session/sessions" \
    "$T/xdg/autostart" "$T/xdg-test/autostart" "$HOME/.config/autostart" "$T/bin"

cat >"$T/xsessions/testde.desktop" <<EOF
[Desktop Entry]
Name=Test DE
Name[de]=Test-DE
Comment=fixture
Exec=/bin/false %U
TryExec=/bin/true
Type=Application
DesktopNames=TestDE;GNOME-Flashback
EOF
cat >"$T/etc/multisession.conf" <<EOF
ISOLATE=always
XSESSION_DIRS=($T/xsessions)
LATE_AUTOSTART_DELAY=0
EOF

echo "# entries"
shipped=/usr/share/xsessions/regolith-x11-multisession.desktop
stock=/usr/share/xsessions/regolith-x11.desktop
key() { sed -n "s/^$2=//p" "$1"; }
# DesktopNames is a display-manager key that desktop-file-validate does not
# know (as in the units test): that one diagnostic is tolerated
valid_entry() { ! desktop-file-validate "$1" 2>&1 | grep -v '"DesktopNames"' | grep -q .; }
expect "the regolith-x11 entry is installed" test -r "$shipped"
expect "it is a valid desktop entry" valid_entry "$shipped"
expect "it runs the launcher for regolith-x11" test "$(key "$shipped" Exec)" = "$MS launch regolith-x11"
for k in DesktopNames TryExec Type; do
    expect "it has the stock entry's $k" test "$(key "$shipped" $k)" = "$(key "$stock" $k)"
done
expect "the stock entry is still there, unchanged" test "$(key "$stock" Exec)" = /usr/bin/regolith-session-x11-launch
"$MS" entry testde >"$T/testde-multisession.desktop" 2>/dev/null
gen=$T/testde-multisession.desktop
expect "entry: runs the launcher" grep -qx "Exec=$MS launch testde" "$gen"
expect "entry: names carry the suffix" grep -qx "Name=Test DE (multi-session)" "$gen"
expect "entry: localized names too" grep -qx "Name\[de\]=Test-DE (multi-session)" "$gen"
expect "entry: keeps DesktopNames" grep -qx "DesktopNames=TestDE;GNOME-Flashback" "$gen"
expect "entry: keeps TryExec" grep -qx "TryExec=/bin/true" "$gen"
expect "entry: valid desktop entry" valid_entry "$gen"
expect "entry: a missing session is an error" bash -c "! '$MS' entry missing-session 2>/dev/null"
expect "entry: not of a multi-session entry" bash -c "! '$MS' entry testde-multisession 2>/dev/null"

echo "# isolation decision"
D=$T/decide; mkdir -p "$D/etc" "$D/bin" "$D/logind"
echo "ISOLATE=auto" >"$D/etc/multisession.conf"
cat >"$D/bin/loginctl" <<'EOF'
#!/bin/bash
case $1 in
    list-sessions) cat "$FAKE_LOGIND/list" ;;
    show-session) cat "$FAKE_LOGIND/$2" ;;
esac
EOF
cat >"$D/bin/systemctl" <<'EOF'
#!/bin/bash
[[ "$*" == *graphical-session.target* && ${FAKE_GST:-inactive} == active ]]
EOF
chmod +x "$D/bin/loginctl" "$D/bin/systemctl"
me=$(id -un)
fake_session() { # <id> <user> <type> <state>
    echo "$1 1000 $2 seat0" >>"$D/logind/list"
    printf 'Name=%s\nClass=user\nType=%s\nState=%s\n' "$2" "$3" "$4" >"$D/logind/$1"
}
decide() { # <expected: standalone|primary> <description> [env...]
    local want=$1 what=$2 got; shift 2
    if env PATH="$D/bin:$PATH" FAKE_LOGIND="$D/logind" MULTISESSION_SYSCONF="$D/etc" XDG_SESSION_ID=self "$@" \
        "$MS" should-isolate; then got=standalone; else got=primary; fi
    expect "$what -> $want" test "$got" = "$want"
}
reset_logind() { rm -rf "$D/logind" "$XDG_RUNTIME_DIR/multisession"; mkdir -p "$D/logind"; : >"$D/logind/list"; }
reset_logind; fake_session self "$me" x11 active
decide primary "first login"
fake_session c2 "$me" x11 online
decide standalone "user has another X11 session"
reset_logind; fake_session self "$me" x11 active; fake_session c3 "$me" wayland active
decide standalone "user has a Wayland session"
reset_logind; fake_session self "$me" x11 active; fake_session c4 "$me" tty active
decide primary "user only has a text console login"
reset_logind; fake_session self "$me" x11 active; fake_session c5 someone-else x11 active
decide primary "only another user has a session"
reset_logind; fake_session self "$me" x11 active; fake_session c6 "$me" x11 closing
decide primary "user's other session is closing"
reset_logind; fake_session self "$me" x11 active; fake_session c7 "$me" x11 active
mkdir -p "$XDG_RUNTIME_DIR/multisession/c7"; echo mode=standalone >"$XDG_RUNTIME_DIR/multisession/c7/state"
decide primary "only standalone sessions left: the user manager is free"
decide standalone "... unless the user manager still runs a graphical session" FAKE_GST=active
reset_logind; fake_session self "$me" x11 active
decide standalone "graphical-session.target active without a session" FAKE_GST=active
decide standalone "decision handed down by the Xsession hook" MULTISESSION_ISOLATE=1
decide primary "Xsession hook decided primary" MULTISESSION_ISOLATE=0 FAKE_GST=active
hook() { # [env...] → what the Xsession hook leaves for the later Xsession.d scripts
    # shellcheck disable=SC2016  # expanded by the inner sh
    env PATH="$D/bin:$PATH" FAKE_LOGIND="$D/logind" MULTISESSION_SYSCONF="$D/etc" XDG_SESSION_ID=self \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/userbus "$@" \
        HOOK=$HOOK sh -c '. "$HOOK"; echo "${MULTISESSION_ISOLATE:-none} ${DBUS_SESSION_BUS_ADDRESS:-unset}"'
}
expect "Xsession hook: primary login keeps the user bus" \
    test "$(hook DESKTOP_SESSION=testde-multisession)" = "0 unix:path=/userbus"
fake_session c9 "$me" x11 active
expect "Xsession hook: standalone login hides the user bus from 95dbus_update-activation-env" \
    test "$(hook DESKTOP_SESSION=testde-multisession)" = "1 unset"
expect "Xsession hook: other sessions are left alone" \
    test "$(hook DESKTOP_SESSION=regolith-x11)" = "none unix:path=/userbus"
reset_logind; fake_session self "$me" x11 active
echo "ISOLATE=always" >"$D/etc/multisession.conf"; decide standalone "ISOLATE=always"
echo "ISOLATE=never" >"$D/etc/multisession.conf"; fake_session c8 "$me" x11 active; decide primary "ISOLATE=never"
reset_logind

echo "# configuration mistakes"
mkdir -p "$T/badconf"; printf 'ISOLATE=always\nthis-is-not-a-command\n' >"$T/badconf/multisession.conf"
expect "a broken config line is logged, not fatal" \
    bash -c "MULTISESSION_SYSCONF=$T/badconf $MS should-isolate 2>&1 | grep -q 'error in $T/badconf/multisession.conf'"
expect "the rest of a broken config still applies" env MULTISESSION_SYSCONF="$T/badconf" "$MS" should-isolate

echo "# plan: components and autostart"
cat >"$T/share/gnome-session/sessions/testde.session" <<EOF
[GNOME Session]
Name=Test
RequiredComponents=comp-desktop;comp-unit;testde-wm;comp-missing;
EOF
# GLib skips entries whose program does not exist: give every fixture one
F=$T/fakebin; mkdir -p "$F"
for p in comp-desktop testde-wm plain-app early hidden disabled kde fb nottest x cond dup system-version \
         session-version user-plain; do
    printf '#!/bin/sh\n' >"$F/$p"; chmod +x "$F/$p"
done
printf '[Desktop Entry]\nType=Application\nName=c\nExec=%s --replace %%U\n' "$F/comp-desktop" \
    >"$T/share/applications/comp-desktop.desktop"
printf '[Desktop Entry]\nType=Application\nName=wm\nExec=%s\n' "$F/testde-wm" >"$T/share/applications/testde-wm.desktop"
plan_unit_ok=0; [[ -f /usr/local/lib/systemd/user/comp-unit.service ]] && plan_unit_ok=1   # debian/tests/multisession
ae() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%s\n' "$2" "$F/$3" "${4:-}" >"$1/$2.desktop"; }
ae "$T/xdg/autostart" plain plain-app
ae "$T/xdg/autostart" early-one early "X-GNOME-Autostart-Phase=Initialization"
ae "$T/xdg/autostart" hidden hidden "Hidden=true"
ae "$T/xdg/autostart" disabled disabled "X-GNOME-Autostart-enabled=false"
ae "$T/xdg/autostart" only-kde kde "OnlyShowIn=KDE;"
ae "$T/xdg/autostart" only-flashback fb "OnlyShowIn=GNOME-Flashback;"
ae "$T/xdg/autostart" not-testde nottest "NotShowIn=TestDE;"
ae "$T/xdg/autostart" tryexec-missing x "TryExec=/nonexistent/binary"
ae "$T/xdg/autostart" cond-missing cond "AutostartCondition=if-exists multisession-test-flag"
ae "$T/xdg/autostart" comp-desktop dup ""
ae "$T/xdg/autostart" overridden system-version
ae "$T/xdg-test/autostart" overridden session-version
ae "$HOME/.config/autostart" plain user-plain "Hidden=true"
plan=$(XDG_CURRENT_DESKTOP=TestDE:GNOME-Flashback XDG_CONFIG_DIRS="$T/xdg-test:$T/xdg" \
    "$LIB/msagent" plan --gnome-session testde --skip testde-wm, --autostart 2>"$T/plan.err")
has() { grep -qxF "$1" <<<"$plan"; }
expect "component from its desktop entry, field codes dropped" has "early	$F/comp-desktop --replace"
if ((plan_unit_ok)); then
    expect "component from its systemd unit, prefix and %h handled" has "early	/usr/libexec/comp-unit --flag $HOME"
    expect "service the session's systemd target wants" has "early	/usr/libexec/target-svc"
    expect "... a component it also wants starts once" test "$(grep -c comp-unit <<<"$plan")" -eq 1
fi
expect "window manager component skipped" bash -c "! grep -q testde-wm <<<'$plan'"
expect "unresolvable component logged" grep -q "comp-missing" "$T/plan.err"
expect "early autostart phase" has "early	$F/early"
expect "OnlyShowIn matching XDG_CURRENT_DESKTOP" has "late	$F/fb"
expect "session XDG dir overrides /etc/xdg" has "late	$F/session-version"
for gone in plain-app user-plain hidden disabled kde nottest /x cond dup system-version; do
    expect "autostart skips $gone" bash -c "! grep -q -- '$gone' <<<'$plan'"
done
expect "plan has exactly the expected entries" test "$(wc -l <<<"$plan")" -eq $((4 + 2 * plan_unit_ok)) || printf "%s\n" "$plan"

# ---- a user bus, as the user's first session has it ---------------------------
echo "# standalone sessions"
dbus-daemon --session --address="unix:path=$XDG_RUNTIME_DIR/bus" --fork --print-pid >"$T/userbus.pid"
USER_BUS=unix:path=$XDG_RUNTIME_DIR/bus
DBUS_SESSION_BUS_ADDRESS=$USER_BUS gsettings set org.gnome.desktop.interface cursor-size 24
DBUS_SESSION_BUS_ADDRESS=$USER_BUS gsettings set org.gnome.desktop.interface text-scaling-factor 1.0

# The "window manager" of the test session: i3 on its display, plus probes
cat >"$T/bin/probe-wm" <<'EOF'
#!/bin/bash
out=$1
{
    echo "bus=$DBUS_SESSION_BUS_ADDRESS"
    echo "path=$PATH"
    echo "xdg_config_dirs=$XDG_CONFIG_DIRS"
    echo "desktop_session=${DESKTOP_SESSION:-}"
    echo "mode=$MULTISESSION_MODE"
    echo "gdsid=${GNOME_DESKTOP_SESSION_ID:-}"
} >"$out.env"
systemctl --user import-environment DISPLAY >"$out.systemctl" 2>&1; echo "rc=$?" >>"$out.systemctl"
systemctl --user cat some.service >/dev/null 2>&1; echo "query_rc=$?" >>"$out.systemctl"
gdbus call --session --dest org.gnome.SessionManager --object-path /org/gnome/SessionManager \
    --method org.gnome.SessionManager.IsSessionRunning >"$out.sm" 2>&1
cookie=$(gdbus call --session --dest org.gnome.SessionManager --object-path /org/gnome/SessionManager \
    --method org.gnome.SessionManager.Inhibit test 0 testing 8 2>&1)
echo "inhibit=$cookie" >>"$out.sm"
gdbus call --session --dest org.gnome.SessionManager --object-path /org/gnome/SessionManager \
    --method org.gnome.SessionManager.IsInhibited 8 >>"$out.sm" 2>&1
exec i3 -c /dev/null -V >"$out.i3log" 2>&1
EOF
chmod +x "$T/bin/probe-wm"
# A fake compositor: a binary named picom (comm, argv[0] and exe), for the process shims
cp /usr/bin/python3 "$T/bin/picom"

start_session() { # <n> → standalone session n on display :n
    local n=$1
    Xvfb ":$n" -nolisten tcp -noreset >/dev/null 2>&1 &
    for _ in $(seq 50); do xdpyinfo -display ":$n" >/dev/null 2>&1 && break; sleep 0.1; done
    cat >"$T/etc/profiles/testde.conf" <<EOF
WM_EXEC="$T/bin/probe-wm $T/s"'\$MULTISESSION_INSTANCE_TAG'
GNOME_SESSION=""
AUTOSTART=false
XDG_CONFIG_PREFIX=/etc/xdg/xdg-testde
standalone_setup() { export GNOME_DESKTOP_SESSION_ID=this-is-deprecated; }
EOF
    # What LightDM and the Xsession hook hand to the session
    env DISPLAY=":$n" XDG_SESSION_ID="t$n" MULTISESSION_INSTANCE_TAG="$n" \
        DESKTOP_SESSION=testde-multisession XDG_CONFIG_DIRS="/etc/xdg/xdg-testde-multisession:$XDG_CONFIG_DIRS" \
        DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
        setsid "$MS" launch testde >"$T/launch$n.log" 2>&1 &
    echo $! >"$T/launch$n.pid"
}

start_session 1
start_session 2
for _ in $(seq 100); do [[ -s $T/s1.sm && -s $T/s2.sm ]] && break; sleep 0.1; done
sleep 1

for n in 1 2; do
    expect "session $n: own private bus" bash -c "grep -q '^bus=' $T/s$n.env && ! grep -qF 'bus=$USER_BUS' $T/s$n.env"
    expect "session $n: standalone mode" grep -qx "mode=standalone" "$T/s$n.env"
    expect "session $n: shims first on PATH" grep -q "^path=$LIB/shims:" "$T/s$n.env"
    expect "session $n: session name restored for the session" grep -qx "desktop_session=testde" "$T/s$n.env"
    expect "session $n: XDG dirs use the session's own name" grep -q "^xdg_config_dirs=/etc/xdg/xdg-testde:" "$T/s$n.env"
    expect "session $n: profile setup ran" grep -qx "gdsid=this-is-deprecated" "$T/s$n.env"
    expect "session $n: systemctl --user import-environment refused" grep -q "refused 'systemctl --user import-environment DISPLAY'" "$T/s$n.systemctl"
    expect "session $n: it fails, as without a user manager" grep -qx "rc=1" "$T/s$n.systemctl"
    expect "session $n: systemctl --user queries fail too" grep -qx "query_rc=1" "$T/s$n.systemctl"
    expect "session $n: session manager answers" grep -qx "(true,)" "$T/s$n.sm"
    expect "session $n: inhibit gives a cookie" grep -q "^inhibit=(uint32 1,)" "$T/s$n.sm"
    expect "session $n: IsInhibited reflects it" bash -c "tail -n1 $T/s$n.sm | grep -qx '(true,)'"
    expect "session $n: i3 runs on :$n" test -n "$(live -f "i3 -c /dev/null")"
done
expect "two i3 instances" test "$(count -x i3)" -eq 2

# Settings: both sessions write through the user bus's single dconf-service
bus1=$(sed -n 's/^bus=//p' "$T/s1.env"); bus2=$(sed -n 's/^bus=//p' "$T/s2.env")
DBUS_SESSION_BUS_ADDRESS=$bus2 gsettings set org.gnome.desktop.interface cursor-size 48
DBUS_SESSION_BUS_ADDRESS=$bus1 gsettings set org.gnome.desktop.interface text-scaling-factor 1.5
sleep 0.5
expect "no setting lost between sessions (cursor-size kept)" \
    test "$(DBUS_SESSION_BUS_ADDRESS=$USER_BUS gsettings get org.gnome.desktop.interface cursor-size)" = 48
expect "no setting lost between sessions (text-scaling-factor)" \
    test "$(DBUS_SESSION_BUS_ADDRESS=$USER_BUS gsettings get org.gnome.desktop.interface text-scaling-factor)" = 1.5
expect "one dconf-service for the user" test "$(count -x dconf-service)" -eq 1
expect "dconf bridged in session 1" test -n "$(live -f "msagent bridge ca.desrt.dconf")"

# Change signals reach the sessions
DBUS_SESSION_BUS_ADDRESS=$bus1 timeout 3 dconf watch /org/gnome/desktop/interface/ >"$T/watch1" 2>&1 &
sleep 0.7
DBUS_SESSION_BUS_ADDRESS=$USER_BUS gsettings set org.gnome.desktop.interface cursor-size 32
sleep 1
expect "change from the user bus seen in session 1" grep -q "cursor-size" "$T/watch1"

# pgrep/pkill shim: a session only matches its own display's processes
DISPLAY=:1 "$T/bin/picom" -c 'import time; time.sleep(300)' & p1=$!
DISPLAY=:2 "$T/bin/picom" -c 'import time; time.sleep(300)' & p2=$!
sleep 0.2
SHIMENV=("MULTISESSION_SHIM_DIR=$LIB/shims" "MULTISESSION_DISPLAY_SCOPED=picom compton"
         PATH="$LIB/shims:$PATH")
expect "pidof in session 2 names only its own picom" test "$(env "${SHIMENV[@]}" DISPLAY=:2 pidof picom)" = "$p2"
expect "pgrep of unlisted programs passes through" \
    test "$(env "${SHIMENV[@]}" DISPLAY=:9 pgrep -u "$(id -u)" -x dconf-service)" = "$(pgrep -u "$(id -u)" -x dconf-service)"
env "${SHIMENV[@]}" DISPLAY=:1 pkill -U "$(id -u)" -x picom
sleep 0.3
expect "pkill -U in session 1 stops session 1's picom" bash -c "! kill -0 $p1 2>/dev/null"
expect "pkill -U in session 1 leaves session 2's picom" kill -0 "$p2"
expect "pgrep -u in session 2 finds only its own" test "$(env "${SHIMENV[@]}" DISPLAY=:2 pgrep -u "$(id -u)" -x picom)" = "$p2"
kill "$p2" 2>/dev/null

# Logout through the session manager ends session 1 only
DBUS_SESSION_BUS_ADDRESS=$bus1 gdbus call --session --dest org.gnome.SessionManager \
    --object-path /org/gnome/SessionManager --method org.gnome.SessionManager.Logout 1 >/dev/null
for _ in $(seq 50); do kill -0 "$(cat "$T/launch1.pid")" 2>/dev/null || break; sleep 0.1; done
expect "logout ends session 1" bash -c "! kill -0 $(cat "$T/launch1.pid") 2>/dev/null"
for _ in $(seq 30); do [[ -d $XDG_RUNTIME_DIR/multisession/t1 ]] || break; sleep 0.1; done
expect "session 1 cleaned up its runtime dir" test ! -d "$XDG_RUNTIME_DIR/multisession/t1"
expect "session 2 still runs" kill -0 "$(cat "$T/launch2.pid")"
expect "one i3 left" test "$(count -x i3)" -eq 1
expect "user bus and its dconf-service survive" test "$(count -x dconf-service)" -eq 1

# Window manager exit ends session 2
pkill -u "$(id -u)" -x i3
for _ in $(seq 50); do kill -0 "$(cat "$T/launch2.pid")" 2>/dev/null || break; sleep 0.1; done
expect "window manager exit ends session 2" bash -c "! kill -0 $(cat "$T/launch2.pid") 2>/dev/null"
for _ in $(seq 30); do [[ -n $(live -f '[m]sagent') ]] || break; sleep 0.1; done
expect "no bridges left behind" test -z "$(live -f '[m]sagent')"

echo
echo "$pass passed, $fail failed"
if ((fail)); then
    echo "--- processes"; ps -u "$(id -u)" -o pid,ppid,stat,args
    for f in "$T"/launch*.log "$T"/plan.err; do echo "--- $f"; cat "$f"; done
    exit 1
fi
