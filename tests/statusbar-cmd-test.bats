#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2016,SC2030,SC2031
# statusbar-cmd-test.bats — the command chip resolver (_sb_cmd in statusbar.sh,
# @sl_cmd / @sl_cmd_for / @sl_command in 04-statusbar.conf).
#
# Two tiers, both against a throwaway tmux server (see test_helper.bash):
#   * publish tests run the real statusbar.sh by hand, the way tmux's `#()` does
#     (TMUX="$SOCK"), so there is no tick to wait for: the options are checked
#     right after the run.
#   * render tests attach an observer and read the chip off the drawn status line.
#
# Every command runs as a foreground job of the runner in test_helper.bash
# (open_cmd_window), so the foreground process group is a real job (own pgid ==
# the tty's tpgid), exactly what the resolver keys on — with no client attached
# and no send-keys. A `shell -c cmd` window would test the shell's exec
# behaviour instead.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  DIR="$BATS_TEST_DIRNAME"
}

teardown() {
  stop_scratch_server
}

# --- helpers -------------------------------------------------------------------

# tmux's own name for the foreground command (argv[0] only).
cmd_is() { [[ "$(tmux display -p -t base '#{pane_current_command}')" == "$1" ]]; }

# One statusbar.sh run, as tmux's `#()` would make it (drawn session, client width).
run_job() { TMUX="$SOCK" bash "$HOME/.config/tmux/scripts/statusbar.sh" base 200 >/dev/null; }
sl_cmd() { tmux show-options -gv @sl_cmd; }
sl_cmd_for() { tmux show-options -gv @sl_cmd_for; }
# The chip as the conf composes it for the active pane, before any drawing.
chip_fmt() { tmux display -p -t base '#{E:@sl_command}'; }

# Observer helpers (same shape as statusbar-e2e-test.bats).
attach_observer() {
  tmux new-session -d -s obs -x 200 -y 20 'env -u TMUX tmux attach-session -t base'
}
obs_row() { tmux capture-pane -p -t obs | head -1; }
obs_esc() { tmux capture-pane -e -p -t obs | head -1; }
row_ready() {
  local suffix
  suffix="$(obs_row)"
  suffix="${suffix: -40}"
  [[ $suffix == *%* && $suffix == *.* ]]
}
row_has() { [[ "$(obs_row)" == *"$1"* ]]; }
row_lacks() { [[ "$(obs_row)" != *"$1"* ]]; }

# --- publish tier: what the resolver writes ------------------------------------

@test "cmd: ships empty, and the chip falls back to the bare name before the first draw" {
  stub_bar
  open_cmd_window 'sleep 300'
  wait_until 5 cmd_is sleep
  [[ -z "$(sl_cmd)" ]]
  [[ -z "$(sl_cmd_for)" ]]
  [[ "$(chip_fmt)" == *' sleep '* ]]
}

@test "cmd: a plain command publishes its args" {
  real_bar
  open_cmd_window 'sleep 300'
  wait_until 5 cmd_is sleep
  run_job
  [[ "$(sl_cmd)" == 'sleep 300' ]]
  [[ "$(sl_cmd_for)" == sleep ]]
}

@test "cmd: a command run by absolute path is published by its basename" {
  real_bar
  open_cmd_window "$(type -P sleep) 300"
  wait_until 5 cmd_is sleep
  run_job
  [[ "$(sl_cmd)" == 'sleep 300' ]]
  [[ "$(sl_cmd_for)" == sleep ]]
}

@test "cmd: an interpreter keeps the command it runs" {
  real_bar
  open_cmd_window "sh -c 'sleep 300; :'"
  wait_until 5 cmd_is sh
  run_job
  # the leader is the sh; its child sleep shares the group but must not win.
  # 'sh -c sleep 300; :' is 18 chars: the first 14 and the ellipsis
  [[ "$(sl_cmd)" == 'sh -c sleep 30…' ]]
  [[ "$(sl_cmd_for)" == sh ]]
}

@test "cmd: an idle shell publishes under its own name (the ignore regex then hides it)" {
  real_bar
  open_cmd_window
  wait_until 5 cmd_is bash
  run_job
  [[ "$(sl_cmd_for)" == bash ]]
  [[ "$(sl_cmd)" == bash* ]]
}

