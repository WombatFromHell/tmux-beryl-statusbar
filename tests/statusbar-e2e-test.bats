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

# The stored status-right option is always the raw conf format (job
# substitution happens per-client at draw time), so the observable is the
# status line of a real attached client: its job cache renders the script's
# output. The time block never contains '%', so a '%' in the bottom row
# proves the job ran. The client is wide so the right-aligned status-right
# is not clipped.
attach_observer() { attach_observer_at 200; }
# The same client at a given width, for claims about a narrow bar.
attach_observer_at() {
  tmux new-session -d -s obs -x "$1" -y 20 'env -u TMUX tmux attach-session -t base'
}
# The conf pins status-position top, so the status line is the first row.
obs_row() { tmux capture-pane -p -t obs | head -1; }
# The same row with its colours, for claims about which cells are painted over.
obs_esc() { tmux capture-pane -e -p -t obs | head -1; }
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
  real_bar
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
  real_bar
  attach_observer
  wait_until 15 row_has_metrics
  # Reload the conf — status-right goes back to the raw job format, and the
  # next tick re-runs the job under the new format.
  tmux source-file "$T/tmux.conf"
  wait_until 15 row_has_metrics
}

@test "E2E: data pulls paced at >= status-interval (no back-to-back)" {
  real_bar
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
  real_bar
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
  real_bar
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
  real_bar
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
  real_bar
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
# statusbar.sh publishes @sl_tw, the active chip's title field for the next draw:
# the client's width minus everything else the bar draws. 04-statusbar.conf uses
# it as a truncation limit only, so the free space is tmux's own fill and a padded
# `capture-pane -p` row cannot show it: `wc -m` of that row is the client width
# whether or not the budget is right. The observable errors are the list being
# clipped (tmux draws its < > markers) and a title that fits the field rendering
# cut; both directions of the error are asserted by the field-boundary test below.
row_width() { obs_row | wc -m; }

# The row and the published field only agree once the budget's fixed point
# converges, so wait for two consecutive identical draws: that proves
# convergence instead of catching a lucky tick.
stable_draw() { # $1: name of a zero-arg row function
  local prev='' row=''
  for _tick in {1..20}; do
    row="$($1)"
    [[ -n $row && $row == "$prev" ]] && break
    prev=$row
    sleep 0.5
  done
  [[ -n $row && $row == "$prev" ]] # converged
  printf '%s\n' "$row"
}
stable_row() { stable_draw obs_row; }
stable_esc() { stable_draw obs_esc; }

# The SGR tmux emits for a palette colour used as a background, so a test can
# point at the cells that colour paints without hardcoding the triplet.
sgr_bg() {
  local h=${1#\#}
  printf '\033[48;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}
# The same for a foreground colour.
sgr_fg() {
  local h=${1#\#}
  printf '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}

# The metric chips are composed inside the detached pull, so the palette read
# (_sb_opts) has to happen before that subshell forks. Read it only in the
# renderer (_sb_stamp, as it was) and the fetch composes empty terms: the cached
# line carries `#[bg=] #[fg=]`, which tmux paints with the bar's own colour, while
# the renderer's own time block keeps its colours. That asymmetry is the defect.
@test "E2E: the detached pull composes with the palette it owns" {
  real_bar
  attach_observer
  wait_until 15 row_ready
  local s0
  s0=$(tmux show-options -gv @c_s0)
  [[ $s0 == \#[0-9a-fA-F][0-9a-fA-F]* ]] # the conf owns the chip colour
  # the cached metric line is replayed verbatim, so it must already carry it
  [[ "$(sed -n 2p "$T/sb-state")" == *"bg=$s0"* ]]
}

# The published field is a truncation limit, so a title that fits it renders whole.
# Over-measuring the bar's own blocks shrinks the field and tmux clips such a title
# with its own ellipsis; the shipped _sb_out_w used to add a cell back per
# private-use nf-icon on top of tmux 3.8's #{w:}, which already counts those cells.
@test "E2E: a title that fits the published field renders whole" {
  real_bar
  tmux new-window -d -n tab2 'bash --norc --noprofile'
  tmux set-window -t base:1 automatic-rename off
  tmux select-window -t base:1
  attach_observer
  wait_until 15 row_ready
  local field title esc
  field=$(tmux display -p '#{E:@sl_tw}')
  [[ $field =~ ^[1-9][0-9]*$ ]]
  title=$(printf 't%.0s' $(seq 1 "$field")) # exactly the field, no more
  tmux select-pane -t base:1 -T "$title"
  tmux refresh-client -S
  wait_until 15 row_ready
  esc="$(stable_esc)"
  [[ $esc == *"$title"* ]] # nothing clipped
}

# The active chip's coloured band must hug its content: the free space belongs to
# tmux's own fill, not to the chip. A pad term inside the styled title group paints
# @c_s1 over that space, so the band keeps running past the title's trailing margin.
@test "E2E: the active chip's colour hugs its title" {
  real_bar
  tmux new-window -d -n tab2 'bash --norc --noprofile'
  tmux set-window -t base:1 automatic-rename off
  tmux select-window -t base:1
  tmux select-pane -t base:1 -T 'fixed title'
  attach_observer
  wait_until 15 row_ready
  local esc seq
  esc="$(stable_esc)"
  seq=$(sgr_bg "$(tmux show-options -gv @c_s1)")
  [[ $esc == *"$seq fixed title "* ]]  # the band opens with the title
  [[ $esc != *"$seq fixed title  "* ]] # and closes after its own margin
}

# The free space between the window list and the right block is tmux's own fill,
# painted with the bar's colour (@c_base), so the cell before the right block's
# first chip carries that colour. The right block starts with a space painted
# @c_s0 followed by the chip's icon in @c_t1, which is the only place in the row
# where that pair of colours appears back to back.
@test "E2E: the free space is the bar's own colour" {
  real_bar
  tmux new-window -d -n tab2 'bash --norc --noprofile'
  attach_observer
  wait_until 15 row_ready
  local esc base gap needle before_block
  esc="$(stable_esc)"
  base=$(sgr_bg "$(tmux show-options -gv @c_base)")
  gap=$(printf '%*s' 20 '')   # a run no chip margin can produce
  [[ $esc == *"$base$gap"* ]] # the fill is one long bar-coloured run
  needle="$(sgr_bg "$(tmux show-options -gv @c_s0)") $(sgr_fg "$(tmux show-options -gv @c_t1)")"
  before_block=${esc%%"$needle"*}
  before_block=${before_block%"${before_block##*[! ]}"} # the gap's own cells
  [[ $before_block == *"$base" ]]                       # it ends in the bar's colour, not a chip's
}

@test "E2E: the published budget sizes the window list to the client" {
  real_bar
  tmux new-window -d -n tab2 'bash --norc --noprofile'
  tmux new-window -d -n tab3 'bash --norc --noprofile'
  tmux select-window -t base:2
  attach_observer
  wait_until 15 row_ready
  local row field
  row="$(stable_row)"
  # the field is published and positive (the shipped 32 fallback would also pass,
  # so the clip check below carries the sizing claim)
  field=$(tmux show-options -gv @sl_tw | awk '{print $NF}')
  [[ $field =~ ^[0-9]+$ ]] && ((field > 0))
  # nothing clipped
  [[ $row != *'<'* && $row != *'>'* ]]
}

# The title shrinks first, then the tabs themselves: once the window chrome no
# longer fits the space, tmux marks the cut end with its > marker. The pad used
# to size the list exactly to the space, so that state never arrived.
@test "E2E: the window list marks the cut when the tabs stop fitting" {
  real_bar
  local i
  for i in 1 2 3 4 5 6 7 8; do
    tmux new-window -d -n "tab$i" 'bash --norc --noprofile'
  done
  attach_observer_at 60
  wait_until 15 row_ready
  local row
  row="$(stable_row)"
  [[ $row == *'>'* ]] # the cut end is marked, not silently chopped
}

# The sizing rule (DESIGN.md): the title field is budgeted for @sl_tab_budget
# chips, not for the live count, so the chip past that budget makes the list
# wider than the space and tmux marks the cut. @sl_title_floor keeps the active
# title readable instead of letting the field collapse; a title shorter than the
# field keeps its own width, so more chips stay visible and nothing is marked.
@test "E2E: the chip past the tab budget marks the cut" {
  real_bar
  local i
  for i in 1 2 3; do
    tmux new-window -d -n "tab$i" 'bash --norc --noprofile'
  done
  tmux set-window -t base:3 automatic-rename off
  tmux select-window -t base:3
  tmux select-pane -t base:3 -T "$(printf 'w%.0s' $(seq 1 200))"
  attach_observer
  wait_until 15 row_ready
  local row
  row="$(stable_row)"
  [[ $row == *'<'* || $row == *'>'* ]] # the cut end is marked, not silently chopped
}

@test "E2E: a short title keeps the chip budget visible" {
  real_bar
  local i
  for i in 1 2 3 4 5 6; do
    tmux new-window -d -n "tab$i" 'bash --norc --noprofile'
  done
  tmux set-window -t base:6 automatic-rename off
  tmux select-window -t base:6
  tmux select-pane -t base:6 -T 'short'
  attach_observer
  wait_until 15 row_ready
  local row
  row="$(stable_row)"
  [[ $row != *'<'* && $row != *'>'* ]] # six chips fit: nothing to mark
}

# scripts/lockchip.sh emits ' #[fg=…]<glyph> ' (3 cells) inside the session
# chip when the leader is locked, and tmux's #{w:} primitive measures the
# status-left's #() job as zero width, so those cells are outside the left
# block's term: locking without a term of its own leaves the row short by 3.
# `set -g prefix None` is exactly what _is_locked tests.
@test "E2E: a locked leader keeps the budget flush" {
  real_bar
  attach_observer
  wait_until 15 row_ready
  tmux set -g prefix None # the leader is locked: lockchip.sh's _is_locked test
  tmux refresh-client -S
  wait_until 15 row_ready
  local row
  row="$(stable_row)"
  [[ $row != *'<'* && $row != *'>'* ]]                                # nothing clipped
  [[ $(tmux show-options -gv @sl_tw | awk '{print $NF}') =~ ^[1-9] ]] # the field still fits a title
}

# Dragging the terminal: the job re-runs with the new #{client_width} on the
# next status-interval tick, so each width needs its own convergence wait
# (status-interval is 3s, see 02-core.conf). resize-window -x/-y is the
# harness's only headless lever on a client's width.
@test "E2E: a resize follows the new client width" {
  real_bar
  attach_observer
  wait_until 15 row_ready
  local row
  for w in 140 90; do
    tmux resize-window -t obs -x "$w" -y 20
    tmux refresh-client -S
    wait_until 15 row_ready
    row="$(stable_row)"
    [[ $row != *'<'* && $row != *'>'* ]]                                # nothing clipped
    [[ $(tmux show-options -gv @sl_tw | awk '{print $NF}') =~ ^[1-9] ]] # the field follows the width
  done
}

# Absurdly narrow client: the field under the chrome leaves no room for a title,
# so the bar must stop drawing a 1-char fragment and let the teal chip be the
# accent. 0 is what the conf's #{?#{@sl_tw},...} guard reads as "no title term".
# 60 is the width where the list chrome still fits without the title, so the
# indexes must survive; 40 is below that ceiling — the chrome itself no longer
# fits, which is tmux's own truncation, so the claim there is only "no garbage".
@test "E2E: a client narrower than the budget drops the active title" {
  real_bar
  tmux new-window -d -n tab2 'bash --norc --noprofile'
  attach_observer
  wait_until 15 row_ready
  local row w
  for w in 60 40; do
    tmux resize-window -t obs -x "$w" -y 20
    tmux refresh-client -S
    # row_ready reads the last 40 columns, which a narrow client clips, so the
    # wait here is only that the client drew something.
    wait_until 15 row_nonempty
    row="$(stable_row)"
    [[ $row != *'<'* && $row != *'>'* ]]                        # nothing clipped
    [[ $(row_width) -le $(tmux display -p '#{client_width}') ]] # never overflows
    [[ $(tmux show-options -gv @sl_tw) -eq 0 ]]                 # the title group is not drawn
    # every window index survives where the chrome still fits without the title
    if ((w == 60)); then
      local i
      for i in $(tmux list-windows -t base -F '#{window_index}'); do
        [[ $row == *" $i "* ]] # index survives
      done
    fi
  done
}
