#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2001,SC2030,SC2031
# statusbar-e2e-test.bats — E2E tier: the real statusbar.sh under a throwaway
# tmux server, observed through a real attached client.
#
# Isolation (see test_helper.bash): per-test $T, the `tmux` wrapper always
# passes -S "$SOCK" so the user's real server is unreachable, no fixed /tmp
# paths -> safe under `bats --jobs N`.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  DIR="$BATS_TEST_DIRNAME"
}

teardown() {
  stop_scratch_server
}

# --- helpers -------------------------------------------------------------------

# Copy the real statusbar.sh (not the stub) into the scratch HOME.
load_real_script() {
  cp "$DIR/../scripts/statusbar.sh" "$HOME/.config/tmux/scripts/statusbar.sh"
  cp "$DIR/../scripts/statusbar-lib.bash" "$HOME/.config/tmux/scripts/statusbar-lib.bash"
  chmod +x "$HOME/.config/tmux/scripts/statusbar.sh"
}

# The stored status-right option is always the raw conf format (job
# substitution happens per-client at draw time), so the observable is the
# status line of a real attached client: its job cache renders the script's
# output. The time block never contains '%', so a '%' in the bottom row
# proves the job ran. The client is wide so the right-aligned status-right
# is not clipped.
attach_observer() {
  tmux new-session -d -s obs -x 200 -y 20 'env -u TMUX tmux attach-session -t base'
}
# The conf pins status-position top, so the status line is the first row.
obs_row() { tmux capture-pane -p -t obs | head -1; }
row_has_metrics() { [[ "$(obs_row)" == *'%'* ]]; }
row_nonempty() { [[ -n "$(obs_row)" ]]; }
# Decorated ready-state draw: metric blocks (%) and calendar (MM.DD) present
# in the right-aligned block (assert on the suffix so pane-title dots
# can't interfere).
row_ready() {
  local row suffix
  row="$(obs_row)"
  suffix="${row: -40}"
  [[ $suffix == *%* && $suffix == *.* ]]
}
# The fetcher has published metrics once the cached line (state line 2) has a %.
state_has_metrics() { [[ "$(sed -n 2p "$T/sb-state" 2>/dev/null)" == *%* ]]; }

# --- E2E: pull model (#() job) ----------------------------------------------

@test "E2E: attached client renders the composed status-right" {
  start_server
  load_conf
  load_real_script
  attach_observer
  # The job takes ~1s; wait for its output in the client's status line.
  wait_until 15 row_has_metrics
  local row
  row="$(obs_row)"
  # Metric blocks (percent signs, separators) plus the clock.
  [[ $row == *'%'* ]]
  [[ $row =~ [0-9]:[0-9]{2}$ ]]
}

@test "E2E: reload conf re-fires the status bar job" {
  start_server
  load_conf
  load_real_script
  attach_observer
  wait_until 15 row_has_metrics
  # Reload the conf — status-right goes back to the raw job format, and the
  # next tick re-runs the job under the new format.
  tmux source-file "$T/tmux.conf"
  wait_until 15 row_has_metrics
}

