#!/bin/bash
# This script contains common functions for Regolith session management

# File Locations - Optional User Overrides
USER_XRESOURCE_OVERRIDE_FILE="$HOME/.config/regolith3/Xresources"
USER_XRESOURCE_SEARCH_PATH="$HOME/.config/regolith3/Xresources.d"

# File Locations - System Defaults
DEFAULT_XRESOURCE_LOOK_PATH="/usr/share/regolith-look/default"

DEFAULT_SYS_I3_CONFIG_FILE="/etc/regolith/i3/config"
DEFAULT_USER_I3_CONFIG_FILE="$HOME/.config/regolith3/i3/config"

DEFAULT_SYS_SWAY_CONFIG_FILE="/etc/regolith/sway/config"
DEFAULT_USER_SWAY_CONFIG_FILE="$HOME/.config/regolith3/sway/config"

# File Locations - Baseline
BASELINE_XRESOURCE_FILE="$HOME/.Xresources"

# Regolith Look directories
DEFAULT_LOOK_ROOT="/usr/share/regolith-look"
USER_LOOK_ROOT="$HOME/.config/regolith3/looks"

# File location - user scripts
USER_POST_LOGOUT_SCRIPT_FILE="$HOME/.config/regolith3/logout"

# File location - text scaling factor set from the user's Xft.dpi
XFT_DPI_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/regolith/xft-dpi-text-scaling-factor"

DEFAULT_SESSION_TYPE="i3"

# Preprocessor for Xresources files; keeps non-ASCII values as they are
XRES_CPP="/usr/lib/regolith/regolith-xres-cpp"

# Set the default resource getter
RESOURCE_GETTER="xrescat"
if [ "${XDG_SESSION_TYPE-}" == "wayland" ]; then
	RESOURCE_GETTER="trawlcat"
fi

# Add the variables set in environment.d to the environment of a session that
# gnome-session runs itself (--builtin), as systemd gives them to the services
# of a systemd-managed session. Variables of the login environment win, as in
# that session, where gnome-session imports them into the user manager.
# Ubuntu and Debian link /etc/environment into environment.d, so the PATH
# Ubuntu sets there would otherwise replace the PATH that ~/.profile set.
import_environment_d() {
    local generator=/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
    local line name
    [ -x "$generator" ] || return 0
    while IFS= read -r line; do
        name=${line%%=*}
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # The generator quotes values for the shell, as in VAR="a b"
        if [ -z "${!name+set}" ]; then
            eval "export -- $line"
        fi
    done < <("$generator")
}

# Drop the IPC socket variables of an earlier session. The sway session puts
# SWAYSOCK and I3SOCK into the systemd user environment, and the user manager
# outlives a logout while the user has another session (ssh, lingering, a
# quick new login), so the next session's services and window manager inherit
# them. i3 takes I3SOCK as the path for its own IPC socket, so it would listen
# on the dead sway socket's path, and a stale SWAYSOCK makes tools believe
# they run under sway. The window managers set the variables they need.
clear_wm_sockets() {
    unset I3SOCK SWAYSOCK
    systemctl --user unset-environment I3SOCK SWAYSOCK 2>/dev/null || :
}

# Drop the IPC socket variables in this process only. An additional X11
# session uses this instead of clear_wm_sockets: the systemd user manager
# is shared by every session of the user, so unsetting I3SOCK and SWAYSOCK
# there would remove the first session's variables.
clear_wm_sockets_local() {
    unset I3SOCK SWAYSOCK
}

# State file of the primary (gnome-session) X11 session, written by
# regolith-session-x11-launch in the per-user runtime directory before it
# execs gnome-session, so $$ and later gnome-session share a PID. It lets
# later logins find that session and restore the user manager environment
# that a display manager's Xsession uploaded this login's values over.
REGOLITH_X11_PRIMARY_SESSION_FILE="${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/regolith-x11-primary-session}"

# Record this process as the primary X11 session. Called just before exec
# of gnome-session, whose leader process keeps this PID for the session.
regolith_x11_record_primary_session() {
    local file=${REGOLITH_X11_PRIMARY_SESSION_FILE-}
    local tmp
    [ -n "$file" ] || return 0
    [ -d "${XDG_RUNTIME_DIR-}" ] || return 0
    tmp="$file.tmp.$$"
    printf 'PID=%s\nDISPLAY=%s\nXAUTHORITY=%s\n' \
        "$$" "${DISPLAY-}" "${XAUTHORITY-}" > "$tmp" 2>/dev/null || return 0
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || :
}

