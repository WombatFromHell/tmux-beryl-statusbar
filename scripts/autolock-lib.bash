#!/usr/bin/env bash
# autolock-lib.bash — pure decision layer for autolock.sh. No tmux, no I/O:
# `decide` maps (locked-procs, foreground, locked, override) to an action.
# Sourced by autolock.sh (consumer) and by the bats unit tier, so the same
# logic is exercised live and unit-tested with fixtures.

# matches_locked LOCKED_PROCS FG -> success (0) if FG is exactly one of the
# locked procs (full-string match, so 'sshd' does NOT match 'ssh').
matches_locked() {
  local pattern
  pattern="^($1)$"
  [[ $2 =~ $pattern ]]
}

# auto_desired LOCKED_PROCS FG -> "lock" if FG is a locked proc, else "unlock".
# The single owner of the auto half of the decision: `decide` and autolock.sh's
# override-clearing both ask it, so the rule lives in one place.
auto_desired() {
  if matches_locked "$1" "$2"; then printf 'lock'; else printf 'unlock'; fi
}

# decide LOCKED_PROCS FG LOCKED OVERRIDE -> "lock" | "unlock" | "noop"
#   LOCKED_PROCS  regex alternation of procs that should lock (e.g. 'ssh|fzf')
#   FG            current foreground procname
#   LOCKED        1 if the leader is currently locked, else 0
#   OVERRIDE      "lock" | "unlock" | "" (manual state set by F12; "" = none).
#
# The override (if set) takes priority over the auto-desired state.
decide() {
  local locked_procs=$1 fg=$2 locked=$3 override=$4
  local desired auto
  auto=$(auto_desired "$locked_procs" "$fg")
  [[ -n $override ]] && desired=$override || desired=$auto
  if [[ $desired == lock && $locked != 1 ]]; then
    printf 'lock'
  elif [[ $desired == unlock && $locked == 1 ]]; then
    printf 'unlock'
  else
    printf 'noop'
  fi
}