@test "cmd: a long command line is cut to 15 chars with a trailing ellipsis" {
  real_bar
  open_cmd_window "cat - $(printf 'a%.0s' $(seq 1 80))"
  wait_until 5 cmd_is cat
  run_job
  local v
  v="$(sl_cmd)"
  [[ $v == 'cat - '*… ]]
  ((${#v} <= 17)) # 15 chars, or 17 bytes in a C locale (the ellipsis is 3)
  [[ $v == 'cat - aaaaaaaa…' ]] # 14 chars + the ellipsis
}

@test "cmd: a command that fits the budget is published whole, no ellipsis" {
  real_bar
  open_cmd_window 'sleep 123456789' # exactly 15 chars
  wait_until 5 cmd_is sleep
  run_job
  [[ "$(sl_cmd)" == 'sleep 123456789' ]]
}

@test "cmd: path-like args keep only their basename" {
  real_bar
  open_cmd_window 'cat - /no/such/dir/f.txt ./x/y'
  wait_until 5 cmd_is cat
  run_job
  [[ "$(sl_cmd)" == 'cat - f.txt y' ]]
}

@test "cmd: a directory arg with a trailing slash shows its last component" {
  real_bar
  open_cmd_window 'cat - /no/such/dir/'
  wait_until 5 cmd_is cat
  run_job
  [[ "$(sl_cmd)" == 'cat - dir' ]]
}

@test "cmd: a resolver miss publishes the bare name, never a blank chip" {
  real_bar
  open_cmd_window 'sleep 300'
  wait_until 5 cmd_is sleep
  # ps finds nothing: the shipped fallback is tmux's own name
  make_mock ps $'#!/bin/sh\nexit 1\n'
  TMUX="$SOCK" PATH="$T/mock:$PATH" bash "$HOME/.config/tmux/scripts/statusbar.sh" base 200 >/dev/null
  [[ "$(sl_cmd)" == sleep ]]
  [[ "$(sl_cmd_for)" == sleep ]]
  [[ "$(chip_fmt)" == *' sleep '* ]]
}

# --- the conf's stale-text guard -----------------------------------------------

@test "cmd: text published for another command is never shown" {
  stub_bar
  open_cmd_window 'sleep 300'
  wait_until 5 cmd_is sleep
  # last draw was for python3; the pane has since moved on to sleep
  tmux set -g @sl_cmd 'python3 old.py'
  tmux set -g @sl_cmd_for python3
  [[ "$(chip_fmt)" == *' sleep '* ]]
  [[ "$(chip_fmt)" != *'old.py'* ]]
  # once the publish catches up, the full text takes over
  tmux set -g @sl_cmd 'sleep 300'
  tmux set -g @sl_cmd_for sleep
  [[ "$(chip_fmt)" == *'sleep 300'* ]]
}

# --- render tier: what the client draws ----------------------------------------

@test "cmd: the drawn chip carries the command's args, and drops when it exits" {
  real_bar
  open_cmd_window 'sleep 300'
  wait_until 5 cmd_is sleep
  attach_observer
  wait_until 15 row_ready
  wait_until 15 row_has 'sleep 300'
  # end the job: the runner exec's an idle shell, so the chip is hidden by the ignore regex
  end_cmd
  wait_until 5 cmd_is bash
  wait_until 15 row_lacks 'sleep 300'
}

@test "cmd: an idle shell's args stay out of the bar" {
  real_bar
  open_cmd_window
  wait_until 5 cmd_is bash
  attach_observer
  wait_until 15 row_ready
  sleep 2 # a couple of ticks, so the published text has had its chance to show
  [[ "$(obs_row)" != *'--norc'* ]]
}

@test "cmd: argv that looks like a tmux style is drawn, not applied" {
  real_bar
  open_cmd_window "cat - '#[bg=red]'"
  wait_until 5 cmd_is cat
  attach_observer
  wait_until 15 row_ready
  wait_until 15 row_has 'cat - '
  [[ "$(obs_row)" == *'cat - #[bg=red]'* ]]       # the text survives as typed
  [[ "$(obs_esc)" != *$'\033[41m'* ]]             # and painted nothing red
}

@test "cmd: argv that looks like a tmux format is not expanded" {
  real_bar
  open_cmd_window "cat - '#{host}'" # 13 chars: inside the budget
  wait_until 5 cmd_is cat
  attach_observer
  wait_until 15 row_ready
  wait_until 15 row_has 'cat - '
  [[ "$(obs_row)" == *'cat - #{host}'* ]] # not the hostname
}

# --- the tunable wrapper list: @sl_cmd_strip -----------------------------------
# publish tier: the option is read live on every run, so each test sets its own.

@test "strip: the shipped list names the usual wrappers and interpreters" {
  stub_bar
  local re w
  re="$(tmux show-options -gv @sl_cmd_strip)"
  [[ -n $re ]]
  for w in sudo doas env nohup python python3 python3.12; do
    [[ $w =~ $re ]]
  done
  [[ ! sshd =~ $re ]] # whole-word, like @sl_command_ignore
}

@test "strip: a listed wrapper and its flags are dropped from the chip" {
  real_bar
  tmux set -g @sl_cmd_strip '^(sh)$'
  open_cmd_window "sh -c 'sleep 300; :'"
  wait_until 5 cmd_is sh
  run_job
  [[ "$(sl_cmd)" == 'sleep 300; :' ]] # sh and -c are gone
  [[ "$(sl_cmd_for)" == sh ]]         # tmux's name is untouched
}

@test "strip: stripping runs before the path shrink" {
  real_bar
  tmux set -g @sl_cmd_strip '^(cat)$'
  open_cmd_window 'cat - /no/such/dir/f.txt'
  wait_until 5 cmd_is cat
  run_job
  [[ "$(sl_cmd)" == 'f.txt' ]]
}

@test "strip: an empty option turns stripping off" {
  real_bar
  tmux set -g @sl_cmd_strip ''
  open_cmd_window 'cat - /no/such/dir/f.txt'
  wait_until 5 cmd_is cat
  run_job
  [[ "$(sl_cmd)" == 'cat - f.txt' ]]
}

@test "strip: a command that is nothing but wrapper stays visible" {
  real_bar
  tmux set -g @sl_cmd_strip '^(cat)$'
  open_cmd_window 'cat -'
  wait_until 5 cmd_is cat
  run_job
  [[ "$(sl_cmd)" == 'cat -' ]] # never blank
}

# unit tier: _sb_strip is pure (statusbar-lib.bash), so it is sourced directly.

@test "_sb_strip: drops leading wrappers, their flags and env assignments" {
  source "$DIR/../scripts/statusbar-lib.bash"
  local re='^(sudo|doas|nohup|nice|time|command|exec|env|python[0-9.]*)$'
  [[ "$(_sb_strip "$re" 'sudo python3 foo.py')" == 'foo.py' ]]
  [[ "$(_sb_strip "$re" 'sudo -E python3 -u foo.py')" == 'foo.py' ]]
  [[ "$(_sb_strip "$re" '/usr/bin/sudo vim')" == vim ]]
  [[ "$(_sb_strip "$re" 'env FOO=1 BAR=2 node x')" == 'node x' ]]
  [[ "$(_sb_strip "$re" 'python3.12 -m http.server')" == 'http.server' ]]
  [[ "$(_sb_strip "$re" 'sudo nohup python3 x')" == x ]]
}

@test "_sb_strip: only strips from the front, and never to nothing" {
  source "$DIR/../scripts/statusbar-lib.bash"
  local re='^(sudo|env|python[0-9.]*)$'
  [[ "$(_sb_strip "$re" 'make python3 x')" == 'make python3 x' ]] # not a leading word
  [[ "$(_sb_strip "$re" 'vim foo')" == 'vim foo' ]]
  [[ "$(_sb_strip "$re" 'sudo')" == sudo ]]                      # all wrapper: keep it
  [[ "$(_sb_strip "$re" 'sudo -E')" == 'sudo -E' ]]
  [[ "$(_sb_strip '' 'sudo vim')" == 'sudo vim' ]]               # empty regex: off
}
