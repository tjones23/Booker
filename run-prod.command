#!/bin/bash
#
# Booker — production launcher
#
# For the machine that serves the site. Double-click this file in Finder for
# a menu, or run it from a terminal:
#
#   ./run-prod.command start       # serve the last build, to this Mac only
#   ./run-prod.command stop        # stop serving (and stop hosting it anywhere)
#   ./run-prod.command restart     # same build, same hosting
#   ./run-prod.command rebuild     # new production build; restarts if running
#
#   ./run-prod.command lan         # host on this network (+ keep awake)
#   ./run-prod.command lan off
#   ./run-prod.command tailnet     # host on Booker's own Tailscale node, "rootedreaders", over HTTPS (+ keep awake)
#   ./run-prod.command tailnet off
#   ./run-prod.command public      # ...and to the internet, via Tailscale Funnel (+ keep awake)
#   ./run-prod.command public off  # back to tailnet-only
#
#   ./run-prod.command status
#   ./run-prod.command logs        # follow the log; any key stops following
#
#   ./run-prod.command setup       # once: let hosting keep a closed-lid Mac awake
#   ./run-prod.command setup --remove
#
# First time on a new server: copy .env.example to .env and fill it in, then
# `setup`, `rebuild`, `public`. The site is then at
# https://rootedreaders.<tailnet>.ts.net.
#
# Starting never builds, and building never starts: `rebuild` is how new code
# gets in. Hosting on this network and on the tailnet are independent — either,
# both, or neither — and neither ever opens a browser.
#
# This network is plain HTTP, the tailnet is HTTPS. The admin login works on
# either, but only the tailnet address keeps its cookie off the wire.
#
# `public` is the same tailnet address, opened to the internet with Tailscale
# Funnel: anyone with the link can reach it, not just your tailnet. It won't
# go public while the admin login is still the demo one.
#
# Production reads its settings and secrets from .env and keeps its database
# in ~/booker-data (BOOKER_DATA_DIR), outside the repo.

set -uo pipefail

# shellcheck source=scripts/run-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/run-common.sh" || exit 1

port_is_production() {
  is_running || return 0
  case "$(current_mode)" in
    prod|lan) return 0 ;;
  esac
  err "Port $PORT is already in use ($(mode_label "$(current_mode)")) — stop that server first."
  return 1
}

prod_start() {
  local mode="${1:-prod}"

  port_is_production || return 1
  if is_running; then
    warn "Production is already running ($(mode_label "$(current_mode)"))."
    print_urls
    return 0
  fi

  launch_server "$mode" || return 1
  sync_awake
  ok "Production running ($(mode_label "$mode"))."
  print_urls
}

prod_stop() {
  stop_server
}

# ---------------------------------------------------------------------------
# Rebuild
#
# `dotnet publish` goes into a staging folder while the current build keeps
# serving, so a build that fails costs nothing at all. Only once it has
# succeeded is production stopped, the new build swapped in, and production
# started again — a few seconds' gap. If the new build then won't start, the
# previous one is put back and served again.
# ---------------------------------------------------------------------------

publish_build() {
  rm -rf "$STAGING_DIR"
  mkdir -p "$STATE_DIR" || return 1
  "$DOTNET_BIN" publish "$REPO_DIR/Booker.csproj" -c Release -o "$STAGING_DIR" \
    --nologo /p:UseAppHost=false >>"$BUILD_LOG_FILE" 2>&1 &&
    [ -f "$STAGING_DIR/Booker.dll" ]
}

# The staged build becomes the live one; the live one is kept as previous.
swap_in_build() {
  rm -rf "$PREVIOUS_DIR"
  if [ -d "$PUBLISH_DIR" ]; then
    mv "$PUBLISH_DIR" "$PREVIOUS_DIR" || return 1
  fi
  mv "$STAGING_DIR" "$PUBLISH_DIR"
}

restore_build() {
  [ -f "$PREVIOUS_DIR/Booker.dll" ] || return 1
  rm -rf "$PUBLISH_DIR"
  mv "$PREVIOUS_DIR" "$PUBLISH_DIR"
}

