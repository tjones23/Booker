#!/bin/bash
#
# Shared by run-dev.command and run-prod.command — sourced, never run directly.
#
# Everything both launchers need lives here: finding and stopping the web
# server, sleep holds, tailscale, and following a log. Each .command file adds
# only its own commands and menu on top.
#
# Adapted from Outside's and WhatsGood's launchers. Booker gets the same
# shape — its own Tailscale node, the shared closed-lid sleep hold in
# scripts/lid-hold.sh — with dotnet in place of next: `dotnet watch` for dev,
# and for production a `dotnet publish` output run with `dotnet Booker.dll`.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="booker"
# Not 5000: on Monterey and later, AirPlay Receiver already listens there.
PORT="${BOOKER_PORT:-5080}"
# Booker's own node serves nothing else, so it gets plain 443 — no port in
# the URL. Override if that's ever not free on this node.
TS_HTTPS_PORT="${BOOKER_TS_PORT:-443}"
LOG_FILE="$REPO_DIR/server.log"
BUILD_LOG_FILE="$REPO_DIR/build.log"
PID_FILE="$REPO_DIR/server.pid"
MODE_FILE="$REPO_DIR/mode"
STATE_DIR="$REPO_DIR/.booker"
# The production build, what `rebuild` publishes into first, and the one
# before it, kept so a build that won't start can be put back.
PUBLISH_DIR="$STATE_DIR/publish"
STAGING_DIR="$STATE_DIR/publish-next"
PREVIOUS_DIR="$STATE_DIR/publish-previous"
# Production data lives outside the repo, so neither a rebuild nor a fresh
# clone can touch it. Dev keeps using ./booker.db.
DATA_DIR="${BOOKER_DATA_DIR:-$HOME/booker-data}"
# Production settings and secrets (admin password, SMTP) — see .env.example.
ENV_FILE="$REPO_DIR/.env"

# How the launcher was invoked, so hints name the file actually being run.
SELF="./$(basename "$0")"

# Color only when attached to a terminal, so redirected output stays clean.
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; }

# ---------------------------------------------------------------------------
# Modes
#
# The mode file records how the web server was started, so a restart brings it
# back the same way:
#
#   dev   dotnet watch, Development environment, ./booker.db
#   prod  the published build bound to 127.0.0.1 — this Mac only
#   lan   the published build bound to 0.0.0.0 — this Mac and this network
#
# Tailnet hosting is deliberately not a mode. `tailscale serve` proxies from
# localhost, so it works in front of either production mode, and its own
# persistent config is the record of whether it's on — which is what lets it be
# switched on and off without touching the server.
# ---------------------------------------------------------------------------

current_mode() {
  local mode=""
  [ -f "$MODE_FILE" ] && mode="$(cat "$MODE_FILE" 2>/dev/null)"
  printf '%s' "$mode"
}

mode_label() {
  case "${1:-}" in
    dev)  printf 'dev' ;;
    prod) printf 'production, this Mac only' ;;
    lan)  printf 'production, this network' ;;
    *)    printf 'not started by these scripts' ;;
  esac
}

# ---------------------------------------------------------------------------
# Process discovery
#
# The port is the source of truth, not the PID file: a PID file goes stale if
# the machine restarts, and the thing we actually care about is "is something
# serving on this port". Asking lsof answers that directly and lets `stop`
# work even on a server these scripts didn't start.
#
# The one exception is dev. The port belongs to the app that `dotnet watch`
# runs, and watch starts a new one the moment that one dies — so stopping dev
# means stopping watch itself, which only the PID file knows.
# ---------------------------------------------------------------------------

listeners() {
  lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null
}

is_running() {
  [ -n "$(listeners)" ]
}

# The process actually holding the port — what a sleep hold should follow.
server_pid() {
  listeners | head -1
}

# Start a long-lived process detached from this terminal, appending its output
# to a log. Its pid lands in DETACHED_PID.
#
# A process in a session of its own has no terminal to lose: when the Terminal
# window closes or an SSH session drops, the terminal's process group is hung
# up, and nohup alone doesn't protect a runtime that resets its signal
# handlers at startup.
detach() {
  local log="$1"
  shift
  if [ -x /usr/bin/perl ]; then
    /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' \
      "$@" >>"$log" 2>&1 </dev/null &
  else
    nohup "$@" >>"$log" 2>&1 </dev/null &
  fi
  DETACHED_PID=$!
}

# Kill a process and everything it spawned, children first.
kill_tree() {
  local pid="$1" signal="${2:-TERM}" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child" "$signal"
  done
  kill "-$signal" "$pid" 2>/dev/null || true
}

