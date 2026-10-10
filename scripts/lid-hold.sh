#!/bin/bash
#
# Shared closed-lid sleep hold — sourced by run-common.sh, never run directly.
#
# KEEP IN SYNC: this file is byte-identical in WhatsGood and Outside. Both
# apps host from the same Mac, and `pmset -a disablesleep` is one switch for
# the whole machine, so they have to agree on who may turn it back off.
#
# LID_HOLD_PROTOCOL=1
#
# The registry lives outside either repo:
#
#   $LH_DIR/holders/<app>   one per app hosting right now: its watcher's pid
#                           and a token the watcher recognizes itself by
#   $LH_DIR/owned           SleepDisabled was set by this registry, so the
#                           registry may undo it (never a setting you made)
#   $LH_DIR/lock.d          a mkdir lock around every change
#
# Sleep is disabled when the first app starts hosting and re-enabled only
# when the last one stops. A holder whose watcher has died (a reboot, a kill)
# is pruned by the next app to look, so a stale entry can't pin the Mac awake.
#
# Expects from the sourcing script: APP_ID, REPO_DIR, SELF, PMSET, the
# say/ok/warn/err helpers and colors, hosting_active, is_busy, sleep_setup.
# LH_LEGACY_MARKER may name an older per-app marker to migrate.

LH_DIR="${LID_HOLD_DIR:-$HOME/.local/state/lid-hold}"
LH_HOLDERS="$LH_DIR/holders"
LH_OWNED="$LH_DIR/owned"
LH_LOCK="$LH_DIR/lock.d"
LH_SETUP_OFFERED=""

sleep_is_disabled() {
  ioreg -rn IOPMrootDomain -d1 2>/dev/null | grep -q '"SleepDisabled" = Yes'
}

lh_lock() {
  mkdir -p "$LH_HOLDERS" || return 1
  local tries=0
  until mkdir "$LH_LOCK" 2>/dev/null; do
    # A lock left by a killed script is stale after 15 seconds.
    if [ -n "$(find "$LH_LOCK" -maxdepth 0 -mtime +15s 2>/dev/null)" ]; then
      rmdir "$LH_LOCK" 2>/dev/null
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -gt 100 ] && return 1
    sleep 0.1
  done
  return 0
}

lh_unlock() {
  rmdir "$LH_LOCK" 2>/dev/null
  return 0
}

lh_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

lh_alive() {
  local pid
  pid="$(lh_field "$1" watch_pid)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Drop holders whose watcher is gone.
lh_prune() {
  local f
  for f in "$LH_HOLDERS"/*; do
    [ -f "$f" ] || continue
    lh_alive "$f" || rm -f "$f"
  done
}

# Other apps holding sleep off right now, space-separated.
lh_others() {
  local f names=""
  for f in "$LH_HOLDERS"/*; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = "$APP_ID" ] && continue
    lh_alive "$f" && names="$names ${f##*/}"
  done
  printf '%s' "${names# }"
}

lh_own_hold() {
  [ -f "$LH_HOLDERS/$APP_ID" ] && lh_alive "$LH_HOLDERS/$APP_ID"
}

# An older per-app marker meant "we set SleepDisabled"; that is now `owned`.
lh_migrate_legacy() {
  [ -n "${LH_LEGACY_MARKER:-}" ] && [ -f "$LH_LEGACY_MARKER" ] || return 0
  mkdir -p "$LH_DIR" && : > "$LH_OWNED" && rm -f "$LH_LEGACY_MARKER"
}

