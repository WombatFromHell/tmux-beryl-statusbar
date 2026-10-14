# REVIEW — Smart tab-title width (tmux 3.8)

## Outcome
The active tab's title now spans **exactly** the free width of the status line
(`client_width − everything else`), adapting to window-list and client-width
changes every tick. Inactive chips are unchanged (compact, index-only).

## Mechanism
tmux 3.8 **cannot** expand a width argument in `#{p}`/`#{=}` (verified:
`#{p#{@tw}:x}` renders the literal `p12:x`; `#{=…/#{@tw}/…}` renders nothing),
and `#{client_width}` is only populated in a draw context. So the active title
width must be a **literal integer** baked into `@sl_windows_fmt` on every tick.

- `scripts/tabwidth.sh` **owns** the `@sl_windows_fmt` template (single source
  of truth). Each run:
  1. `l` = visible width of `status-left` (its `#()` jobs expand here).
  2. `r` = `@sr_w` (published by `statusbar.sh`).
  3. `tabs` = sum of per-tab chrome (active = 5 + bell, inactive = 3 + bell,
     1-digit index).
  4. `@fixed_w = l + r + tabs + 5` (the 5 literal gaps: space, `<`, space,
     `>`, space).
  5. `title_w = max(widest client_width − @fixed_w, 8)`.
  6. Bake `title_w` into `@sl_windows_fmt` (`#{p<N>:…}` + `#{=/N/…}`).
- `scripts/statusbar.sh` publishes `@sr_w` (the right block's visible width)
  and calls `tabwidth.sh` each tick, before the bar draws.
- `conf.d/04-statusbar.conf` sets `@sl_windows_fmt` to the template with a
  `p32` placeholder, so the first draw is styled; the script re-bakes the real
  width on the first tick.

## Empirical grounding (tmux 3.8, real attached client)
- `#{p#{@tw}:X}` → literal `p12:X` (no expansion). `#{=…/#{@tw}/…:…}` → empty.
  ⇒ width argument must be a literal integer.
- `#{client_width}` in `list-clients -F` → `0` (no real TTY in sandbox); in a
  real attached client → the true width.
- Chrome measured from the rendered bar: 1 active tab (no bell) = **5**;
  active + inactive = **8** ⇒ inactive = **3**. (The prior awk's constants were
  swapped; the prior `length($0)` counted the number's digits, not its value.)

## Slices (TDD)
1. **`tabwidth.sh`** — new script; bats `smart-width` test (red → green).
2. **`statusbar.sh`** — publishes `@sr_w`, calls `tabwidth.sh` pre-draw.
3. **Initial `run-shell`** — *skipped* (no client on load ⇒ bakes the 8-min;
   the first tick bakes the real width).
4. **`04-statusbar.conf`** — `@sl_windows_fmt` active title wrapped in
   `#{p32:…}` (placeholder).
5. **E2E rendered-width** — *folded into* Slice 1's test (real client + full
   conf).

## Tests
- `tests/statusbar-tablist-test.bats` → `smart-width` (new): real client (w200),
  `tabwidth.sh` bakes a literal `p<N>` in `8..199`.
- Full suite: **all green** (88 tests).

## Known limitations (ponytail ceilings)
- **1-digit tab index** assumed (10+ tabs add 1 chrome char each — untested;
  personal config, rarely >9 tabs).
- **Widest client** = main bar; the narrower floax client is fixed-width via
  `conf.d/05-floax.conf` (per-session `@sl_windows_fmt`), not by this script.
- **DRY note**: the `@sl_windows_fmt` template lives in both the conf
  (placeholder `p32`) and `tabwidth.sh` (owned). The conf copy is only the
  initial value, overwritten by the script on the first tick.