lan_ip() {
  local iface
  iface="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
  { [ -n "$iface" ] && ipconfig getifaddr "$iface" 2>/dev/null; } ||
    ipconfig getifaddr en0 2>/dev/null ||
    ipconfig getifaddr en1 2>/dev/null ||
    true
}

# ---------------------------------------------------------------------------
# Sleep
#
# Anything that hosts has to stay reachable, and a sleeping Mac answers
# nothing.
#
# There are two layers, because the first one alone can't survive a closed lid.
#
# caffeinate. `-w` ties the assertion to the process that needs it: caffeinate
# exits by itself when that process stops, so nothing has to remember to
# release it. `-i` blocks idle sleep but still allows the display to sleep.
# That covers a Mac with its lid open — but Apple's own IOPMLib.h says of this
# assertion that "the system may still sleep for lid close", and no assertion
# an ordinary process can take says otherwise.
#
# SleepDisabled. So a laptop run lid-closed as a server sleeps the moment
# nothing else is keeping it up — a Screen Sharing session counts as a display
# while it lasts, which is why a server started over Screen Sharing keeps going
# until the session ends and then drops within a minute ("Clamshell Sleep" in
# `pmset -g log`). `pmset -a disablesleep 1` is the one switch that covers the
# lid too. It is system-wide and needs root, so:
#
#   - `setup` installs a sudoers rule allowing exactly `pmset -a disablesleep 0`
#     and `... 1` without a password — nothing else — so the scripts, and the
#     watcher below, can flip it unattended.
#   - it is turned on only while something is hosted (this network or the
#     tailnet), and off again as soon as nothing is — by this app, Outside or
#     WhatsGood, which share the switch; see scripts/lid-hold.sh;
#   - a background watcher releases this app's hold if hosting ends some
#     other way, such as a crash, and only a SleepDisabled the scripts set
#     themselves is ever undone.
#
# Non-zero from keep_awake means nothing is holding sleep off, so callers can
# say so rather than promise a hold that isn't there.
# ---------------------------------------------------------------------------

keep_awake() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  command -v caffeinate >/dev/null 2>&1 || return 1
  detach /dev/null caffeinate -i -w "$pid"
  return 0
}

# Is a hold currently tied to this pid? Anchored, so pid 123 doesn't match the
# caffeinate that is waiting on 1234.
awake_for() {
  [ -n "${1:-}" ] || return 1
  pgrep -f "caffeinate -i -w $1\$" >/dev/null 2>&1
}

release_awake() {
  [ -n "${1:-}" ] || return 0
  pkill -f "caffeinate -i -w $1\$" >/dev/null 2>&1 || true
}

# Hold sleep off while the web server is hosted anywhere beyond this Mac, and
# only then. Called after anything that changes either half.
sync_awake() {
  local pid
  pid="$(server_pid)"
  [ -n "$pid" ] || return 0

  if [ "$(current_mode)" = "lan" ] || [ -n "$(ts_serve_url)" ]; then
    awake_for "$pid" && return 0
    if ! keep_awake "$pid"; then
      warn "caffeinate isn't available — this Mac may sleep while hosting."
      return 1
    fi
  else
    release_awake "$pid"
  fi
  return 0
}

BUSY_FILE="$STATE_DIR/busy"
SUDOERS_FILE="/etc/sudoers.d/booker-pmset"
PMSET="/usr/bin/pmset"

# Is anything hosted beyond this Mac right now?
hosting_active() {
  [ -n "$(ts_serve_url)" ] && return 0
  is_running && [ "$(current_mode)" = "lan" ]
}

