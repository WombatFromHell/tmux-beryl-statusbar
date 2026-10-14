# DESIGN — tmux-beryl: what each feature does and where it lives

tmux 3.8 (display-popup, list markers, `#{client_width}`). Catppuccin Mocha palette,
Nerd Font glyphs. Every claim names the owning file or the greppable symbol —
name over line number, so this stays true as the files move.

## Layout

| Path | Owns |
|---|---|
| `tmux.conf` | entry point only: sources `conf.d/*` in numeric order |
| `conf.d/01-env.conf` | server `PATH` + `default-shell` discovery (nix / homebrew / linuxbrew / system) |
| `conf.d/02-core.conf` | terminal settings, `status-interval 3`, bell + focus hooks |
| `conf.d/03-keys.conf` | leader `C-s`, keybindings, F12 autolock, daemon start |
| `conf.d/04-statusbar.conf` | palette, `@sl_*` blocks, `status-left`, `status-format[0]`, `status-right` |
| `conf.d/05-floax.conf` | the floax popup session and its tab-bar hooks |
| `scripts/statusbar.sh` | the `status-right` job: pacing, pull, compose, publish the width budget |
| `scripts/statusbar-lib.bash` | pure parse/compute: GPU providers, CPU/RAM math, parsers, block composer |
| `scripts/autolock.sh` | the lock state: daemon, poll, F12 toggle, `lock`/`unlock` |
| `scripts/autolock-lib.bash` | pure decision layer: `matches_locked` / `auto_desired` / `decide` |
| `scripts/lockchip.sh` | `status-left` job: emits the lock glyph when locked |
| `scripts/bell.sh` | the per-window `@bell` flag and the sound |
| `scripts/_env.bash` | the PATH tail every `#()` child shares (sourced by the three jobs) |
| `helpers/capture-bar.sh` | the eyeball harness: one bar row per client width, not a gate |
| `tests/` | bats suite — the gate (see Testing) |

## 1. Config layering and PATH

`tmux.conf` sources the five modules in order; order matters: `01` sets the server
environment before `04` composes the bar, and `03` starts the autolock daemon after
its bindings exist. Each module is one section, self-contained.

PATH is resolved in two layers, because the two consumers are different:

- `01-env.conf` prepends discovered bin dirs to the **server's** env
  (`set-environment -g PATH`), so panes and hooks resolve tools.
- `scripts/_env.bash` appends the standard bins inside each `#()` child, whose
  env comes from the server and can be minimal when tmux started from a
  non-login context. One file, sourced by `statusbar.sh`, `lockchip.sh`,
  `autolock.sh` — the triplicate line it replaces lives here once.

## 2. Keys and the leader

