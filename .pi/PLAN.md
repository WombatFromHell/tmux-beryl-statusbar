# PLAN — degraded on-tick "grow-to-fill" tab chip

## Goal
Make the active tab's title fill the free space in the window-list, updating on
each status tick / tab switch / bell. **Not** live-resize (impossible on tmux 3.8
— see `.pi/FINDINGS.md`). This is the degraded on-tick version the user selected.

## Mechanism (forced by tmux 3.8)
`#{p...}` / `#{=N/...}` only accept a **literal** integer width, and
`#{client_width}` is only known at draw time. So the width cannot be a format
expression. A script computes `title_w = max(client_width − @fixed_w, 8)` and
**bakes a literal integer** into `@sl_windows_fmt`. The script owns the format
template (single source of truth); the conf only invokes the script.

## Files
- `scripts/tabwidth.sh`        (new) — compute `@fixed_w` + `title_w`, rewrite `@sl_windows_fmt`
- `scripts/statusbar.sh`       — publish `@sr_w`, call `tabwidth.sh` each tick
- `conf.d/04-statusbar.conf`   — stop defining `@sl_windows_fmt` inline; invoke script
- `conf.d/02-core.conf`        — tab-switch / bell hooks call `tabwidth.sh`
- `conf.d/05-floax.conf`       — floax keeps a **fixed-width** `@sl_windows_fmt` (per-session)
- `tests/statusbar-tablist-test.bats` — add smart-width tests

## Vertical slices (TDD: failing test first, then implement)

### Slice 1 — `tabwidth.sh` core
- **Test (red):** scratch server + real client; after running `tabwidth.sh`,
  `@sl_windows_fmt` contains a literal `p<N>` / `=/<N>/` with N > 8, and the
  rendered active chip is exactly N visible columns wide (styles stripped).
- **Impl:**
  - `vw()` visible-width helper (strip `#[...]`, `wc -m`).
  - `l = vw(#{status-left})`; `r = @sr_w` (default 0); `tabs = awk` sum
    (co-agent's per-tab chrome constants, verified correct).
  - `@fixed_w = l + r + tabs + N` — **N tuned in Slice 5** (covers the 2 literal
    spaces + the `<` `>` markers between the blocks and the list).
  - `cw = tmux list-clients -F '#{client_width}' | sort -n | tail -1`
    (max width = the main client).
  - `title_w = max(cw − @fixed_w, 8)`.
  - Build `@sl_windows_fmt` template with `#{p${title_w}:...}` /
    `#{=/${title_w}/...}` (active title only; inactive chips unchanged);
    `tmux set -g @sl_windows_fmt "$fmt"`.
  - `ponytail:` global `@fixed_w` + max-width picks the main client; the narrower
    floax client is handled in Slice 3, not here.

### Slice 2 — `statusbar.sh` publishes `@sr_w` + calls `tabwidth.sh`
- **Test (red):** after a status tick, `@sr_w` is a positive integer and
  `@sl_windows_fmt`'s width tracks the client width.
- **Impl:** end of `statusbar.sh`: `tmux set -g @sr_w "$(vw "$out")"`; call
  `tabwidth.sh`; then `printf '%s' "$out"`.

### Slice 3 — conf wiring
- **Test (red):** conf loads; before any tick, `@sl_windows_fmt` is a valid
  literal (width 8, no `%%W%%` garbage); tab-switch fires `tabwidth.sh`.
- **Impl:**
  - `04-statusbar.conf`: remove the inline `@sl_windows_fmt`; add
    `run-shell 'bash ~/.config/tmux/scripts/tabwidth.sh'` (sets initial width 8).
  - `02-core.conf`: `session-window-changed` + `alert-bell` hooks call
    `tabwidth.sh`.

### Slice 4 — floax keeps a fixed width (per-session)
- **Test (red):** the floax session's `@sl_windows_fmt` is a fixed 32-char
  format, independent of the main bar's smart width.
- **Impl:** `05-floax.conf` sets `@sl_windows_fmt` **per-session** on `floax` to
  the fixed 32-char format, so the floax tab bar is unaffected by the main bar's
  smart width (session overrides global).

### Slice 5 — tune + full regression
- Run the bats suite (tablist, e2e, golden_bar, unit). Tune the `+ N` constant
  until the rendered active chip **exactly** fills the free space (no wrap / clip).
- Confirm `tests/golden_bar.txt` still matches (floax fixed-width path unchanged).
- Confirm existing `statusbar-tablist-test.bats` cases still pass (no regression).

## Out of scope (YAGNI)
- Live-resize (impossible on 3.8).
- Per-client smart width for floax (fixed width suffices; revisit only if needed).
- Reordering the bell dot (kept after the padding, per the co-agent layout).