# A command is part-way through — a restart, a rebuild. The server is down for
# a moment on purpose, and the hold must outlast that: a rebuild started over
# SSH with the lid closed would otherwise put the Mac to sleep mid-build.
is_busy() {
  local pid
  pid="$(cat "$BUSY_FILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

busy_begin() {
  mkdir -p "${BUSY_FILE%/*}" && printf '%s' "$$" > "$BUSY_FILE"
}

busy_end() {
  [ "$(cat "$BUSY_FILE" 2>/dev/null)" = "$$" ] && rm -f "$BUSY_FILE"
  return 0
}

# Run one state-changing command, then bring the lid hold in line with
# whatever it left behind. Every command the menus and CLIs offer goes through
# here, so no single command has to remember to.
run_op() {
  local rc
  busy_begin
  "$@"
  rc=$?
  busy_end
  sync_lid_hold
  return "$rc"
}

sync_lid_hold() {
  if hosting_active; then
    lid_hold_on
  else
    lid_hold_off
  fi
}

# shellcheck source=scripts/lid-hold.sh
source "$REPO_DIR/scripts/lid-hold.sh" || return 1

# Install (or, with --remove, uninstall) the sudoers rule described above.
sleep_setup() {
  if [ "${1:-}" = "--remove" ]; then
    # The rule is shared with Outside and WhatsGood: pulling it while another
    # app holds sleep off would leave that app unable to turn it back on.
    local others
    others="$(lh_others)"
    if [ -n "$others" ] && [ "${2:-}" != "--force" ]; then
      err "Still in use — hosting: $others. Stop that first (or: $SELF setup --remove --force)."
      return 1
    fi
    lid_hold_off
    if [ ! -f "$SUDOERS_FILE" ]; then
      if sudo -n -l "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
        say "Booker didn't install the rule in use — another app's file in /etc/sudoers.d/ did (e.g. outside-pmset)."
      else
        say "Not set up — nothing to remove."
      fi
      return 0
    fi
    sudo rm -f "$SUDOERS_FILE" || { err "Couldn't remove $SUDOERS_FILE."; return 1; }
    ok "Removed $SUDOERS_FILE. Closing the lid will sleep this Mac again, even while hosting."
    return 0
  fi

  # Checked by command, not by file: Outside's and WhatsGood's rules grant
  # exactly the same thing and serve every app.
  if sudo -n -l "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
    ok "Already set up — these scripts can keep this Mac awake with the lid closed."
    return 0
  fi

  local user tmp
  user="$(id -un)"
  tmp="$(mktemp -t booker-sudoers)" || return 1
  cat > "$tmp" <<EOF
# Installed by Booker's run-dev.command / run-prod.command ('setup').
# Lets them keep this Mac awake with the lid closed while it hosts, and turn
# that off again. Remove with: $SELF setup --remove
$user ALL=(root) NOPASSWD: $PMSET -a disablesleep 0, $PMSET -a disablesleep 1
EOF

  say "Installing $SUDOERS_FILE ${DIM}(allows only '$PMSET -a disablesleep 0|1')${RESET}"
  # Checked with visudo before it goes in: a malformed file in sudoers.d can
  # lock sudo out entirely. And only if /etc/sudoers reads sudoers.d at all.
  if ! sudo /bin/sh -c '
      grep -qE "^[#@]includedir[[:space:]]+(/private)?/etc/sudoers.d" /etc/sudoers || { echo "/etc/sudoers does not include /etc/sudoers.d" >&2; exit 1; }
      /usr/sbin/visudo -cqf "$1" || exit 1
      /usr/bin/install -m 0440 -o root -g wheel "$1" "$2"
    ' sh "$tmp" "$SUDOERS_FILE"; then
    rm -f "$tmp"
    err "Setup failed — nothing was changed."
    return 1
  fi
  rm -f "$tmp"
  ok "Set up. From now on, hosting keeps this Mac awake with the lid closed."
}

# ---------------------------------------------------------------------------
# Tailscale
#
# Booker gets its own Tailscale node — a second, userspace `tailscaled` that
# only this app's launcher runs, logged in under its own name (TS_NODE_NAME).
# That's what gives it a clean address with no port
# (https://rootedreaders.<tailnet>.ts.net) instead of sharing the machine's
# own node and a second HTTPS port. It costs nothing: Tailscale's free plan
# doesn't limit user-owned devices, and this one is a normal (non-ephemeral)
# node like any other.
#
# Every Tailscale call below goes through the `ts` wrapper, which always
# names this node's own --socket. Nothing here ever touches the machine's
# own Tailscale — including the bare `tailscale` CLI, which would otherwise
# silently talk to whichever daemon it finds first.
#
# Hosting on the tailnet is `tailscale serve`, proxying HTTPS on
# $TS_HTTPS_PORT to localhost; `public` adds Funnel, which opens that same
# address to the internet. Tailscale holds the certificate and terminates
# HTTPS, and passes X-Forwarded-Proto through so the app knows the request
# was secure (Program.cs).
#
# Nothing here ever runs `ts down`. On a server administered over the
# tailnet, that would cut off SSH along with the app — so "stop hosting"
# withdraws the proxy (and, on a full stop, the node's own daemon) rather
# than logging the node out.
# ---------------------------------------------------------------------------

TS_BIN="$(command -v tailscale 2>/dev/null || true)"
if [ -z "$TS_BIN" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

# The standalone daemon binary for Booker's own node. Neither the App Store
# nor the standalone Tailscale.app ships one of these to run by hand — it has
# to come from `brew install tailscale` (the binary only; never `brew
# services start` it, which would run it as the *system* daemon), or from
# `go install tailscale.com/cmd/tailscaled@latest` where Homebrew can't.
TSD_BIN="$(command -v tailscaled 2>/dev/null || true)"
if [ -z "$TSD_BIN" ]; then
  for _ts_candidate in /opt/homebrew/opt/tailscale/bin/tailscaled /usr/local/opt/tailscale/bin/tailscaled "$HOME/go/bin/tailscaled"; do
    [ -x "$_ts_candidate" ] && TSD_BIN="$_ts_candidate" && break
  done
  unset _ts_candidate
fi

TS_NODE_NAME="${BOOKER_TS_HOSTNAME:-rootedreaders}"
TS_STATE_DIR="$STATE_DIR/tailscale"
TS_SOCKET="$TS_STATE_DIR/tailscaled.sock"
TS_DAEMON_LOG="$TS_STATE_DIR/tailscaled.log"
TS_DAEMON_PID_FILE="$TS_STATE_DIR/tailscaled.pid"

have_tailscale()  { [ -n "$TS_BIN" ]; }
have_tailscaled() { [ -n "$TSD_BIN" ]; }

# Every Tailscale CLI call for Booker's own node goes through here.
ts() { "$TS_BIN" --socket="$TS_SOCKET" "$@"; }

# Is Booker's own tailscaled answering on its socket? Checked for the socket
# file first: asked about one that isn't there, the CLI spends five seconds
# retrying, and nearly every command asks this more than once.
ts_daemon_running() {
  have_tailscale && have_tailscaled && [ -S "$TS_SOCKET" ] || return 1
  ts status --json --peers=false >/dev/null 2>&1
}

# Start Booker's own tailscaled, in userspace mode so it needs no root and
# can't fight the machine's own Tailscale over the network interface.
ts_daemon_start() {
  ts_daemon_running && return 0
  have_tailscaled || return 1
  mkdir -p "$TS_STATE_DIR" || return 1
  : > "$TS_DAEMON_LOG"
  detach "$TS_DAEMON_LOG" "$TSD_BIN" --tun=userspace-networking \
    --statedir="$TS_STATE_DIR" --socket="$TS_SOCKET" --port=0
  printf '%s' "$DETACHED_PID" > "$TS_DAEMON_PID_FILE"

  local waited=0
  while [ "$waited" -lt 15 ]; do
    ts_daemon_running && return 0
    if ! kill -0 "$DETACHED_PID" 2>/dev/null; then
      err "Booker's tailscaled didn't start. Last 20 lines of $TS_DAEMON_LOG:"
      tail -20 "$TS_DAEMON_LOG"
      rm -f "$TS_DAEMON_PID_FILE"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  err "Booker's tailscaled didn't answer on its socket within 15s."
  return 1
}

# Stop Booker's own tailscaled. The node stays logged in — it just goes
# offline until next started, the same as any machine that's turned off.
ts_daemon_stop() {
  if ts_daemon_running; then
    local pid
    pid="$(cat "$TS_DAEMON_PID_FILE" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill_tree "$pid" TERM
    else
      pkill -f "tailscaled .*--socket=$TS_SOCKET" 2>/dev/null || true
    fi
    local waited=0
    while [ "$waited" -lt 10 ] && ts_daemon_running; do
      sleep 1
      waited=$((waited + 1))
    done
  fi
  rm -f "$TS_DAEMON_PID_FILE" "$TS_SOCKET"
  return 0
}

# Running | Stopped | NeedsLogin | NoState, or empty when the daemon isn't
# running at all (the normal state while Booker isn't hosted anywhere).
ts_state() {
  ts_daemon_running || return 0
  ts status --json --peers=false 2>/dev/null |
    sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# This node's tailnet name, trailing dot stripped. `--peers=false` is what
# makes the match unambiguous — every peer carries a DNSName too.
ts_hostname() {
  ts_daemon_running || return 0
  ts status --json --peers=false 2>/dev/null |
    sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | sed 's/\.$//'
}

# The URL serve is publishing for this app's port, if any. Port 443 prints
# as a bare host; any other port as host:port.
ts_serve_url() {
  ts_daemon_running || return 0
  local port_re=""
  [ "$TS_HTTPS_PORT" = 443 ] || port_re=":$TS_HTTPS_PORT"
  ts serve status 2>/dev/null |
    grep -Eo "^https://[^ :/]+${port_re}( |/|\$)" | head -1 | sed 's|[ /]*$||'
}

# Bring Booker's own node onto the tailnet, starting its daemon first if
# needed. Non-zero means it needs a human.
ts_connect() {
  ts_daemon_start || return 1

  case "$(ts_state)" in
    Running) ts_check_node_name; return 0 ;;
    NeedsLogin|NoState)
      # First login needs a human to open the URL this prints — there's no
      # way around that, so only attempt it with a terminal attached, and in
      # the foreground (no backgrounding, no --timeout) so the URL is seen.
      if [ ! -t 0 ]; then
        err "\"$TS_NODE_NAME\" has never logged in to the tailnet."
        say "  ${DIM}Run '$SELF tailnet' from a terminal, open the URL it prints, then try again.${RESET}"
        return 1
      fi
      say "${DIM}First run — signing \"$TS_NODE_NAME\" in to the tailnet…${RESET}"
      ts up --hostname="$TS_NODE_NAME" || return 1
      ;;
    *)
      # Stopped, or the daemon just started and hasn't settled. This node's
      # prefs are ours alone (we always pass --hostname), so bare `up` is
      # safe — bounded from the outside so a wedged daemon can't hang this.
      say "${DIM}Connecting \"$TS_NODE_NAME\" to the tailnet…${RESET}"
      ts up --hostname="$TS_NODE_NAME" >/dev/null 2>&1 &
      local up_pid=$! waited=0
      while [ "$waited" -lt 30 ] && kill -0 "$up_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if kill -0 "$up_pid" 2>/dev/null; then
        kill_tree "$up_pid" KILL
        warn "\"$TS_NODE_NAME\" didn't come up within 30s."
        return 1
      fi
      wait "$up_pid" 2>/dev/null
      ;;
  esac

  # The daemon flips to Running a beat before the node is actually online, so
  # give it a moment rather than deciding on the first read.
  waited=0
  while [ "$waited" -lt 15 ]; do
    if [ "$(ts_state)" = "Running" ]; then
      ts_check_node_name
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  warn "Couldn't bring \"$TS_NODE_NAME\" up."
  say "  ${DIM}Try '$SELF tailnet' again, or run 'tailscale --socket=$TS_SOCKET up --hostname=$TS_NODE_NAME' yourself.${RESET}"
  return 1
}