prod_rebuild() {
  preflight || return 1

  # The mode to come back in, if production was running.
  local was=""
  if is_running; then
    case "$(current_mode)" in
      prod|lan) was="$(current_mode)" ;;
      # Dev builds Debug into bin/, so publishing Release beside it is safe
      # and the dev server can keep running — production just can't start after.
      dev) ;;
      *)
        err "A server these scripts didn't start is on port $PORT — stop it before rebuilding."
        return 1 ;;
    esac
  fi

  cd "$REPO_DIR" || return 1
  : > "$BUILD_LOG_FILE"

  say "${BOLD}Building for production…${RESET} ${DIM}(this takes a moment)${RESET}"
  if ! publish_build; then
    rm -rf "$STAGING_DIR"
    err "Build failed. Last 20 lines of $BUILD_LOG_FILE:"
    tail -20 "$BUILD_LOG_FILE"
    [ -n "$was" ] && say "  ${DIM}Production is still running the previous build.${RESET}"
    return 1
  fi
  ok "Build complete."

  if [ -n "$was" ]; then
    say "${DIM}Restarting production on the new build…${RESET}"
    stop_server keep-serve || return 1
  fi

  if ! swap_in_build; then
    err "Couldn't put the new build in place — see $STATE_DIR."
    return 1
  fi

  if [ -z "$was" ]; then
    if is_running; then
      say "  ${DIM}The dev server still has port $PORT; stop it before starting production.${RESET}"
    else
      say "  ${DIM}Not started — start production to serve it.${RESET}"
    fi
    return 0
  fi

  if launch_server "$was"; then
    sync_awake
    ok "Production running the new build ($(mode_label "$was"))."
    print_urls
    return 0
  fi

  rebuild_failed "$was"
  return 1
}

# The new build wouldn't start: put the previous one back and serve that.
rebuild_failed() {
  local was="$1"

  if ! restore_build; then
    warn "There was no earlier build to go back to — production stays stopped."
    return 0
  fi
  ok "Put the previous build back."

  if launch_server "$was"; then
    sync_awake
    ok "Production is back up on the previous build ($(mode_label "$was"))."
    print_urls
  fi
}

# ---------------------------------------------------------------------------
# Hosting
#
# "This network" is how the server binds: 127.0.0.1 keeps it on this Mac,
# 0.0.0.0 opens it to the LAN, and switching between them is a quick restart.
# "Tailnet" is a tailscale serve proxy from localhost, switched on and off
# without touching the server at all.
# ---------------------------------------------------------------------------

lan_on() {
  port_is_production || return 1

  if is_running; then
    if [ "$(current_mode)" = "lan" ]; then
      ok "Already hosted on this network."
      print_urls
      return 0
    fi
    say "${DIM}Restarting production so this network can reach it…${RESET}"
    stop_server keep-serve || return 1
  fi

  launch_server lan || return 1
  sync_awake
  ok "Hosted on this network."
  print_urls

  say "  ${DIM}This address is plain HTTP: fine for browsing, but sign in to the admin pages over the tailnet address.${RESET}"
}

lan_off() {
  if ! is_running || [ "$(current_mode)" != "lan" ]; then
    say "Not hosted on this network."
    return 0
  fi

  say "${DIM}Restarting production for this Mac only…${RESET}"
  stop_server keep-serve || return 1
  launch_server prod || return 1
  sync_awake
  ok "No longer hosted on this network."
  print_urls
}

# Non-zero, with the reason already said, when Booker's own node can't be
# used at all — checked before anything else in both tailnet_on and public_on.
require_tailscale() {
  if ! have_tailscale; then
    err "Tailscale isn't installed."
    say "  ${DIM}brew install tailscale, or get the app from tailscale.com${RESET}"
    return 1
  fi
  if ! have_tailscaled; then
    err "tailscaled isn't installed — Booker needs its own copy to run its own node."
    say "  ${DIM}brew install tailscale (the App Store app and tailscale.com installer don't include tailscaled),${RESET}"
    say "  ${DIM}or, where Homebrew can't: go install tailscale.com/cmd/tailscale{,d}@latest${RESET}"
    return 1
  fi
  return 0
}

tailnet_on() {
  require_tailscale || return 1
  port_is_production || return 1

  # Before starting anything: a node that needs a human to log in is worth
  # hearing about while nothing has changed yet.
  ts_connect || return 1

  if ! is_running; then
    launch_server prod || return 1
  fi

  # Pointed at the server only once it answers, so the tailnet URL is never
  # advertising a port that isn't listening yet.
  if [ -z "$(ts_serve_url)" ] && ! ts serve --bg --https="$TS_HTTPS_PORT" "$PORT" >/dev/null 2>&1; then
    err "tailscale serve failed — production is running, but not on the tailnet."
    say "  ${DIM}Run 'tailscale --socket=$TS_SOCKET serve --bg --https=$TS_HTTPS_PORT $PORT' yourself to see why.${RESET}"
    return 1
  fi

  sync_awake
  ok "Hosted on the tailnet."
  print_urls
}

tailnet_off() {
  if [ -z "$(ts_serve_url)" ]; then
    say "Not hosted on the tailnet."
    return 0
  fi
  ts_unserve || return 1
  ts_daemon_stop
  sync_awake
}