# Called with the lock held. The watcher releases this app's hold once it
# stops hosting, however that happens — a crash, or the other launcher. It
# exits as soon as its holder file stops naming its token, so a newer watcher
# replaces it cleanly. HUP is ignored so closing the Terminal doesn't end it.
lh_start_watch() {
  local holder="$LH_HOLDERS/$APP_ID" token
  token="$$-$RANDOM-$(date +%s)"
  printf 'token=%s\nrepo=%s\n' "$token" "$REPO_DIR" > "$holder"
  (
    trap '' HUP INT
    while grep -q "^token=$token\$" "$holder" 2>/dev/null; do
      sleep 20
      hosting_active || is_busy || break
    done
    # Re-checked: hosting may have started again since the loop last looked.
    if grep -q "^token=$token\$" "$holder" 2>/dev/null; then
      hosting_active || is_busy || lid_hold_off
    fi
  ) </dev/null >/dev/null 2>&1 &
  printf 'watch_pid=%s\ntoken=%s\nrepo=%s\n' "$!" "$token" "$REPO_DIR" > "$holder"
}

lid_hold_on() {
  lh_migrate_legacy
  lh_lock || { warn "Couldn't lock $LH_DIR — sleep handling skipped."; return 1; }
  lh_prune

  if lh_own_hold && sleep_is_disabled; then
    lh_unlock
    return 0
  fi

  local newly=""
  if ! sleep_is_disabled; then
    if ! sudo -n "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
      lh_unlock
      lh_offer_setup && lid_hold_on && return 0
      warn "Only idle sleep is held off — closing the lid will still sleep this Mac."
      say "  ${DIM}Run '$SELF setup' once to fix that.${RESET}"
      return 1
    fi
    : > "$LH_OWNED"
    newly=1
  fi

  lh_start_watch
  lh_unlock
  [ -n "$newly" ] && ok "Sleep disabled while hosting — it's safe to close the lid (keep it plugged in)."
  return 0
}

# Offer the one-time sudoers setup, once per run and only to a person.
lh_offer_setup() {
  [ -z "$LH_SETUP_OFFERED" ] && [ -t 0 ] && [ -t 1 ] || return 1
  LH_SETUP_OFFERED=1
  say ""
  warn "This Mac will still sleep if its lid is closed (or a Screen Sharing session ends with it closed)."
  say "  Staying up with the lid closed needs a one-time admin setup: a sudoers rule that lets"
  say "  these scripts run '$PMSET -a disablesleep 0|1' without a password, and nothing else."
  printf '  Set it up now? You will be asked for your password. [Y/n] '
  local answer
  read -r answer
  case "$answer" in
    n|N|no|No) return 1 ;;
  esac
  sleep_setup
}

# Release this app's hold; re-enable sleep only if no other app holds it and
# the registry was the one that disabled it.
lid_hold_off() {
  lh_migrate_legacy
  [ -d "$LH_DIR" ] || return 0
  lh_lock || return 1
  lh_prune

  local had=""
  [ -f "$LH_HOLDERS/$APP_ID" ] && had=1
  rm -f "$LH_HOLDERS/$APP_ID"

  local others
  others="$(lh_others)"
  if [ -n "$others" ]; then
    lh_unlock
    [ -n "$had" ] && say "  ${DIM}Sleep stays disabled — still hosting: $others.${RESET}"
    return 0
  fi

  if [ -f "$LH_OWNED" ]; then
    if ! sleep_is_disabled; then
      rm -f "$LH_OWNED"
    elif sudo -n "$PMSET" -a disablesleep 0 >/dev/null 2>&1; then
      rm -f "$LH_OWNED"
      ok "Nothing is hosted any more — this Mac can sleep normally again."
    else
      warn "Couldn't re-enable sleep — run 'sudo pmset -a disablesleep 0'."
    fi
  fi
  lh_unlock
  return 0
}

# One line on how sleep is being handled, for status and the menus.
sleep_summary() {
  if sleep_is_disabled; then
    if [ -f "$LH_OWNED" ]; then
      say "  ${DIM}sleep: disabled while hosting — safe to close the lid${RESET}"
    else
      say "  ${DIM}sleep: disabled system-wide (not by these scripts)${RESET}"
    fi
  elif hosting_active; then
    say "  ${YELLOW}sleep: only idle sleep held off — closing the lid will sleep this Mac ('$SELF setup')${RESET}"
  fi
}