# Tailscale hands out "$TS_NODE_NAME-1" etc. if the name was already taken by
# another node on this tailnet. Said once per connect, not an error — the
# app still works, just at a different address than expected.
ts_check_node_name() {
  local host="${1:-$(ts_hostname)}"
  case "$host" in
    "$TS_NODE_NAME".*) ;;
    *) [ -n "$host" ] && warn "\"$TS_NODE_NAME\" was already taken on this tailnet — this node is \"${host%%.*}\" instead (https://$host). Remove the old node in the admin console to free the name, if you want it." ;;
  esac
}

# Is this app's port open to the public internet, not just the tailnet?
ts_public() {
  ts_daemon_running || return 1
  local host
  host="$(ts_hostname)"
  [ -n "$host" ] || return 1
  ts serve status --json 2>/dev/null |
    grep -q "\"$host:$TS_HTTPS_PORT\"[[:space:]]*:[[:space:]]*true"
}

# Turn off public ingress for this app's port, leaving the private tailnet
# listener (if any) alone. `serve`/`funnel off` on some Tailscale versions
# also drops the plain tailnet listener; callers that want to stay on the
# tailnet put it back afterward (see run-prod.command's `public_off`).
ts_unfunnel() {
  ts_public || return 0
  ts funnel --https="$TS_HTTPS_PORT" off >/dev/null 2>&1
  if ts_public; then
    err "Couldn't withdraw from the internet — check 'tailscale --socket=$TS_SOCKET funnel status'."
    return 1
  fi
  return 0
}

