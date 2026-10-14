#!/usr/bin/env bash
# statusbar.sh — pull-model status-right provider for tmux's `#()`.
# tmux spawns it as a background job on every status draw (status ticks AND
# job-completion redraws — back-to-back), inserts the last output line into
# status-right verbatim, and redraws when it exits. We enforce "no pull
# faster than status-interval": at most one full pull per interval, and
# faster spawns emit the last composed output. State + lock live in
# TMUX_TMPDIR if set, else /tmp (`#()` children get no TMUX_TMPDIR).
# Output rules:
#   * single line, single % (tmux does not strftime `#()` output)
#   * no `#{}`; `#[...]` styles are honored
#   * the time block is composed here (static: rendered at pull time)
exec 2>/dev/null
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/_env.bash"
source "${BASH_SOURCE[0]%/*}/statusbar-lib.bash"

# tmux passes the session whose bar it is drawing and the width of the client
# looking at it (04-statusbar.conf puts '#{session_name}' and '#{client_width}'
# in the job text, expanded at draw time); the job's own current session is the
# client's, a different one when an observer is attached, so window queries
# must name the drawn session and the width has to come from the expansion.
sb_session="${1:-}"
sb_client_w="${2:-}"

# --- pacing: at most one pull per status-interval --------------------------
# State file: line 1 = last claim (epoch s), line 2 = last composed output.
_sb_state="${TMUX_TMPDIR:-/tmp}/sb-state"

# _sb_lock — exclusive flock so concurrent spawns (tick + completion redraw)
# serialize; skipped when flock is absent (stock macOS) -> rare double-work.
_sb_lock() {
  command -v flock >/dev/null && exec 9>"${_sb_state}.lock" && flock 9
  return 0
}

# _sb_interval -> status-interval read live from tmux (the conf stays the
# source of truth; runtime changes are followed); default 3 if unavailable.
_sb_interval() {
  local iv
  iv=$(tmux show-options -gv status-interval 2>/dev/null | awk '{print $NF}')
  [[ $iv =~ ^[1-9][0-9]*$ ]] || iv=3
  printf '%s' "$iv"
}

# _sb_read_state -> SB_LAST (claim ts) / SB_CACHE (last composed output).
_sb_read_state() {
  SB_LAST='' SB_CACHE=''
  {
    IFS= read -r SB_LAST
    IFS= read -r SB_CACHE
  } <"$_sb_state" 2>/dev/null
  [[ $SB_LAST =~ ^[0-9]+$ ]] || SB_LAST=0
}

# _sb_opts -> the one tmux read for everything the conf owns that the bar
# needs: the clock-format value and the palette the chips paint with (@c_*).
# The conf is the single owner of both; the library stays tmux-free and takes
# them as inputs.
_sb_opts() {
  IFS='|' read -r clock_fmt _sb_s0 _sb_o2 _sb_t1 _sb_m < <(
    tmux display -p '#{E:@clock-format}|#{E:@c_s0}|#{E:@c_o2}|#{E:@c_t1}|#{E:@c_m}' 2>/dev/null
  )
}