# Directory with one file per running Regolith X11 session script of
# this user, named by its PID. A login that reaches regolith-session-x11
# directly, without the launcher or a user manager that can be asked,
# is found through these files instead.
REGOLITH_X11_SESSIONS_DIR="${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/regolith-x11-sessions}"

# Record this session script as running, and remove the record when it
# ends. Stale records name a dead PID and are ignored.
regolith_x11_register_running_session() {
    local dir=${REGOLITH_X11_SESSIONS_DIR-} file
    [ -n "$dir" ] || return 0
    [ -d "${XDG_RUNTIME_DIR-}" ] || return 0
    mkdir -p "$dir" 2>/dev/null || return 0
    file="$dir/$$"
    printf 'PID=%s\nDISPLAY=%s\nXAUTHORITY=%s\n' \
        "$$" "${DISPLAY-}" "${XAUTHORITY-}" > "$file" 2>/dev/null || return 0
    REGOLITH_X11_RUNNING_SESSION_FILE="$file"
    trap 'rm -f "${REGOLITH_X11_RUNNING_SESSION_FILE-}"' EXIT
}

# Is a Regolith X11 session script of this user already running?
regolith_x11_running_session_active() {
    local dir=${REGOLITH_X11_SESSIONS_DIR-} entry pid cmdline
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    for entry in "$dir"/*; do
        [ -f "$entry" ] || continue
        pid=$(sed -n 's/^PID=//p' "$entry" | head -n 1)
        case $pid in ''|*[!0-9]*) continue ;; esac
        [ "$pid" -gt 0 ] 2>/dev/null || continue
        kill -0 "$pid" 2>/dev/null || continue
        if [ -r "/proc/$pid/cmdline" ]; then
            cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")
            case $cmdline in
                *"/regolith-session-x11 "*|*" regolith-session-x11 "*) return 0 ;;
                *) continue ;;
            esac
        else
            return 0
        fi
    done
    return 1
}

# Is the primary, gnome-session-managed Regolith X11 session of this user
# already running? The user manager and its gnome-session targets are
# singletons per user, so a second gnome-session for the same user cannot
# start alongside it. A running session script counts too: a new
# gnome-session cannot be started next to it either.
regolith_x11_primary_session_active() {
    local file=${REGOLITH_X11_PRIMARY_SESSION_FILE-} pid cmdline unit
    if [ -n "$file" ] && [ -f "$file" ]; then
        pid=$(sed -n 's/^PID=//p' "$file" | head -n 1)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if [ -r "/proc/$pid/cmdline" ]; then
                cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")
                case $cmdline in
                    *gnome-session*) return 0 ;;
                esac
            else
                return 0
            fi
        fi
    fi
    if regolith_x11_running_session_active; then
        return 0
    fi
    if command -v systemctl > /dev/null 2>&1; then
        for unit in regolith-x11.service \
                    gnome-session@regolith-x11.target \
                    gnome-session-x11@regolith-x11.target \
                    regolith-x11.target; do
            if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
                return 0
            fi
        done
    fi
    return 1
}

# Print "DISPLAY XAUTHORITY" of the primary session, from the state file,
# or failing that from the environment of regolith-x11.service's main
# process, which started with the primary session's values.
regolith_x11_primary_session_env() {
    local file=${REGOLITH_X11_PRIMARY_SESSION_FILE-} display= xauthority= pid line
    if [ -n "$file" ] && [ -f "$file" ]; then
        display=$(sed -n 's/^DISPLAY=//p' "$file" | head -n 1)
        xauthority=$(sed -n 's/^XAUTHORITY=//p' "$file" | head -n 1)
    fi
    if [ -z "$display" ] && command -v systemctl > /dev/null 2>&1; then
        pid=$(systemctl --user show -p MainPID --value regolith-x11.service 2>/dev/null) || pid=
        case $pid in ''|*[!0-9]*) pid= ;; esac
        if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && [ -r "/proc/$pid/environ" ]; then
            while IFS= read -r -d '' line || [ -n "$line" ]; do
                case $line in
                    DISPLAY=*) display=${line#DISPLAY=} ;;
                    XAUTHORITY=*) xauthority=${line#XAUTHORITY=} ;;
                esac
            done < "/proc/$pid/environ"
        fi
    fi
    [ -n "$display" ] || return 1
    printf '%s\n%s\n' "$display" "$xauthority"
}

# Put the primary session's DISPLAY and XAUTHORITY back into the systemd
# user manager (and the D-Bus activation environment) when something since
# that session started, such as this login's Xsession scripts, uploaded
# the new session's values over them. This login keeps its own values in
# its own process environment; only the shared record for the first
# session is restored. I3SOCK is never touched: it still holds the first
# session's i3 socket.
regolith_x11_restore_primary_session_env() {
    local primary display xauthority current cur_display= cur_xauthority=
    command -v systemctl > /dev/null 2>&1 || return 0
    primary=$(regolith_x11_primary_session_env) || return 0
    display=$(printf '%s\n' "$primary" | sed -n '1p')
    xauthority=$(printf '%s\n' "$primary" | sed -n '2p')
    [ -n "$display" ] || return 0
    current=$(systemctl --user show-environment 2>/dev/null) || return 0
    cur_display=$(printf '%s\n' "$current" | sed -n 's/^DISPLAY=//p' | head -n 1)
    cur_xauthority=$(printf '%s\n' "$current" | sed -n 's/^XAUTHORITY=//p' | head -n 1)
    if [ "$cur_display" = "$display" ] && [ "$cur_xauthority" = "$xauthority" ]; then
        return 0
    fi
    if [ -n "$xauthority" ]; then
        systemctl --user set-environment "DISPLAY=$display" "XAUTHORITY=$xauthority" 2>/dev/null || return 0
        if [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ] \
           && command -v dbus-update-activation-environment > /dev/null 2>&1; then
            dbus-update-activation-environment "DISPLAY=$display" "XAUTHORITY=$xauthority" 2>/dev/null || :
        fi
    else
        systemctl --user set-environment "DISPLAY=$display" 2>/dev/null || return 0
        if [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ] \
           && command -v dbus-update-activation-environment > /dev/null 2>&1; then
            dbus-update-activation-environment "DISPLAY=$display" 2>/dev/null || :
        fi
    fi
    return 0
}

# Determine where the default i3 and sway config files are
# Sets I3_CONFIG_FILE and SWAY_CONFIG_FILE
resolve_default_config_file() {
    if [ -e "$DEFAULT_USER_I3_CONFIG_FILE" ]; then
        I3_CONFIG_FILE="$DEFAULT_USER_I3_CONFIG_FILE"
    else
        I3_CONFIG_FILE="$DEFAULT_SYS_I3_CONFIG_FILE"
    fi
    
    # To be changed with sway config locations
    if [ -f "$DEFAULT_USER_SWAY_CONFIG_FILE" ]; then
        SWAY_CONFIG_FILE="$DEFAULT_USER_SWAY_CONFIG_FILE"
    else
        SWAY_CONFIG_FILE="$DEFAULT_SYS_SWAY_CONFIG_FILE"
    fi
}

# Load default Xresources
load_standard_xres() {
    if [ -e "$BASELINE_XRESOURCE_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -merge "$BASELINE_XRESOURCE_FILE"
    fi
}

# Load default Xresources
load_standard_trawlres() {
    if [ -f "$BASELINE_XRESOURCE_FILE" ]; then
        trawldb --cpp "$XRES_CPP" --merge "$BASELINE_XRESOURCE_FILE"
    fi
}

# Change the quotes in workspace names from double to to single.
# Due to a limitation of the preprocessor they have double quotes.
# The i3-wm workspace command fails with double quotes in the name
# grep exits 1 when no workspace names are defined; callers run with
# "set -e -o pipefail", so that must not end the script (it once stopped
# the X11 login before i3 started, which is why the call was removed then).
xres_i3_cleanup() {
    xrdb -query | { grep wm.workspace. || true; } | sed "s/\"/'/g" | xrdb -nocpp -merge
}

trawl_sway_cleanup() {
    trawldb --query wm.workspace.|sed "s/\"/'/g" > $XDG_RUNTIME_DIR/trawl_sway_cleanup.tmp
    trawldb --nocpp --merge $XDG_RUNTIME_DIR/trawl_sway_cleanup.tmp
}

# Set DEFAULT_XRESOURCE_LOOK_PATH to the look used when regolith.look.path is
# not set: the most recently installed look directory, by birth time, as
# package updates change the mtime. Use the mtime where there is no birth time.
resolve_default_look_path() {
    local by_birth=--time=birth newest
    if stat -c %W "$DEFAULT_LOOK_ROOT"/*/ 2>/dev/null | grep -vx '[1-9][0-9]*' >/dev/null; then
        by_birth=
    fi
    newest=$(ls -td ${by_birth:+"$by_birth"} "$DEFAULT_LOOK_ROOT"/*/ 2>/dev/null | head -n 1) || true
    if [ -d "$newest" ]; then
        DEFAULT_XRESOURCE_LOOK_PATH="${newest%/}"
    fi
}

# 1. Load the Regolith Xresource override file if exists
# 2. Load Regolith Look Xresource as defined in override or use default
# 3. Re-merge Regolith Xresource override file if exists
load_regolith_xres() {
    if [ -e "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi

    resolve_default_look_path

    LOOK_STYLE_ROOT_PATH=$(xrescat regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH")

    if [ -d "$LOOK_STYLE_ROOT_PATH" ]; then
        LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"
    else 
        LOOK_STYLE_ROOT_FILE="$DEFAULT_XRESOURCE_LOOK_PATH/root"
    fi

    if [ -e "$LOOK_STYLE_ROOT_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$LOOK_STYLE_ROOT_FILE"
    fi #TODO: emit some dialog notifying user of invalid configuration on else

    if [ -e "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        xrdb -cpp "$XRES_CPP" -I"$USER_XRESOURCE_SEARCH_PATH" -merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi
}

# In the X11 session gsd-xsettings owns Xft.dpi: it publishes 96 dpi times
# org.gnome.desktop.interface text-scaling-factor, times the UI scale of GNOME
# Flashback, over XSETTINGS, where GTK reads it, and writes the same value into
# the X resources over the user's own. To keep an Xft.dpi set in ~/.Xresources
# or the Regolith Xresources working, set the text scaling factor that makes
# gsd-xsettings publish that value. The factor is recorded so that removing
# Xft.dpi later resets it, unless it was changed elsewhere in the meantime.
apply_user_xft_dpi() {
    command -v gsettings >/dev/null 2>&1 || return 0
    local file value dpi="" current scale=1 factor
    # Later files win, as in the login path
    for file in "$BASELINE_XRESOURCE_FILE" "$USER_XRESOURCE_OVERRIDE_FILE"; do
        [ -e "$file" ] || continue
        value=$(xrdb -n -I"$USER_XRESOURCE_SEARCH_PATH" -load "$file" 2>/dev/null \
                | sed -n 's/^Xft\.dpi:[[:space:]]*//p' | tail -n 1) || true
        [ -z "$value" ] || dpi=$value
    done
    current=$(gsettings get org.gnome.desktop.interface text-scaling-factor 2>/dev/null) || return 0

    if [ -z "$dpi" ]; then
        if [ -f "$XFT_DPI_STATE_FILE" ]; then
            if same_number "$current" "$(cat "$XFT_DPI_STATE_FILE")"; then
                gsettings reset org.gnome.desktop.interface text-scaling-factor
            fi
            rm -f "$XFT_DPI_STATE_FILE"
        fi
        return 0
    fi
    case $dpi in
        *[!0-9.]* | .* | *.*.*)
            echo "Ignoring Xft.dpi: $dpi is not a number" >&2
            return 0 ;;
    esac

    # gsd-xsettings uses a UI scale of 1 if GNOME Flashback does not answer.
    # Flashback starts with the session, so wait for it briefly.
    if command -v gdbus >/dev/null 2>&1 \
       && gdbus wait --session --timeout 5 org.gnome.Mutter.X11 >/dev/null 2>&1; then
        scale=$(gdbus call --session --dest org.gnome.Mutter.X11 \
                    --object-path /org/gnome/Mutter/X11 \
                    --method org.freedesktop.DBus.Properties.Get \
                    org.gnome.Mutter.X11 UiScalingFactor 2>/dev/null \
                | tr -cd '0-9') || true
        [ "${scale:-0}" -ge 1 ] 2>/dev/null || scale=1
    fi
    factor=$(awk -v dpi="$dpi" -v scale="$scale" 'BEGIN { printf "%.17g", dpi / (96 * scale) }')
    if ! same_number "$current" "$factor"; then
        gsettings set org.gnome.desktop.interface text-scaling-factor "$factor"
    fi
    mkdir -p "${XFT_DPI_STATE_FILE%/*}"
    echo "$factor" > "$XFT_DPI_STATE_FILE"
}