# Withdraw the app from the tailnet. Only this app's HTTPS listener is turned
# off — this node serves nothing else, but `serve reset` would also forget
# that, so it's still avoided. Funnel is cleared first, so this never leaves
# the port public with nothing to show for it on the tailnet.
ts_unserve() {
  [ -n "$(ts_serve_url)" ] || return 0

  ts_unfunnel
  ts serve --https="$TS_HTTPS_PORT" off >/dev/null 2>&1

  if [ -n "$(ts_serve_url)" ]; then
    err "Couldn't withdraw from the tailnet — check 'tailscale --socket=$TS_SOCKET serve status'."
    return 1
  fi
  ok "No longer hosted on the tailnet."
  say "  ${DIM}\"$TS_NODE_NAME\" is still logged in; only the app's listener was withdrawn.${RESET}"
  return 0
}

# Full withdrawal for a stop that means it: drop this app's listener and put
# its node's own daemon to sleep too. Skipped on a stop that's about to be
# followed by a start (`keep-serve`), so a restart or rebuild never drops
# the node, and Funnel/serve stay configured across it.
ts_withdraw() {
  ts_unserve
  ts_daemon_stop
}

# ---------------------------------------------------------------------------
# Preflight and settings
# ---------------------------------------------------------------------------

DOTNET_BIN="$(command -v dotnet 2>/dev/null || true)"
if [ -z "$DOTNET_BIN" ] && [ -x /usr/local/share/dotnet/dotnet ]; then
  DOTNET_BIN="/usr/local/share/dotnet/dotnet"
