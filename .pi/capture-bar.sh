#!/usr/bin/env bash
set -euo pipefail
# capture-bar.sh — render the shipped status bar in a throwaway tmux server and
# dump everything a client can observe, so a before/after pair can be diffed.
#
#   .pi/capture-bar.sh .pi/golden-pre.txt
#
# Isolation mirrors tests/test_helper.bash: private socket dir, scratch HOME
# holding the shipped conf, so ~ and ~/.config/tmux never resolve to the user's
# dotfiles and the real server is unreachable.

OUT="${1:?usage: capture-bar.sh OUTFILE}"
WIDTHS="${WIDTHS:-200 140 90}" # observer client widths, swept in order

SOCKDIR=$(mktemp -d)
SOCK="$SOCKDIR/tmux-$(id -u)/default" # default path, so a nested bare `tmux attach` finds this server
mkdir -p -m 700 "${SOCK%/*}"
T() { env -u TMUX TMUX_TMPDIR="$SOCKDIR" tmux -S "$SOCK" "$@"; }
cleanup() {
  [[ -S $SOCK ]] && T kill-server 2>/dev/null || true
  rm -rf "$SOCKDIR"
}
trap cleanup EXIT

# Scratch HOME with the shipped conf + real statusbar script.
H="$SOCKDIR/home"
export HOME="$H" XDG_CONFIG_HOME="$H/.config" # tmux reads ~/.config/tmux; never the user's dotfiles
mkdir -p -m 700 "$H/.config/tmux/scripts"
cp tmux.conf "$SOCKDIR/tmux.conf"
cp -r conf.d "$H/.config/tmux/"
cp scripts/statusbar.sh scripts/statusbar-lib.bash scripts/lockchip.sh "$H/.config/tmux/scripts/"
chmod +x "$H/.config/tmux/scripts"/*.sh

T -f "$SOCKDIR/tmux.conf" new-session -d -s base -x 200 -y 20 'bash --norc --noprofile'
[[ $(T display -p -t base:1 '#{socket_path}') == "$SOCK" ]] || {
  echo "wrong server" >&2
  exit 1
}

# Three tabs, pinned titles, middle one active: a deterministic tab list whose
# active chip is the one the smart-width work touches.
T new-window -d -n tab2 'bash --norc --noprofile'
T new-window -d -n tab3 'bash --norc --noprofile'
for w in 1 2 3; do
  T set-window -t "base:$w" automatic-rename off
  T select-pane -t "base:$w" -T "title$w"
done
T select-window -t base:2

# Observer client, 200 cols; status-position is top, so the bar is row 1.
T new-session -d -s obs -x 200 -y 20 'env -u TMUX tmux attach-session -t base'
row() { T capture-pane -p -t obs | head -1 | sed 's/[[:space:]]*$//' ; }
ready() { [[ $(row) == *%* ]]; } # '%' only comes from the metric blocks
sweep() { # resize the observer across WIDTHS, one bar row per width
  local w
  for w in $WIDTHS; do
    T resize-window -t obs -x "$w" -y 20
    sleep 3.25 # > status-interval (02-core.conf: 3s), which redraws the status line at the new width
    printf '## width %s\nsl_tw: %s\n' "$w" "$(T show-options -gv @sl_tw 2>/dev/null)"
    row
  done
}

{
  printf '# @sl_windows_fmt — the mechanism (raw conf value)\n'
  T show-options -gv @sl_windows_fmt

  printf '# row — real statusbar.sh, metrics filled (what the user sees)\n'
  for _ in $(seq 40); do ready && break || sleep 0.25; done
  ready || echo 'NOT READY: no metrics in the bar' >&2
  sweep

  printf '# row — stub statusbar.sh, no live data (byte-stable baseline)\n'
  printf '#!/bin/sh\nexit 0\n' >"$H/.config/tmux/scripts/statusbar.sh"
  # the stub publishes nothing, so the field would stay at whatever the last
  # real draw left (0 = no title); pin the shipped fallback to keep the
  # baseline about the format, not about the previous sweep's client width
  T set -g @sl_tw 32
  T refresh-client -S
  for _ in $(seq 40); do [[ $(row) != *%* ]] && break || sleep 0.25; done
  sweep
} >"$OUT"

echo "wrote $OUT"