@test "E2E: data pulls paced at >= status-interval (no back-to-back)" {
  start_server
  load_conf
  load_real_script
  attach_observer
  # The script claims a pull slot by writing its start timestamp to the
  # pacing state file. It reads status-interval live, so 2s keeps the
  # back-to-back signature (d<=1) distinct from a paced pull (d==2 at
  # 1s-resolution clocks). Poll for the distinct claims (6s covers tick
  # alignment plus slow GPU probes).
  tmux set -g status-interval 2
  local state="$TMUX_TMPDIR/sb-state" claims="" lastv="" v start now
  start=$(date +%s)
  while :; do
    now=$(date +%s)
    ((now - start >= 6)) && break
    v="$(head -n1 "$state" 2>/dev/null || true)"
    [[ $v =~ ^[0-9]+$ && $v != "$lastv" ]] && claims+="$v " || true
    lastv="$v"
    sleep 0.2
  done
  local -a C=()
  read -ra C <<<"$claims"
  # >= 2 pulls in 6s, each spaced >= 2s (a true 2s spacing measures exactly
  # 2; the back-to-back bug measures 0-1) and <= 4s (catches a stuck
  # puller, absorbs one skipped tick on slow probes).
  [[ ${#C[@]} -ge 2 ]]
  local i
  for ((i = 1; i < ${#C[@]}; i++)); do
    local d=$((C[i] - C[i - 1]))
    ((d >= 2 && d <= 4))
  done
}

@test "E2E: first render is a fast bare clock; metrics fill in async (#() env)" {
  # Run the real script the way tmux does: `#()` children get TMUX (socket);
  # the harness's TMUX_TMPDIR=$T isolates the pacing state.
  # Run 1: no state -> bare clock returned at once, detached fetch spawned.
  # Run 2 (after the fetch lands): cached metrics + decorated calendar/clock.
  start_server
  load_conf
  load_real_script
  # sourced via runtime $DIR; not followable by shellcheck
  # shellcheck disable=SC1091
  source "$DIR/../scripts/statusbar-lib.bash"
  local out1 out2 t0 t1
  rm -f "$T/sb-state"
  t0=$EPOCHREALTIME
  out1="$(TMUX="$SOCK" bash "$HOME/.config/tmux/scripts/statusbar.sh")" # $() also proves the fetch is detached
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(b - a < 1) }'
  [[ $out1 =~ [0-9]{1,2}:[0-9]{2} ]] # clock present
  [[ $out1 != *'%'* ]]               # no metrics yet
  [[ $out1 != *"$(_icon cal)"* ]]    # no calendar icon
  [[ $out1 != *.* ]]                 # no date (MM.DD)
  wait_until 15 state_has_metrics
  out2="$(TMUX="$SOCK" bash "$HOME/.config/tmux/scripts/statusbar.sh")"
  [[ $out2 == *'%'* ]]            # metrics filled in
  [[ $out2 == *"$(_icon cal)"* ]] # calendar icon
  [[ $out2 == *.* ]]              # date (MM.DD)
}

@test "E2E: in-flight job returns cache in under 1s (no not-ready text)" {
  start_server
  load_conf
  load_real_script
  # A paced-out run must emit the cached line and exit fast: a `#()` job
  # outliving tmux's 1s in-flight window makes tmux render its placeholder
  # `<'cmd' not ready>` in status-right (tmux's own text, not a failure).
  local state="$T/sb-state"
  printf '%s\ncache line\n' "$(date +%s)" >"$state"
  local t0 t1 out
  t0=$EPOCHREALTIME
  out="$(TMUX="$SOCK" bash "$HOME/.config/tmux/scripts/statusbar.sh")"
  t1=$EPOCHREALTIME
  [[ $out == "cache line"* ]]
  [[ $out =~ [0-9]{1,2}:[0-9]{2} ]]
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(b - a < 1) }'
}

@test "E2E: ready-state draw shows the decorated block, clock exactly once" {
  start_server
  load_conf
  load_real_script
  attach_observer
  # After the second pull (had_prev=1), the decorated block renders:
  # metrics (%), calendar (MM.DD), separator — and a single clock at
  # the end.
  wait_until 15 row_ready
  local row
  row="$(obs_row)"
  # An HH:MM never abuts another HH:MM. Guards the regression where the
  # clock was present in both the ready branch and at top level,
  # rendering `16:0416:04`.
  [[ ! $row =~ [0-9]{1,2}:[0-9]{2}[0-9]{1,2}:[0-9]{2} ]]
}

@test "E2E: floax bell dot renders in the session chip (not blank padding)" {
  start_server
  load_conf
  load_real_script
  attach_observer
  wait_until 15 row_nonempty
  local row
  row="$(obs_row)"
  # Baseline: no dot anywhere in the bar.
  [[ $row != *'●'* ]]
  # The bell hook (scripts/bell.sh) sets @floax_bell; the chip's
  # conditional then shows the tab bell unit (red ●) after the
  # session name.
  tmux set -g @floax_bell 1
  tmux refresh-client -S
  row="$(obs_row)"
  [[ $row == *'base ●'* ]]
  # Clearing it removes the dot again.
  tmux set -gu @floax_bell
  tmux refresh-client -S
  row="$(obs_row)"
  [[ $row != *'●'* ]]
}

# --- budget oracle -----------------------------------------------------------
# statusbar.sh publishes @sl_tw, the active chip's title field for the next
# draw: the client's width minus everything else the bar draws. 04-statusbar.conf
# sizes that field once (#{E:@sl_tw} three times) and pads the remainder, so the
# window list must end where the right block begins. Two ways to be wrong, both
# observable: over-count clips the list (tmux draws its < > truncation markers),
# under-count leaves base-colour space there. The pad inside the active chip
# carries the chip bg (@c_s1), so a flush bar has exactly one base-colour space
# before the right block: the conf's `#[nolist align=right range=right default] `
# _sb_sl_tw sizes the window list to the client, so the drawn row must fill the
# client exactly: an over-count clips (tmux draws its < > truncation markers,
# asserted below), an under-count leaves the row short of the last column. The
# right block ends with the clock, so the row has no trailing spaces to strip
# and its own width is the observable for both directions of the error.
row_width() { obs_row | wc -m; }

@test "E2E: the published budget sizes the window list to the client" {
  start_server
  load_conf
  load_real_script
  tmux new-window -d -n tab2 'bash --norc --noprofile'
  tmux new-window -d -n tab3 'bash --norc --noprofile'
  tmux select-window -t base:2
  attach_observer
  wait_until 15 row_ready
  # the row and the published field only agree once the budget's fixed point
  # converges, so wait for two consecutive identical draws: that proves
  # convergence instead of catching a lucky tick.
  local prev='' row=''
  for _tick in {1..20}; do
    row="$(obs_row)"
    [[ -n $row && $row == "$prev" ]] && break
    prev=$row
    sleep 0.5
  done
  [[ -n $row && $row == "$prev" ]] # converged
  # the field is published and sane (the shipped 32 fallback would also pass,
  # so the gap and clip checks below carry the sizing claim)
  local field
  field=$(tmux show-options -gv @sl_tw | awk '{print $NF}')
  [[ $field =~ ^[0-9]+$ ]] && ((field > 0))
  # nothing clipped
  row="$(obs_row)"
  [[ $row != *'<'* && $row != *'>'* ]]
  # the row fills the client: no short tail, and no clip markers above
  [[ $(row_width) -eq $(tmux display -p '#{client_width}') ]] # flush
}
