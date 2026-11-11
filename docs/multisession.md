# regolith-multisession: any number of Regolith X11 sessions at once

Log in through LightDM as many times as you like: on any number of VTs, as
any number of users, and several times as the same user. Each login is a
full Regolith X11 session with its own i3, bar, gsd plugins, gnome-flashback
and compositor.

```
VT7   joe   Regolith / X11 (multi-session)   primary     stock gnome-session + systemd
VT8   joe   Regolith / X11 (multi-session)   standalone  own bus, own components
VT9   ana   Regolith / X11 (multi-session)   primary     ana's own user manager
VT10  joe   Regolith / X11 (multi-session)   standalone  ...
```

## Why the second login failed

There are two separate problems.

1. **`systemctl restart lightdm` ends every session.** LightDM is a single
   daemon that owns every greeter, X server and session on the seat. When
   you restart it from tty2, it kills the X server under your first
   session, then shows a fresh greeter. To get another login, ask the
   running LightDM for another greeter (`regolith-multisession new`, or
   `dm-tool switch-to-greeter`). It opens one on the next free VT.

2. **gnome-session runs only one graphical session per user.** The
   Regolith X11 entry runs `regolith-session-x11-launch`, which runs
   `gnome-session --session=regolith-x11`.
   - On Ubuntu 26.04, gnome-session 50 runs only on the systemd user
     manager, and it no longer has a `--builtin` mode.
   - It refuses to start while that manager already runs a graphical
     session ("A graphical session is already running!").
   - Before it refuses, it rewrites the first session's `DISPLAY` in the
     user manager.
   - Even without gnome-session, the Regolith i3 config would run
     `systemctl --user import-environment …` and `start regolith-x11.target`
     against the first session's user manager.

`startx` + `dbus-run-session` works because it never runs gnome-session: it
runs `regolith-session-x11` (i3) directly on a private bus. That approach
still has gaps, though:
- The i3 config still writes to the first session's user manager.
- A second `dconf-service` on the same database silently loses settings
  changes.
- Logout, lock and the gsd plugins don't work.
- Restarting the compositor in one session kills the compositor of the
  others.

regolith-multisession builds the standalone path properly and lets the
display manager use it.

## How it works

The package adds **"Regolith / X11 (multi-session)"** to the greeter
(`/usr/share/xsessions/regolith-x11-multisession.desktop`). Its `Exec` is
`regolith-multisession launch regolith-x11`, which picks a mode for each
login:

| Mode | When | What runs |
|---|---|---|
| **primary** | no other session of this user holds the user manager | The stock session, unchanged: gnome-session, systemd units, everything. |
| **standalone** | the user manager is taken (another session of this user, or `graphical-session.target` is active) | The session runs outside the user manager, as described below. |

A standalone session runs like this:

- **Private D-Bus bus.** It runs on a private bus (`dbus-run-session`), with
  generated service files that take priority over the system's:
  - **Bridges** (`msagent bridge`) for per-user services: dconf, secrets
    (gnome-keyring), the portal permission store and the document portal.
    The session talks to the user's single instance on the user bus.
    Method calls and replies are forwarded, and the services' signals are
    re-emitted. Settings changed in any session are kept and show up in
    all of them.
  - **A small `org.gnome.SessionManager`** (`msagent session-manager`).
    Logout ends only this session; shutdown and reboot go to logind; idle
    and suspend inhibitors are tracked here and taken from logind. The
    Regolith logout binding (`gnome-session-quit --logout`) works unchanged.
- **Session components started directly.** These are the
  `RequiredComponents` of `regolith-x11.session` (gsd plugins,
  gnome-flashback), resolved from desktop entries or from systemd user
  units. 26.04 ships the gsd plugins only as units.
- **XDG autostart, run as gnome-session would run it.** It honours
  `OnlyShowIn`/`NotShowIn`, `Hidden`, `TryExec`, `AutostartCondition` and
  phases, and gives `/etc/xdg/xdg-regolith-x11` priority.
- **The window manager runs in the foreground** (`regolith-session-x11`
  → i3). The session ends when it does, or on logout.
- **Shims on `PATH`** keep the session off the first session's state:
  - `systemctl --user` fails, as it does where there is no user manager, so
    the session's scripts take their paths for sessions without systemd.
    For example, the compositor's `init` runs picom itself instead of
    handing this display to the first session's picom service. Attempts to
    change the user manager are logged.
  - `dbus-update-activation-environment`: drops `--systemd`.
  - `pgrep` / `pkill` / `pidof`: for per-display programs (picom by
    default), only this display's process is seen. A compositor restart
    therefore no longer kills other sessions' compositors.
- **An Xsession.d hook** (`94regolith-multisession`) hides the user bus
  address from `95dbus_update-activation-env`, which would otherwise push
  the standalone session's `DISPLAY` into the user manager before
  regolith-multisession runs.
- **Teardown.** Everything runs in the session's own process group, so when
  the session ends, everything it started ends too. Per-display programs on
  the session's display that left the group (`picom --daemon`) are stopped
  as well.