# _sb_out_w TEXT -> publish TEXT as @sb_out (scratch) and echo the CELLS TEXT
# occupies on the status line. tmux's own width primitive is the base measure —
# it strips the #[...] style markers the conf wraps output in, which `wc -m`
# cannot. It is not the whole story: the private-use nf-icons it measures as
# zero-width are still drawn in a cell, so each of those is added back (round 3,
# E4e: the drawn left block was one cell wider than #{w:} reported).
_sb_out_w() {
  tmux set -g @sb_out "$1"
  local w plain
  w=$(tmux display -p '#{w:#{E:@sb_out}}' 2>/dev/null)
  [[ $w =~ ^[0-9]+$ ]] || w=0
  plain=${1//[$'\ue000'-$'\uf8ff']/}
  echo $((w + ${#1} - ${#plain}))
}

# _sb_sl_tw — publish @sl_tw, the active chip's title field (cells) for the next
# draw: the client's width minus everything else the bar draws. 04-statusbar.conf
# sizes that field from #{E:@sl_tw} and pads the remainder, so the window list is
# as wide as the client that drew last (server-global option, no per-client state
# -> last draw wins). 0 means "no room for a title": the conf's guard then drops
# the whole title group. Every input is measured in cells, not hand-counted:
# left block, this job's own output, per-window chip chrome (" #I ", optional
# " dot", active-title padding), one @sl_gap_pad between windows, and the two
# format spaces.
_sb_sl_tw() {
  local lw rows idx bell act n=0 sum=0 vis field
  [[ $sb_client_w =~ ^[0-9]+$ ]] || return 0 # no client -> keep the shipped field
  # the left block as tmux renders it, in cells (see _sb_out_w)
  lw=$(_sb_out_w "$(tmux display -t "$sb_session" -p '#{E:status-left}' 2>/dev/null)")
  [[ $lw =~ ^[0-9]+$ ]] || lw=0
  # `|` separators: a space-separated read collapses an empty #{@bell} and slides
  # window_active into bell, which counted 2 phantom columns for every window.
  rows=$(tmux list-windows -t "$sb_session" -F \
    '#{window_index}|#{@bell}|#{window_active}' 2>/dev/null)
  while IFS='|' read -r idx bell act; do
    [[ $idx =~ ^[0-9]+$ ]] || continue
    n=$((n + 1))
    sum=$((sum + ${#idx} + 2))          # " #I " chip
    [[ -n $bell ]] && sum=$((sum + 2))  # " dot" on a window that rang
    [[ $act == 1 ]] && sum=$((sum + 2)) # " " before the title + trailing " "
  done <<<"$rows"
  ((n)) || return 0
  sum=$((sum + n - 1)) # @sl_gap_pad between windows
  # the job's own output, measured by tmux's own width primitive (see above)
  vis=$(_sb_out_w "$1")
  [[ $vis =~ ^[0-9]+$ ]] || vis=0
  sum=$((sum + lw + vis + 2)) # blocks + the two format spaces
  field=$((sb_client_w - sum))
  # under 4 columns a title is a fragment: publish 0 and the conf's
  # #{?#{@sl_tw},...} guard drops the whole title group, leaving the teal
  # index chip as the accent. 0 is never tmux's "no limit" here, because the
  # guard sits outside the truncation term it would disable.
  ((field < 4)) && field=0
  tmux set -g @sl_tw "$field"
}

# _sb_stamp -> the conf-owned inputs (one read) + the time strings. The lib's
# _sb_time takes DATE/CLOCK as arguments, so nothing here is a cross-file global.
_sb_stamp() {
  _sb_opts
  date_str=$(date +%m.%d)
  clock=$(date +"$(_sb_clock_fmt "$clock_fmt")")
}

# _sb_pull -> the slow part: fills gpu/vram/cpu/ram/batt.
_sb_pull() {
  gpu_read
  if [[ $(uname -s) == Darwin ]]; then
    cpu_darwin "$(LC_ALL=C top -l 2 -n 0 -s 1 2>/dev/null)"
    ram_darwin "$(vm_stat 2>/dev/null)" "$(sysctl -n hw.memsize 2>/dev/null)"
    batt_darwin "$(pmset -g batt 2>/dev/null)" || true
  else
    read -r _ u n s i w _ </proc/stat
    total=$((u + n + s + i + w)) idle=$((i + w))
    sleep 0.5 # keeps the pull's #() job under tmux's 1s in-flight window
    read -r _ u n s i w _ </proc/stat
    total2=$((u + n + s + i + w)) idle2=$((i + w))
    cpu_delta "$total" "$idle" "$total2" "$idle2"
    read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
    ram_pct "$mt" "$ma"
    batt_linux || true
  fi
}

# _sb_write TS METRICS -> atomic state update (the renderer never sees a partial file).
_sb_write() {
  printf '%s\n%s\n' "$1" "$2" >"$_sb_state.$$" && mv "$_sb_state.$$" "$_sb_state"
}

# _sb_fetch TS -> slow path, runs detached: pull, publish metrics, ask for a redraw.
_sb_fetch() {
  _sb_pull
  _sb_write "$1" "$(compose_metrics)"
  tmux refresh-client -S
}

# Renderer: never waits on a pull.
_sb_lock
now=$(date +%s)
_sb_read_state
ready=0
[[ -f $_sb_state ]] && ready=1
if ((now - SB_LAST >= $(_sb_interval))); then
  _sb_write "$now" "$SB_CACHE" # claim first so concurrent spawns don't double-fetch
  # stdio + lock fd closed so tmux sees this job exit now, not when the fetch ends
  _sb_fetch "$now" </dev/null >/dev/null 9>&- &
fi
_sb_stamp
out=$(printf '%s%s' "$SB_CACHE" "$(_sb_time "$ready" "$date_str" "$clock")")
_sb_sl_tw "$out" # active-chip field for the next draw
printf '%s' "$out"