fi

preflight() {
  if [ -z "$DOTNET_BIN" ]; then
    err "dotnet isn't installed."
    say "  Install the .NET 8 SDK from https://dotnet.microsoft.com/download/dotnet/8.0 and try again."
    return 1
  fi

  if ! "$DOTNET_BIN" --list-runtimes 2>/dev/null | grep -q '^Microsoft\.AspNetCore\.App 8\.'; then
    err "The ASP.NET Core 8 runtime isn't installed — Booker targets net8.0."
    say "  Install the .NET 8 SDK from https://dotnet.microsoft.com/download/dotnet/8.0 and try again."
    return 1
  fi
  return 0
}

# Export production settings from .env into this shell, for the server it
# starts. Every line is KEY=value; the names map onto appsettings.json with
# __ for nesting (Admin__Password, Email__Host, ...).
load_env() {
  [ -f "$ENV_FILE" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

# Is the admin login still the demo one from appsettings.json? Answers for
# whatever .env sets, so call it after load_env.
admin_password_is_default() {
  [ -z "${Admin__Password:-}" ] || [ "$Admin__Password" = "ChangeMe123!" ]
}

# ---------------------------------------------------------------------------
# The web server
# ---------------------------------------------------------------------------

have_build() {
  [ -f "$PUBLISH_DIR/Booker.dll" ]
}

# Anything newer than the last build that the build would have picked up.
build_is_stale() {
  local stamp="$PUBLISH_DIR/Booker.dll"
  [ -f "$stamp" ] || return 1
  [ -n "$(find "$REPO_DIR/Controllers" "$REPO_DIR/Models" "$REPO_DIR/Services" \
            "$REPO_DIR/Data" "$REPO_DIR/Views" "$REPO_DIR/wwwroot" \
            "$REPO_DIR/Program.cs" "$REPO_DIR/appsettings.json" "$REPO_DIR/Booker.csproj" \
            -newer "$stamp" -print 2>/dev/null | head -1)" ]
}

wait_until_ready() {
  local pid="$1" attempts=0 max="${2:-90}"
  printf 'Starting'
  while [ "$attempts" -lt "$max" ]; do
    # 127.0.0.1 rather than localhost: a server bound to IPv4 doesn't answer
    # on ::1, which is where localhost resolves first.
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
      printf '\n'
      return 0
    fi
    # Surface a crash immediately instead of spinning for the full timeout.
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '\n'
      return 1
    fi
    printf '.'
    sleep 1
    attempts=$((attempts + 1))
  done
  printf '\n'
  return 1
}

# Start the web server in the background and wait for it to answer. Callers
# check that the port is free first, and decide what to say on success.
launch_server() {
  local mode="$1"

  if [ "$mode" != "dev" ] && ! have_build; then
    err "There's no production build yet — rebuild production first."
    return 1
  fi

  preflight || return 1

  if [ "$mode" != "dev" ]; then
    build_is_stale && warn "The code has changed since the last build — rebuild production to pick it up."
    load_env
    admin_password_is_default &&
      warn "The admin login is still the demo one — set Admin__Password in .env (see .env.example)."
    mkdir -p "$DATA_DIR" || return 1
  fi

  : > "$LOG_FILE"
  case "$mode" in
    dev)
      # Development reads appsettings.Development.json and user secrets, and
      # keeps ./booker.db. No launch profile: it would pick its own port.
      # Rude edits restart the app rather than waiting on a prompt nobody
      # can answer from a detached process.
      cd "$REPO_DIR" || return 1
      detach "$LOG_FILE" env \
        ASPNETCORE_ENVIRONMENT=Development \
        ASPNETCORE_URLS="http://127.0.0.1:$PORT" \
        DOTNET_WATCH_RESTART_ON_RUDE_EDIT=1 \
        DOTNET_WATCH_SUPPRESS_LAUNCH_BROWSER=1 \
        "$DOTNET_BIN" watch --project "$REPO_DIR/Booker.csproj" run --no-launch-profile ;;
    # The published build rather than `dotnet run`: no compiler, no file
    # watchers, far less memory and idle CPU. It matters for a machine that
    # stays awake. Run from the publish folder, which is its content root.
    prod|lan)
      local bind=127.0.0.1
      [ "$mode" = "lan" ] && bind=0.0.0.0
      cd "$PUBLISH_DIR" || return 1
      detach "$LOG_FILE" env \
        ASPNETCORE_ENVIRONMENT=Production \
        ASPNETCORE_URLS="http://$bind:$PORT" \
        ConnectionStrings__Default="Data Source=$DATA_DIR/booker.db" \
        "$DOTNET_BIN" "$PUBLISH_DIR/Booker.dll"
      cd "$REPO_DIR" || return 1 ;;
    *)
      err "Unknown mode '$mode'."
      return 1 ;;
  esac
  local pid="$DETACHED_PID"
  printf '%s' "$pid" > "$PID_FILE"
  printf '%s' "$mode" > "$MODE_FILE"

  # Dev compiles first, which on an older Mac can take a while.
  local timeout=90
  [ "$mode" = "dev" ] && timeout=240
  if wait_until_ready "$pid" "$timeout"; then
    return 0
  fi

  err "Server didn't come up. Last 20 lines of $LOG_FILE:"
  tail -20 "$LOG_FILE"
  kill_tree "$pid" TERM
  if ! is_running; then
    rm -f "$PID_FILE" "$MODE_FILE"
  fi
  return 1
}

