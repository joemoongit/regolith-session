# Functions telling whether the user's systemd instance already runs a
# Regolith X11 session. POSIX sh, sourced by regolith-session-x11-launch.
#
# gnome-session runs one session per systemd user instance: it refuses to
# start while the instance's gnome-session-<type>@<session>.target
# (gnome-session 48 and 49) or graphical-session.target (gnome-session 50) is
# active, and the display manager shows the greeter again.

# regolith_session_target_active: succeeds if gnome-session would refuse to
# start a session in the user's systemd instance
regolith_session_target_active() {
    systemctl --user is-active --quiet graphical-session.target \
        "gnome-session-${XDG_SESSION_TYPE:-x11}@regolith-x11.target"
}

# regolith_session_leader_running: succeeds if the leader of a session in the
# user's systemd instance runs in another login session that has not ended.
# The leader is the gnome-session process that stays in the scope of the login
# session (gnome-session-init-worker on gnome-session 50, gnome-session-binary
# before) and that has the instance's XDG_RUNTIME_DIR. The display manager
# ends the login when it exits.
regolith_session_leader_running() {
    for _regolith_pid in $(pgrep -u "$(id -u)" '^gnome-session'); do
        _regolith_session=$(sed -n 's|^0::.*/session-\(.*\)\.scope$|\1|p' "/proc/$_regolith_pid/cgroup" 2>/dev/null)
        [ -n "$_regolith_session" ] && [ "$_regolith_session" != "${XDG_SESSION_ID-}" ] || continue
        grep -qzxF "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR-}" "/proc/$_regolith_pid/environ" 2>/dev/null || continue
        case $(loginctl show-session --property=State --value "$_regolith_session" 2>/dev/null) in
            active|online) return 0 ;;
        esac
    done
    return 1
}

# regolith_session_stop_stale: stops what is left of a session whose leader
# has exited, the way gnome-session ends a session at logout
regolith_session_stop_stale() {
    systemctl --user start gnome-session-shutdown.target || return 1
    # gnome-session-shutdown.target then stops dbus.service, through
    # gnome-session-restart-dbus.service; wait for it, so that the bus doesn't
    # go away while the next session starts
    _regolith_tries=0
    while regolith_session_stopping; do
        _regolith_tries=$((_regolith_tries + 1))
        [ "$_regolith_tries" -le 50 ] || return 1
        sleep 0.2
    done
}

regolith_session_stopping() {
    regolith_session_target_active && return 0
    case $(systemctl --user list-jobs --no-legend) in
        *" gnome-session-restart-dbus.service "*|*" dbus.service "*) return 0 ;;
    esac
    case $(systemctl --user show --property=ActiveState --value gnome-session-restart-dbus.service) in
        inactive|failed) ;;
        *) return 0 ;;
    esac
    case $(systemctl --user show --property=ActiveState --value dbus.service) in
        deactivating) return 0 ;;
    esac
    return 1
}
