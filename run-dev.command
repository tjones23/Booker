#!/bin/bash
#
# Booker — development launcher
#
# Double-click this file in Finder for a menu, or run it from a terminal:
#
#   ./run-dev.command start       # dotnet watch with hot reload, opens the browser
#   ./run-dev.command start --no-open
#   ./run-dev.command rebuild     # clean the Debug build and restart
#   ./run-dev.command stop
#   ./run-dev.command restart     # back in whatever mode it was running in
#   ./run-dev.command status
#   ./run-dev.command logs        # follow the log; any key stops following
#
#   ./run-dev.command setup       # once: let hosting keep a closed-lid Mac awake
#   ./run-dev.command setup --remove
#
# Dev runs in the Development environment against ./booker.db, with
# appsettings.Development.json and user secrets. Serving the production build
# — to this network, the tailnet or the internet — is run-prod.command's job.
# Both share scripts/run-common.sh, and either one can see and stop what the
# other started.

set -uo pipefail

# shellcheck source=scripts/run-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/run-common.sh" || exit 1

# The one place a browser is opened: starting the dev server by hand, where
# the next thing you want is the page. Everything else only starts the server.
dev_start() {
  local open_browser="${1:-open}"

  if is_running; then
    local mode
    mode="$(current_mode)"
    if [ "$mode" = "dev" ]; then
      warn "The dev server is already running."
      print_urls
      return 0
    fi
    err "Port $PORT is already in use ($(mode_label "$mode")) — stop that server first."
    return 1
  fi

  launch_server dev || return 1
  ok "Dev server running."
  print_urls

  if [ "$open_browser" = "open" ] && command -v open >/dev/null 2>&1; then
    open "http://localhost:$PORT"
  fi
}

# Throws away the Debug build, for when hot reload has wedged or keeps
# serving something stale. The production build is untouched: it lives in
# .booker/publish, built in Release.
dev_rebuild() {
  if is_running; then
    local mode
    mode="$(current_mode)"
    if [ "$mode" != "dev" ]; then
      err "Port $PORT is in use ($(mode_label "$mode")) — stop that server before rebuilding the dev server."
      return 1
    fi
    stop_server keep-serve || return 1
  fi

  preflight || return 1
  say "${DIM}Cleaning the Debug build…${RESET}"
  "$DOTNET_BIN" clean "$REPO_DIR/Booker.csproj" -c Debug --nologo -v q >/dev/null 2>&1
  rm -rf "$REPO_DIR/bin/Debug" "$REPO_DIR/obj/Debug"

  launch_server dev || return 1
  ok "Dev server rebuilt and running."
  print_urls
}

menu() {
  menu_trap
  sync_lid_hold
  while true; do
    menu_header "Booker — development"
    say "  1) Start dev server"
    say "  2) Rebuild dev server  ${DIM}(clean the Debug build and restart)${RESET}"
    say "  3) Stop"
    say "  4) Restart"
    say "  5) Show logs"
    say "  q) Quit"

    read_choice || return 0
    case "$MENU_CHOICE" in
      1) run_op dev_start open ;;
      2) run_op dev_rebuild ;;
      3) run_op stop_server ;;
      4) run_op restart_server dev ;;
      5) follow_log "$LOG_FILE" ;;
      q|Q) say "Bye. Anything still running keeps running."; return 0 ;;
      "") ;;
      *) warn "Pick 1–5, or q to quit." ;;
    esac
  done
}

case "${1:-}" in
  start|dev)
    if [ "${2:-}" = "--no-open" ]; then run_op dev_start no-open; else run_op dev_start open; fi ;;
  rebuild) run_op dev_rebuild ;;
  stop)    run_op stop_server ;;
  restart) run_op restart_server dev ;;
  status)  status ;;
  logs)    follow_log "$LOG_FILE" ;;
  setup)   shift; sleep_setup "$@" ;;
  ""|menu)
    if [ -t 0 ]; then
      menu
    else
      dev_start no-open
    fi
    ;;
  -h|--help|help)
    # Print the header comment block, stopping at the first line of code.
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    ;;
  *)
    err "Unknown command: $1"
    say "Try: start | rebuild | stop | restart | status | logs | setup"
    exit 1
    ;;
esac