# Funnel is `serve` with public ingress switched on: same proxy, same
# address, just reachable from the internet rather than only the tailnet.
public_on() {
  require_tailscale || return 1
  port_is_production || return 1

  # The admin pages are the one thing on the site worth guarding, and the
  # demo password is in this repo for anyone to read.
  load_env
  if admin_password_is_default; then
    err "The admin login is still the demo one — set Admin__Password in .env before going public."
    say "  ${DIM}cp .env.example .env, fill it in, then restart production.${RESET}"
    return 1
  fi

  if ts_public; then
    ok "Already public."
    print_urls
    return 0
  fi

  ts_connect || return 1

  if ! is_running; then
    launch_server prod || return 1
  fi

  if [ -z "$(ts_serve_url)" ] && ! ts serve --bg --https="$TS_HTTPS_PORT" "$PORT" >/dev/null 2>&1; then
    err "tailscale serve failed — production is running, but not on the tailnet."
    say "  ${DIM}Run 'tailscale --socket=$TS_SOCKET serve --bg --https=$TS_HTTPS_PORT $PORT' yourself to see why.${RESET}"
    return 1
  fi

  local funnel_err
  if ! funnel_err="$(ts funnel --bg --https="$TS_HTTPS_PORT" "$PORT" 2>&1)"; then
    err "tailscale funnel failed — production is on the tailnet, but not public."
    [ -n "$funnel_err" ] && say "$funnel_err" | sed 's/^/  /'
    say "  ${DIM}Funnel may need enabling for this tailnet or node — see https://tailscale.com/kb/1223/funnel${RESET}"
    return 1
  fi

  sync_awake
  warn "Public: anyone with this link can now open it, not just your tailnet."
  ok "Hosted publicly."
  print_urls
}

public_off() {
  if ! ts_public; then
    say "Not public."
    return 0
  fi

  ts_unfunnel || return 1
  # ts_unfunnel can take the plain tailnet listener down with it on some
  # Tailscale versions; put it back so this always ends up tailnet-only,
  # never fully withdrawn.
  if [ -z "$(ts_serve_url)" ]; then
    ts serve --bg --https="$TS_HTTPS_PORT" "$PORT" >/dev/null 2>&1
  fi
  sync_awake
  ok "No longer public — still on the tailnet."
  print_urls
}

# ---------------------------------------------------------------------------
# Finder double-click: no arguments and a terminal attached, so offer a menu
# and keep the window open afterwards.
# ---------------------------------------------------------------------------

lan_toggle() {
  if is_running && [ "$(current_mode)" = "lan" ]; then lan_off; else lan_on; fi
}

tailnet_toggle() {
  if [ -n "$(ts_serve_url)" ]; then tailnet_off; else tailnet_on; fi
}

public_toggle() {
  if ts_public; then public_off; else public_on; fi
}

prod_restart() {
  port_is_production && restart_server prod
}

menu() {
  menu_trap
  # Catch up first: a hold left over from before a reboot is released, and a
  # server already hosting without one gets the offer to set it up.
  sync_lid_hold
  while true; do
    menu_header "Booker — production"
    say "  1) Start production  ${DIM}(this Mac only, last build)${RESET}"
    say "  2) Stop production"
    say "  3) Restart production"
    say "  4) Rebuild production"
    if is_running && [ "$(current_mode)" = "lan" ]; then
      say "  5) Stop hosting on this network"
    else
      say "  5) Host on this network"
    fi
    if [ -n "$(ts_serve_url)" ]; then
      say "  6) Stop hosting on the tailnet"
    else
      say "  6) Host on the tailnet"
    fi
    if ts_public; then
      say "  7) Stop public access"
    else
      say "  7) Make public"
    fi
    say "  8) Show logs"
    say "  q) Quit"

    read_choice || return 0
    case "$MENU_CHOICE" in
      1) run_op prod_start prod ;;
      2) run_op prod_stop ;;
      3) run_op prod_restart ;;
      4) run_op prod_rebuild ;;
      5) run_op lan_toggle ;;
      6) run_op tailnet_toggle ;;
      7) run_op public_toggle ;;
      8) follow_log "$LOG_FILE" ;;
      q|Q) say "Bye. Anything still running keeps running."; return 0 ;;
      "") ;;
      *) warn "Pick 1–8, or q to quit." ;;
    esac
  done
}

usage() {
  say "Try: start | stop | restart | rebuild | lan [off] | tailnet [off] | public [off] | status | logs | setup"
}

case "${1:-}" in
  start)   run_op prod_start prod ;;
  stop)    run_op prod_stop ;;
  restart) run_op prod_restart ;;
  rebuild) run_op prod_rebuild ;;
  lan|tailnet|public)
    case "${2:-on}" in
      on)  run_op "${1}_on" ;;
      off) run_op "${1}_off" ;;
      *)   err "Unknown option: $2"; usage; exit 1 ;;
    esac
    ;;
  status)  status ;;
  logs)    follow_log "$LOG_FILE" ;;
  setup)   shift; sleep_setup "$@" ;;
  ""|menu)
    if [ -t 0 ]; then
      menu
    else
      status
    fi
    ;;
  -h|--help|help)
    # Print the header comment block, stopping at the first line of code.
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    ;;
  *)
    err "Unknown command: $1"
    usage
    exit 1
    ;;
esac