same_number() { # same_number <a> <b>
    awk -v a="$1" -v b="$2" 'BEGIN { exit !((a - b) ^ 2 < 1e-12) }'
}

# Loads the Xresource files into trawl. 
# NOTE: Will load sway specific reource files
load_regolith_trawlres() {
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        trawldb --cpp "$XRES_CPP" -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi

    resolve_default_look_path

    LOOK_STYLE_ROOT_PATH=$(trawlcat regolith.look.path "$DEFAULT_XRESOURCE_LOOK_PATH")

    if [ -d "$LOOK_STYLE_ROOT_PATH" ]; then
        LOOK_STYLE_ROOT_FILE="$LOOK_STYLE_ROOT_PATH/root"
    else 
        LOOK_STYLE_ROOT_FILE="$DEFAULT_XRESOURCE_LOOK_PATH/root"
    fi

    if [ -f "$LOOK_STYLE_ROOT_FILE" ]; then
        trawldb --cpp "$XRES_CPP" -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$LOOK_STYLE_ROOT_FILE" 
    fi #TODO: emit some dialog notifying user of invalid configuration on else
    
    if [ -f "$USER_XRESOURCE_OVERRIDE_FILE" ]; then
        trawldb --cpp "$XRES_CPP" -I "$USER_XRESOURCE_SEARCH_PATH" --merge "$USER_XRESOURCE_OVERRIDE_FILE"
    fi
}

