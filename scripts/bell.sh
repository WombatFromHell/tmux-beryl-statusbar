#!/bin/sh
# bell.sh — the single owner of the per-window @bell flag.
#
#   bell.sh clear              acknowledge every window in the session
#   bell.sh ack <win>          acknowledge one window (selection / focus)
#   bell.sh <win> <sess> <active> <focused> <attached>
#                            a bell landed: sound it + arm that window's dot
#
# One dot per tab per period: @bell is a boolean. A bell sets it to 1;
# acknowledging (selecting the window, or the terminal regaining focus)
# clears it. Repeated bells within the same period can't re-arm it because
# it is already 1.
case ${1:-} in
clear)
  for w in $(tmux list-windows -F '#{window_id}'); do
    tmux set -uw -w -t "$w" @bell
  done
  exit 0
  ;;
ack)
  tmux set -uw -w -t "$2" @bell
  exit 0
  ;;
esac
win=$1 sess=$2 active=$3 focused=$4 attached=$5

# Already looking at it? Do nothing.
[ "$active" = 1 ] && [ "$focused" = 1 ] && [ "$attached" != 0 ] && exit 0

# Sound (Linux, then macOS)
if command -v paplay >/dev/null 2>&1; then
  paplay /usr/share/sounds/freedesktop/stereo/complete.oga &
elif command -v afplay >/dev/null 2>&1; then
  afplay /System/Library/Sounds/Glass.aiff &
fi

# floax isn't in the tab list, so it gets a global flag shown in status-right
if [ "$sess" = floax ]; then
  tmux set -g @floax_bell 1
else
  tmux set -w -t "$win" @bell 1
fi
tmux refresh-client -S