# Where the server can be reached right now, one address per line.
print_urls() {
  say "  ${BOLD}${BLUE}http://localhost:$PORT${RESET}"

  if [ "$(current_mode)" = "lan" ]; then
    local ip
    ip="$(lan_ip)"
    [ -n "$ip" ] && say "  ${BOLD}${BLUE}http://$ip:$PORT${RESET}  ${DIM}(this network)${RESET}"
  fi

  local ts_url
  ts_url="$(ts_serve_url)"
  if [ -n "$ts_url" ]; then
    if ts_public; then
      say "  ${BOLD}${BLUE}${ts_url}${RESET}  ${DIM}(public, HTTPS)${RESET}"
    else
      say "  ${BOLD}${BLUE}${ts_url}${RESET}  ${DIM}(tailnet, HTTPS)${RESET}"
    fi
  fi

  awake_for "$(server_pid)" && say "  ${DIM}Sleep is held off while it's hosted.${RESET}"
  case "$(current_mode)" in
    prod|lan) say "  ${DIM}data: $DATA_DIR/booker.db${RESET}" ;;
  esac
  say "  ${DIM}logs: $LOG_FILE${RESET}"
}

# `keep-serve` is for a stop that is about to be followed by a start: the
# tailnet proxy can stay configured across a restart, and tearing it down
# would only make the restart visible to everyone connected.
stop_server() {
  local keep_serve="${1:-}"
  local pids pid started
  pids="$(listeners)"
  started="$(cat "$PID_FILE" 2>/dev/null)"

  if [ -z "$pids" ] && ! { [ -n "$started" ] && kill -0 "$started" 2>/dev/null; }; then
    say "Web server isn't running."
    rm -f "$PID_FILE" "$MODE_FILE"
    # Still withdraw: a serve config outlives the server it points at, and an
    # advertised URL with nothing behind it is exactly what this should clear.
    [ -z "$keep_serve" ] && ts_withdraw
    return 0
  fi

  # What these scripts started goes first — for dev that's `dotnet watch`,
  # which would otherwise start a fresh app the moment its old one died.
  started_alive() { [ -n "$started" ] && kill -0 "$started" 2>/dev/null; }
  started_alive && kill_tree "$started" TERM
  for pid in $pids; do
    kill_tree "$pid" TERM
  done

  # Give it a moment to shut down cleanly before forcing the issue. Dev gets
  # less: its app goes quickly, and watch itself never will (below).
  local waited=0 patience=10
  [ "$(current_mode)" = "dev" ] && patience=3
  while [ "$waited" -lt "$patience" ] && { is_running || started_alive; }; do
    sleep 1
    waited=$((waited + 1))
  done

  # Forcing is routine for dev: detached from a terminal, `dotnet watch`
  # ignores TERM and INT, and once its app has gone it just waits for a file
  # to change. Only production is worth a warning.
  if is_running || started_alive; then
    [ "$(current_mode)" = "dev" ] || warn "Didn't stop cleanly; forcing."
    started_alive && kill_tree "$started" KILL
    for pid in $(listeners); do
      kill_tree "$pid" KILL
    done
    sleep 1
  fi

  rm -f "$PID_FILE" "$MODE_FILE"

  if is_running; then
    err "Something is still holding port $PORT."
    return 1
  fi
  ok "Web server stopped."

  [ -z "$keep_serve" ] && ts_withdraw
  return 0
}

# Restart in whatever mode it was running in. When nothing is running, start
# in the caller's default mode.
restart_server() {
  local fallback="$1" mode

  if ! is_running; then
    say "Not running — starting it."
    mode="$fallback"
  else
    mode="$(current_mode)"
    [ -z "$mode" ] && mode="$fallback"
    stop_server keep-serve || return 1
  fi

  launch_server "$mode" || return 1
  sync_awake
  ok "Running ($(mode_label "$mode"))."
  print_urls
}