# Merge the system resources, as the display manager's Xsession does
# source ~ https://git.launchpad.net/ubuntu/+source/gdm3/tree/debian/patches/ubuntu/xresources_is_a_dir.patch?h=applied/ubuntu/noble
load_system_xres() {
    local sysresources=/etc/X11/Xresources i
    for i in `ls "$sysresources" 2>/dev/null` ; do
        if [ -r "$sysresources/$i"  -a -f "$sysresources/$i" ] && expr "$i" : '^[[:alnum:]_-]\+$' > /dev/null; then
            xrdb -nocpp -merge "$sysresources/$i"
        fi
    done
}

# Load the X resources as the login does: ~/.Xresources first, then the
# Regolith Xresources and the look, which win over it
load_i3_resources() {
    load_standard_xres # ~/.Xresources
    load_regolith_xres # ~/.config/regolith3/Xresources and the look
    xres_i3_cleanup    # Single-quote workspace names for i3
    apply_user_xft_dpi # Xft.dpi from the files above, through gsd-xsettings
}

# Load the trawl resources as the login does
load_sway_resources() {
    load_standard_trawlres
    load_regolith_trawlres
    # workaround to prevent always loading the default look
    load_regolith_trawlres
    trawl_sway_cleanup
}

# Start the X resource database again from what it holds before the login
# loads the files: clear it and merge the system resources as the display
# manager does. Loading the files into it then rebuilds it as a login does;
# merging into the old database instead would keep resources that the
# previous look set and the new one doesn't, or that the user removed from
# their files. Resources merged by hand or by programs, outside any file, go
# too, except gsd-xsettings' Xft.* and Xcursor.*: it writes them only when its
# settings change, and X programs (i3 too) take the DPI from Xft.dpi.
clear_xres() {
    local xsettings
    xsettings=$(xrdb -query | grep -E '^(Xft|Xcursor)\.' || true)
    xrdb -remove
    load_system_xres
    if [ -n "$xsettings" ]; then
        printf '%s\n' "$xsettings" | xrdb -nocpp -merge
    fi
}

# Rebuild the X resources from scratch, as the login builds them
reload_i3_resources() {
    clear_xres
    load_i3_resources
}

# Rebuild trawl's resources from scratch. trawld runs as long as the user's
# systemd instance, so it can also hold an earlier session's resources.
reload_sway_resources() {
    trawldb --remove
    load_sway_resources
}
