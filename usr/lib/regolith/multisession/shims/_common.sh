# Sourced by the regolith-multisession shims.

# Drop the shim directory from PATH, so that the shim can run the real command
ms_real_path() {
    if [ -n "${MULTISESSION_SHIM_DIR:-}" ]; then
        PATH=$(printf '%s' ":$PATH:" | sed "s#:$MULTISESSION_SHIM_DIR:#:#g; s#^:##; s#:\$##")
        export PATH
    fi
}

ms_log() {
    printf 'regolith-multisession: %s\n' "$*" >&2
    logger -t regolith-multisession -- "$*" 2>/dev/null || :
}

# Whether <name> is a per-display program (MULTISESSION_DISPLAY_SCOPED)
ms_display_scoped() {
    case " ${MULTISESSION_DISPLAY_SCOPED:-} " in
        *" $1 "*) [ -n "$1" ] ;;
        *) return 1 ;;
    esac
}

# Whether process <pid> runs on this session's display. A process that is
# exiting has no readable environment any more: count it, so that callers
# wait until it is gone (it may still hold its display, e.g. a compositor's
# selection), and a signal to it is harmless.
ms_on_display() {
    if [ -r "/proc/$1/environ" ] && env_=$(tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null) && [ -n "$env_" ]; then
        printf '%s\n' "$env_" | grep -qxF "DISPLAY=$DISPLAY"
    else
        # Still there, and not a zombie (which holds nothing any more)
        [ -r "/proc/$1/stat" ] && [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]
    fi
}