# ---------------------------------------------------------------------------
# Logs
#
# `tail -f` alone can only be left with Ctrl-C, and Ctrl-C goes to the whole
# foreground process group — this script included. From a Finder double-click
# that kills the menu and leaves a dead Terminal window. So tail runs in the
# background (where it ignores Ctrl-C), a keypress or Ctrl-C stops it, and the
# caller carries on.
#
# Without a terminal — piped, or run by a tool — it prints the tail and
# returns, so it can never block anything.
# ---------------------------------------------------------------------------

follow_log() {
  local file="$1"
  if [ ! -f "$file" ]; then
    say "No log yet at $file."
    return 0
  fi

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    tail -n 50 "$file"
    return 0
  fi

  say "${DIM}Following $file — press any key to stop (the server keeps running).${RESET}"
  tail -n 40 -f "$file" &
  local tail_pid=$!

  local previous_trap
  previous_trap="$(trap -p INT)"
  trap 'kill "$tail_pid" 2>/dev/null' INT

  local key
  while kill -0 "$tail_pid" 2>/dev/null; do
    # One-second slices, so a Ctrl-C (which ends tail via the trap) is noticed.
    IFS= read -rsn1 -t 1 key && break
  done

  kill "$tail_pid" 2>/dev/null
  wait "$tail_pid" 2>/dev/null
  if [ -n "$previous_trap" ]; then
    eval "$previous_trap"
  else
    trap - INT
  fi
  say ""
  say "${DIM}Stopped following.${RESET}"
  return 0
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

status() {
  local mode
  mode="$(current_mode)"
  if is_running; then
    ok "Web server running ($(mode_label "$mode")) on port $PORT — pid $(listeners | tr '\n' ' ')"
    print_urls
  else
    say "Web server not running."
    local ts_url
    ts_url="$(ts_serve_url)"
    [ -n "$ts_url" ] && warn "The tailnet still advertises $ts_url, with nothing behind it — stop the web server to withdraw it."
  fi

  if have_tailscaled; then
    case "$(ts_state)" in
      Running)
        [ -n "$(ts_serve_url)" ] || say "  ${DIM}\"$TS_NODE_NAME\": connected, app not hosted there${RESET}" ;;
      Stopped)    say "  ${DIM}\"$TS_NODE_NAME\": logged in, daemon running, not connected${RESET}" ;;
      NeedsLogin) say "  ${DIM}\"$TS_NODE_NAME\": needs login — run '$SELF tailnet' from a terminal${RESET}" ;;
      "")         say "  ${DIM}\"$TS_NODE_NAME\": daemon not running${RESET}" ;;
      *)          say "  ${DIM}\"$TS_NODE_NAME\": $(ts_state)${RESET}" ;;
    esac
  elif have_tailscale; then
    say "  ${DIM}tailscaled isn't installed — Booker's own node can't run (brew install tailscale).${RESET}"
  fi

  sleep_summary
  if lh_own_hold && ! hosting_active; then
    warn "Sleep is still disabled from earlier, with nothing hosted — opening the menu, or any start or stop, re-enables it."
  fi
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

menu_header() {
  printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"

  if is_running; then
    printf '  %s● running%s %s(%s)%s  http://localhost:%s\n' \
      "$GREEN" "$RESET" "$DIM" "$(mode_label "$(current_mode)")" "$RESET" "$PORT"
    if [ "$(current_mode)" = "lan" ]; then
      printf '    this network  http://%s:%s\n' "$(lan_ip)" "$PORT"
    fi
  else
    printf '  %s○ stopped%s\n' "$DIM" "$RESET"
  fi

  local ts_url
  ts_url="$(ts_serve_url)"
  if [ -n "$ts_url" ]; then
    if ts_public; then
      printf '    public        %s\n' "$ts_url"
    else
      printf '    tailnet       %s\n' "$ts_url"
    fi
  fi

  sleep_summary
  printf '\n'
}

# Read one menu choice into MENU_CHOICE. Non-zero means the terminal went away
# (end of input), and the menu should end.
#
# Ctrl-C is caught while a menu is up, so a stray one — at the prompt, or to
# abandon something slow — lands back here instead of killing the window.
read_choice() {
  local rc
  MENU_CHOICE=""
  printf '\nChoose: '
  read -r MENU_CHOICE
  rc=$?
  # 1 is end of input; anything above 128 is a signal, which just re-prompts.
  [ "$rc" -eq 1 ] && { say ""; return 1; }
  return 0
}

menu_trap() {
  trap 'printf "\n%s(Ctrl-C — choose q to quit)%s\n" "$DIM" "$RESET"' INT
}