Leader is `C-s` (`set -g prefix C-s`). `<leader>r` reloads the config and runs
`bell.sh clear` so stale dots don't survive a reload. Splits (`v s | -`) and
new windows (`c`) inherit `#{pane_current_path}`; `<` / `>` swap windows.
Vi-mode copy uses `#{@copycmd}` (`wl-copy` → `pbcopy` → `xclip`) through
`copy-pipe-and-cancel`, because popups drop OSC 52 (tmux#4797) and the server
can still reach the system clipboard. Selection is `v`, commit is `y` (and mouse
release), both through the same `#{@copycmd}`; `PageUp`/`PageDown` and `C-u`/`C-d`
scroll copy mode. Navigation without the leader: alt-arrows,
`C-M-hjkl` (forces past vim's own hjkl), `M-h`/`M-l` for windows, `M-HJKL` to resize.
`F12` calls `autolock.sh toggle` from both the normal and the `off` key-table.

## 3. Status bar

Two `#()` jobs, one per side: `status-left` runs `lockchip.sh`, `status-right`
runs `statusbar.sh '#{session_name}' '#{client_width}'`. The arguments exist
because `#{client_width}` is only populated inside a draw expansion, and the
job's own current session is the **client's**, not the drawn one when an
observer is attached — so window queries must name the drawn session and the
width must come from the expansion.

`status-left` is the lock glyph plus two chips: `@sl_session` (teal, the session
name, with the `#()` lock job at its top level) and `@sl_command`, the foreground
procname, hidden when it matches `@sl_command_ignore` (`^(bash|zsh|fish|tmux)$`)
— a shell or tmux itself is noise, a real command is not. `run-shell` composes
the two into `status-left` at load, because `set -g` would store the `#{@sl_*}`
names instead of their values.

tmux spawns `#()` children on status ticks **and** on job-completion redraws,
which is back-to-back, so the script enforces "no pull faster than
`status-interval`":

- State file `${TMUX_TMPDIR:-/tmp}/sb-state`: line 1 = last pull claim (epoch s),
  line 2 = last composed output. Written atomically (`>file.$$` then `mv`).
- The renderer never waits: it emits the cached output, and if
  `now - claim >= interval` it claims the slot first (so a concurrent spawn
  won't double-fetch), then runs `_sb_fetch` detached with stdio and the lock
  fd closed so tmux sees the job exit immediately. `_sb_fetch` pulls metrics,
  rewrites state, and `refresh-client -S` asks for the redraw that shows them.
- `_sb_interval` reads `status-interval` live (the conf stays the source of
  truth, runtime changes are followed); `_sb_lock` is an exclusive `flock` so
  the tick spawn and the completion redraw serialize.

Composition is split so it is testable without tmux:

- `statusbar-lib.bash` is tmux-free — every function takes its input (a tool's
  raw output or a `/proc` snapshot) and fills the gpu/vram/cpu/ram globals.
  GPU provider precedence NVIDIA → AMD → Intel dGPU → Intel iGPU; a provider
  that reports nothing returns 1 and the bar hides that block. CPU/RAM are pure
  math (`cpu_delta`, `ram_pct`); the Darwin path feeds `cpu_darwin`/`ram_darwin`
  the raw `top -l 2` and `vm_stat` output (`ram_darwin` also takes `hw.memsize`).
  Battery: `batt_linux`/`batt_darwin` read the percentage and state, `_batt_is_ac`
  decides the charging icon, `_batt_icon` picks a tiered level glyph otherwise.
  Drivers that report `Unknown` while plugged in are settled by `_ac_online`, which
  reads the AC adapter's `online` file.
- `_tout` wraps every GPU probe in `timeout` (`gtimeout` on macOS, run bare when
  neither exists), so a hung vendor tool cannot stall a draw.
- `compose_metrics` emits one chip per metric (`_sb_chip`, plus `_sb_batt` for the
  battery), hidden blocks emit zero characters, so gaps never double up.
- The palette has one owner: `04-statusbar.conf` sets `@c_*`, `statusbar.sh`
  reads them in a single `tmux display` call (`_sb_opts`), the library takes
  them as inputs. Same for `@clock-format` (`_sb_clock_fmt` maps 12/24). The palette
  also pins the chrome outside the bar: `message-style`, `mode-style`,
  `pane-active-border-style` (teal marks the selected pane), `pane-border-style`,
  `popup-style`, `popup-border-style`.
- The time block (calendar + clock) is composed in the script, since it is
  static per pull; `date` is read by the consumer, never by the library, so the
  block stays fixture-testable.

The width budget is the subtle part. tmux cannot expand a width argument inside
`#{=…/…}` from an option, so the active chip's title field is a **published
integer**: `statusbar.sh` computes `@sl_tw` = client width minus everything else
the bar draws, and `04-statusbar.conf` uses `#{E:@sl_tw}` as a **truncation limit
only**: a title longer than the field is middle-cut, and tmux's own fill takes the
leftover space in the bar's colour. Inputs are measured, not hand-counted:
`_sb_out_w` uses tmux's own `#{w:}` primitive (it strips `#[…]` markers, which
`wc -m` cannot, and already counts the private-use Nerd Font glyphs as one cell
each). `@sl_tw` is server-global — the last-drawn client wins the field; `0` means
"no room for a title" and the conf's guard drops the whole title group, because
`0` in a truncation term would read as "no limit"; `_sb_sl_tw` publishes `0` under
4 cells, since a shorter title is a fragment, and leaves `@sl_tw` at its current
value (the shipped `32` before the first draw) when there is no client width or no
windows to measure.

## 4. Autolock

The lock state **is** tmux state: locked = `prefix None` + `key-table off`.
`unlock` restores the saved `@autolock_prefix` rather than `set -gu`, because
unset reverts to tmux's compiled-in default (`C-b`), not the conf's `C-s`.

- `lock`/`unlock` in `autolock.sh` are the only place those options are touched,
  so the F12 path and the daemon can never drift apart. `lockchip.sh` asks
  `autolock.sh locked` — one owner, no duplicated predicate.
- `autolock-lib.bash` owns the decision: `decide LOCKED_PROCS FG LOCKED OVERRIDE`
  → `lock`/`unlock`/`noop`, with the manual override taking priority over
  `auto_desired`. `matches_locked` is a full-string match, so `sshd` does not
  match `ssh`.
- The daemon: `autolock.sh start` polls every `INTERVAL_MS` (1s); the pidfile
  makes it idempotent across config reloads and server restarts, and a stale
  pidfile self-heals when its process is gone. `03-keys.conf` starts it at load.
- `F12` (`toggle`) flips the state and arms `@autolock_override` (`lock`|`unlock`),
  which the poll honors while a locked proc is foreground; the override is
  cleared once the auto state agrees with it, so a fresh matched proc re-asserts
  auto behaviour.
- `with_lock` (`flock`) serializes `poll` and `toggle`, whose read-modify-write
  of the lock state must not interleave.
- `LOCKED_PROCS` defaults to `ssh|fzf`; env-overridable for tests.

## 5. Bell notifications

`monitor-bell on` + `bell-action any` + `visual-bell off`, and the `alert-bell`
hook delegates everything to `bell.sh`, which is the single owner of the
per-window `@bell` flag: it plays a sound (`paplay`, else `afplay`) and arms that
window's dot. The floax session gets a global `@floax_bell` instead, because it
is not in the tab list. One dot per tab per period: `@bell` is a boolean, so a
second bell in the same period cannot re-arm it.

Acknowledgement clears it: selecting a window (`session-window-changed` →
`bell.sh ack`), the terminal regaining focus (`client-focus-in` → `bell.sh ack`),
and `<leader>r` (`bell.sh clear`). `@term_focused` tracks focus, ignoring the
floax popup's own client, so `bell.sh` does nothing when you are already looking
at the window that rang. `04-statusbar.conf` draws the dot as `@sl_tab_bell`,
referenced once per chip branch so the styling lives in one place.

## 6. floax floating pane

`M-p` toggles the popup: from inside floax it detaches the client (the session
persists), otherwise it ensures the session exists, clears `@floax_bell`, and opens
a `display-popup` at 80% x 80% with a rounded border, running a nested
`tmux attach-session -t floax`. The nested client renders the persistent `floax`
session's status bar, which is the tab bar. A `session-created` hook clears that
session's own `status-left`/`status-right` so only the tab bar shows. The bar is
shown only while floax has more than one window — `window-linked`/`window-unlinked`
hooks flip `set -t floax status on|off` (both run after the window list updates, and
`window-closed` is avoided because it is master-only).

Tabs are keyboard-driven, deliberately: the popup pane is flagged
`PANE_CAPTUREALLKEYS`, which forwards non-mouse keys into the nested client but
never mouse keys, so `#[range=window|…]` clicks cannot switch floax windows.
`M-h`/`M-l` do reach the nested client and move its active window; the tab bar
is the visual indicator of which one is active.

## 7. Terminal defaults (`02-core.conf`)

`escape-time 0` and `extended-keys` in `csi-u` form send whole escape sequences to
the outer terminal; `allow-passthrough on` lets sequences tmux cannot parse reach it
untouched; `set-clipboard on` lets tmux write the clipboard over OSC 52. Windows and
panes are 1-based and renumbered on close; `history-limit` is 100000, `display-time
4000` keeps a message up for four seconds, `mouse on`, `window-size latest` with
`aggressive-resize`. The bar sits at `status-position top`, and
`status-left-length 100` / `status-right-length 120` are the truncation limits
`status-format[0]` applies to each side. Titles: `set-titles on` with
`set-titles-string "#{session_name}:#{window_index} #T"`, and windows auto-rename
from `#{pane_title}`, so the OS window title tracks the selected pane and the tab
chip reads the same string.

## Data flow

```
tmux tick (status-interval 3s)
  └─ expands #{session_name} / #{client_width} into the status-right job text
     └─ statusbar.sh: emit cached output + publish @sl_tw   (never waits)
        └─ if now - claim >= interval: claim, then detached _sb_fetch
           └─ pull metrics → rewrite state → refresh-client -S → redraw with metrics
autolock daemon (1s) ─ decide() ─ lock/unlock ─→ lockchip.sh reads it on the next draw
bell hook ─ bell.sh ─→ @bell / @floax_bell ─→ next draw shows the dot
```

## Invariants the suite enforces

| Invariant | Owner | Proven by |
|---|---|---|
| `#()` output is one line, one `%`, no `#{}` | `statusbar.sh` header contract | e2e "attached client renders the composed status-right" |
| at most one pull per `status-interval` | `_sb_interval`, `_sb_lock`, claim-first | e2e "data pulls paced at >= status-interval" |
| hidden blocks emit zero characters | `compose_metrics`, `_sb_chip` | unit "compose: table — hidden blocks emit zero chars" |
| the row fills the client and never overflows | `_sb_sl_tw` + `@sl_windows_fmt` | e2e budget / locked-leader / resize / narrow-client tests |
| the lock state has one owner | `autolock.sh` `lock`/`unlock` | autolock-e2e tests 1–3, lockchip tests |
| `0` in a truncation term means "no limit" | guard in `@sl_windows_fmt` | e2e "a client narrower than the budget drops the active title" |

## Testing

Two tiers, both driven from `tests/test_helper.bash`, which owns the isolation:
a private socket dir and a scratch `HOME` holding the shipped conf, so the real
server and the user's dotfiles are unreachable.

- **unit** — sources `*-lib.bash` and feeds fixtures; no tmux, no I/O
  (`statusbar-unit-test.bats`, `autolock-unit-test.bats`).
- **e2e** — a real tmux server on the shipped conf, an attached observer client,
  and rendered-row assertions (`statusbar-e2e-test.bats`,
  `statusbar-tablist-test.bats`, `autolock-e2e-test.bats`, `floax-test.bats`).

`bats tests/*.bats` is the gate. Convergence waits poll through the helper's
`wait_until`; `stable_row` (defined in `statusbar-e2e-test.bats`, not the helper)
waits for two identical draws before asserting. The remaining `sleep`s are fixtures
(`sleep 60` as the locked proc) and the pacing test's observation loop.
`helpers/capture-bar.sh` renders the bar at several widths into a file for eyeballing;
it is a helper, not a gate, and nothing in `tests/` runs it.

## Ceilings (deliberate — do not "fix" without a test showing drift)

- `@sl_tw` is server-global and `client_width` is per-client: the last-drawn
  client wins the field, others show tmux's `< >` markers.
- `#{w:}` counts the private-use Nerd Font glyphs as one cell each (tmux 3.8);
  `_sb_out_w` measures with it unchanged.
- `flock` is absent on stock macOS, so `statusbar.sh` may rarely do double work.
- The Darwin parsers and the Intel iGPU provider are live code (the owner runs
  macOS on an Intel iGPU) — they are not dead code to delete.

## Docs map

- `DESIGN.md` (this file) is the current truth for names and mechanisms.
- `helpers/capture-bar.sh` is the eyeball harness. It prints one bar row per client
  width, so a before/after pair of its output can be diffed; nothing in `tests/`
  reads it.
- `.pi/` is scratch for the plan gate. It does not survive refactors and is not
  project truth, so nothing here cites it. The smart-width ticket names that used
  to live there (`@fixed_w`, `@sr_w`, `tabwidth.sh`, `#{p<N>:…}`) are gone; the live
  spellings are `@sl_tw` and `_sb_sl_tw`.