Different users never collide: each user has their own user manager and
user bus. So every user's first login is primary, and their later logins
are standalone.

## Install

```sh
sudo apt install regolith-session-multisession
```

In the greeter, pick **Regolith / X11 (multi-session)** for every login.
LightDM remembers the choice for each user.

## Use

| Command | What it does |
|---|---|
| `regolith-multisession new` | Open one more greeter on the next free VT. Works from a text console (Ctrl+Alt+F2) or from inside a session. Log in there. |
| `regolith-multisession status` | List every graphical session and its mode (`regolith-x11 standalone #2`). |
| `regolith-multisession doctor` | Check the installation, this user's sessions, and recent log lines. |

Switch between sessions with Ctrl+Alt+F7, F8, F9 and so on. To open a
greeter with a key, add a user i3 partial:

```
# ~/.config/regolith3/i3/config.d/90-new-session
bindsym $mod+Ctrl+n exec --no-startup-id regolith-multisession new
```

## Configure and extend

Everything is data in `/etc/regolith/multisession`. Per-user overrides go in
`~/.config/regolith3/multisession/`.

- **Entries.** A session has a multi-session entry when
  `/usr/share/xsessions/<session>-multisession.desktop` exists. To add one
  for another installed session, e.g. i3:
  `regolith-multisession entry i3 | sudo tee /usr/share/xsessions/i3-multisession.desktop`.
- **`multisession.conf`**
  - `ISOLATE`: `auto` (default), `always` or `never`.
  - `BRIDGE_NAMES`: per-user D-Bus services to bridge. For example, add the
    gvfs names here if you want a single gvfs.
  - `AUTOSTART_SKIP`: per-user daemons that standalone sessions don't start
    a second time (file indexer, calendar alarms).
  - `DISPLAY_SCOPED_PROCESSES`: programs that run once per display.
- **`profiles/<session>.conf`**: how a session runs standalone. Each
  profile sets the gnome-session file whose components to start, the
  window-manager component (or `WM_EXEC`), components to skip, the
  session's XDG config directory, autostart on or off, and an optional
  `standalone_setup()` function.
  - A session without a profile runs its own `Exec` on a private bus. That
    suits sessions with no session manager.
  - `regolith-x11.conf` is included.
- **`hooks.d/*.sh`**: sourced right before any session starts, in both
  modes. Hooks get `MULTISESSION_SESSION`, `MULTISESSION_MODE`,
  `MULTISESSION_INSTANCE` and `MULTISESSION_RUNDIR`. For example, a hook can
  give later sessions a different look; see `hooks.d/README`.

## Limitations

- **The autopkgtests run without LightDM, logind or VTs.** They use Xvfb,
  real dbus-daemons and the real Regolith session components. Check on a
  real machine: `regolith-multisession new` from a console, VT switching,
  the polkit agent, the lock screen, and power keys with two sessions.
- **A primary session can still stop standalone compositors.** The primary
  session runs the stock i3 under systemd, without shims. The compositor's
  `init` (regolith-compositor-picom-glx 1.4.1) replaces every picom of the
  user (`pgrep -u`), so an i3 reload in the primary session also stops the
  standalone sessions' compositors; they lose compositing until their next
  reload. The fix there is to match picom by `DISPLAY` in `init`.
- **Logout has no confirmation dialog.** In a standalone session, logout ends
  the session immediately.
- **Keyring prompts can appear on the wrong display.** gnome-keyring starts
  its prompter on the user bus, so a keyring unlock prompt can show up on
  the primary session's display. At login, PAM normally unlocks the keyring
  anyway.
- **Some per-user services run twice.** gvfs and the volume monitors are not
  bridged by default, so each standalone session starts its own.
- **Crashed components are not restarted.** The window manager is the
  exception: when it exits, the session ends.
- **VT limit.** LightDM takes VTs from 7 up to the kernel's 63, so a seat can
  hold about 57 concurrent sessions.
- **X11 only.** Wayland sessions are not covered: LightDM is X11-centric, and
  sway would need a profile plus trawl handling.

## Follow-ups in other packages

The shims do from the outside what other Regolith packages could do
themselves:
- regolith-wm-config: a `REGOLITH_SESSION_MODE=standalone` contract that
  skips the `systemctl --user` calls in the i3 and sway configs. With it,
  the `systemctl` shim becomes unnecessary.
- regolith-compositor-picom-glx: match picom by `DISPLAY` in `init`, so a
  primary session no longer restarts other sessions' compositors.
- gnome-session (GNOME): export the session environment only after the
  `graphical-session.target` check, so a refused login no longer rewrites
  the running session's `DISPLAY`.

## Tests

The autopkgtests `multisession` (decision table, Xsession hook, planner,
shims, two standalone i3 sessions with bridged dconf, logout, teardown) and
`multisession-regolith` (two real standalone Regolith X11 sessions side by
side) cover this package.
