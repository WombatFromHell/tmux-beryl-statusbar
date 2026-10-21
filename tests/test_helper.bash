# test_helper.bash — shared scratch-tmux harness for the bats suites.
#
# Isolation: every test gets its own $T holding the socket, HOME and
# TMUX_TMPDIR; TMUX/TMUX_PANE are unset; the `tmux` wrapper is the ONLY door
# to tmux and always passes -S "$SOCK", so a real server is unreachable.
# The socket sits at the *default* path inside the private TMUX_TMPDIR, so a
# nested bare `tmux attach` (the floax popup path) finds this server too.

ensure_tmp() { [[ -n ${T:-} ]] || T="$(mktemp -d /tmp/tt-XXXXXX)"; }

tmux() {
  [[ -n ${SOCK:-} ]] || {
    echo "refusing to run tmux: no scratch socket" >&2
    return 99
  }
  "$REAL_TMUX" -f /dev/null -S "$SOCK" "$@"
}

start_server() {
  unset TMUX TMUX_PANE
  REAL_TMUX="$(type -P tmux)"
  ensure_tmp
  export TMUX_TMPDIR="$T" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"
  SOCK="$T/tmux-$(id -u)/default"
  mkdir -p -m 700 "${SOCK%/*}"
  mkdir -p "$HOME" # tmux rejects non-700 socket dirs
  # Start the server in a subshell with extra FDs closed so the
  # daemonized server does not inherit the bats pipes (which would
  # keep the pipe open and deadlock bats in do_wait after the last test).
  (
    exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 2>/dev/null
    tmux new-session -d -s base
  ) </dev/null
}

# Server start for the integration/E2E tiers. (The old $T/bin link_tools line
# is gone: no integration/E2E test puts $T/bin on PATH — only unit-tier
# call_gpu does, via init_unit_bin in the unit test file.)
stop_scratch_server() {
  # kill-server can fail (server already gone); never let that skip the rm.
  if [[ -n ${SOCK:-} ]]; then tmux kill-server </dev/null 2>/dev/null || true; fi
  if [[ -n ${T:-} ]]; then
    # The dying fish shell can mkdir its cache dirs back into $T a few ms
    # after kill-server; retry briefly until the tree is actually gone.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      rm -rf "$T" 2>/dev/null
      [[ -e $T ]] || break
      sleep 0.05
    done
  fi
  return 0
}

wait_until() { # seconds cmd [args...] — poll instead of sleeping
  local n=$(($1 * 20)) i
  shift
  for ((i = 0; i < n; i++)); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}

# open_cmd_window [CMD...] — a window whose tty's foreground job is CMD, made
# the active window of `base`, with no client attached: tmux refuses send-keys
# on a conf-sourced scratch server, and typing would depend on tmux's default
# shell parsing the line. The generated runner runs CMD as a job of an
# interactive bash (`-i` gives it job control whatever that shell is) and `fg`s
# it, so the job owns the tty exactly like a command typed at a prompt: its
# pgid is the tty's tpgid, which is what tmux's pane_current_command keys on.
# Arguments are joined and embedded verbatim, so argv is what typing would
# give; no arguments = an idle bash. end_cmd ends the recorded job, after which
# the runner exec's an idle bash again.
open_cmd_window() {
  ensure_tmp
  if (($#)); then
    printf '#!/bin/bash\n%s &\nprintf "%%s\n" "$!" >"%s"\nfg %%1\nexec bash --norc --noprofile\n' \
      "$*" "$T/job.pid" >"$T/rc.sh"
  else
    printf '#!/bin/bash\nexec bash --norc --noprofile\n' >"$T/rc.sh"
  fi
  chmod +x "$T/rc.sh"
  CMD_WIN=$(tmux new-window -d -P -F '#{window_id}' -n cmd "bash --norc --noprofile -i '$T/rc.sh'")
  tmux select-window -t "$CMD_WIN"
}
# end_cmd — end the foreground job; the runner then exec's the idle bash.
end_cmd() { kill "$(cat "$T/job.pid")" 2>/dev/null; }

# Load the real tmux.conf into the scratch server. Copied into $T so ~ and
# #{d:current_file} resolve there, never to the user's dotfiles. The main
# conf sources conf.d/*.conf from ~, so those must land in the scratch HOME too.
load_conf() {
  ensure_tmp

  mkdir -p "$HOME/.config/tmux/scripts"
  printf '#!/bin/sh\nexit 0\n' >"$HOME/.config/tmux/scripts/statusbar.sh"
  chmod +x "$HOME/.config/tmux/scripts/statusbar.sh"

  cp "$BATS_TEST_DIRNAME/../tmux.conf" "$T/tmux.conf" &&
    cp -r "$BATS_TEST_DIRNAME/../conf.d" "$HOME/.config/tmux/" &&
    tmux source-file "$T/tmux.conf"
}

# load_real_script — swap the stub statusbar for the real one (plus the lockchip
# / autolock chain the conf's status-left runs) in the scratch HOME.
load_real_script() {
  cp "$BATS_TEST_DIRNAME/../scripts/"{statusbar.sh,statusbar-lib.bash,lockchip.sh,autolock.sh,autolock-lib.bash,_env.bash} \
    "$HOME/.config/tmux/scripts/"
  chmod +x "$HOME/.config/tmux/scripts"/*.sh
}

# stub_bar / real_bar — the two shared preambles: an isolated server carrying
# the shipped conf, with the stub or the real statusbar. Tests that watch the
# drawn bar add attach_observer on top.
stub_bar() {
  start_server
  load_conf
}

# real_bar — the shipped conf plus the real statusbar chain. The redraw tick is
# cut to 1s so the convergence waits poll a short cycle instead of waiting out
# the shipped 3s (02-core.conf); the pacing test sets its own interval on top,
# so no test asserts a cadence the shipped config does not already own.
real_bar() {
  stub_bar
  load_real_script
  tmux set -g status-interval 1
}

# make_mock NAME CONTENT -> executable in $T/mock, without overwriting other mocks.
make_mock() {
  ensure_tmp
  mkdir -p "$T/mock"
  rm -f "$T/mock/$1" # never write through a symlink to a real binary
  printf '%s' "$2" >"$T/mock/$1"
  chmod +x "$T/mock/$1"
}

# link_tools DIR tool... — symlink the real tools that exist; silently skip the
# rest (jq/flock/timeout are absent on stock macOS).
link_tools() {
  local dir=$1 t p
  shift
  for t in "$@"; do p="$(type -P "$t")" && ln -sf "$p" "$dir/$t"; done
  return 0
}
