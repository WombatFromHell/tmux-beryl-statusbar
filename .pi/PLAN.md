# PLAN — grow-to-fill active tab chip (ticket ledger)

**Status**: Active · **Branch**: trunk (personal dotfile repo, no feature branches)
**Goal**: the active window's chip background fills the free space between the
left chip and the right block, at **any client width**, without ever clipping
window indexes out of the bar.

Grounding: `.pi/FINDINGS.md` (round 1 = the mechanism, round 2 = what the budget
is made of). Do not re-derive either here.

## Owner-approved decisions (2025 session)

1. **Lock chip**: `lockchip.sh` publishes its own visible width as `@lc_w`;
   `statusbar.sh` adds it. Each variable part owns its own width — no path
   knowledge and no duplicated lock logic in the bar script.
2. **Unknown-width fallback**: `TW = fixed_w ? max(1, client_width − fixed_w) : 32`
   — the shipped 32-col field is the fallback when the budget is unpublished
   (no attached client at `display -p`, or the first draw before the job runs).
3. **Delivery**: one ticket = one landing; the **full bats suite is green after
   every ticket** (plus the sweep pair). Revertible checkpoints.

## Acceptance criteria (observable, behaviour-driven)

- [x] A bar drawn with no attached client truncates the active title at 32 cols, one `…`, trailing margin (tablist tier, no sleeps).
- [ ] `@sl_tw` equals the columns the bar actually draws besides the active title field — verified against a rendered sweep row, and the chrome half of it is **measured** (`#{w:#{E:@sl_windows_fmt}}`), not a formula.
- [ ] Locked and unlocked sweep rows are both flush (pad abuts the right block) — the lock glyph costs 3 cols and must not leave a gap.
- [ ] Pad abuts the right block at 1 / 3 / 5 windows and with bells on/off.
- [ ] Pad abuts the right block with the stub script (metrics hidden) — the right block's variable width is in the budget.
- [ ] Resizing one observer 200 → 140 → 90 keeps the pad flush at each width, no window index disappears.
- [ ] The floax popup's nested client shows its inactive window index (` 2`).
- [ ] A client narrower than the budget clips the **tail** only — no zero/negative-width artefacts (`berly`-style garbage).

## Ticket ledger

Work top to bottom; each ticket leaves the suite green. T1 and T7 are the two
tests already red on `main` — they are the acceptance gates, not new oracles.

| # | Ticket | Class | Gate |
|---|---|---|---|
| T0 | The sweep harness prints one bar row per client width. | pure refactor (harness) | sweep files gain 3 rows |
| T1 | A bar with no attached client truncates the active title at the shipped 32-col field. | behaviour change | `statusbar-tablist-test.bats` #4 (red now) |
| T2 | The published budget counts the **rendered** left block, not the option text. | re-pin (side effect of T5) | `statusbar.sh:96` measures it in cells |
| T3 | The lock glyph's width is inside the budget when the leader is locked. | verification (no mechanism — the pad absorbs it) | new e2e test 9, locked via `prefix None` |
| T4 | The window-list chrome is **measured** from the format, not derived term by term. | behaviour change | new: sweep flush at 1/3/5 windows |
| T5 | The right block's variable width is inside the budget. | verification (test-only) | new: stub-script sweep row is flush |
| T6 | A resize keeps the pad flush at every width. | verification (test-only) | new e2e test 10 (`resize-window -x/-y`) |
| T7 | The floax popup's nested client keeps its inactive window index visible. | re-pin (green since T1) | `floax-test.bats` #7 (red on `main`, green from T1) |
| T8 | A client narrower than the budget clips the tail, not the indexes. | behaviour change | new: 40-col client renders sanely |

**Landed**: T0 (`9e6226f`), T1 (`a12f2e8`), T4+T5 (`eac6c19`). Suite after
`eac6c19`: 88 unit + 8 e2e green, 0 failures. T2 landed as a side effect of T5
(re-pin), T3 needs no mechanism (the pad absorbs the lockchip — probe67), T6's
gate is green as a side effect. Open: T7 re-pin, T8 gate.

### T0 — the sweep harness prints one bar row per client width

**Value**: the before/after artifact can show the bar at 200/140/90, which is
the evidence every later ticket is judged against. **Horizontal exception**
(harness fix): it unlocks T1–T8's verification, is smaller than folding it into
any behaviour ticket, and is itself verified by its output.
**Path**: `.pi/capture-bar.sh` → observer client → `resize-window` + `refresh-client -S` → `capture-pane` row 1 → golden file.
**Baseline (red today)**: `.pi/golden-{pre,post}-sweep.txt` contain headers only — `set -euo pipefail` + `ready && break` returns non-zero and exits the script before `sweep` runs.
**GREEN change**: one line — `until ready; do sleep 0.25; done` (and the stub-loop equivalent). No behaviour change.
**Done**: both sweep files carry `## width 200/140/90` sections with a non-empty bar row and the `fixed_w:` line.
**PR-ready when**: the pair renders; commit needs owner approval.

### T1 — a bar with no attached client truncates the active title at 32 cols

**Value**: the fast integration tier (`tmux display -p -F '#{E:@sl_windows_fmt}'`, no client) and the very first real draw keep the shipped 32-col field, so the double-ellipsis oracle stays meaningful and the first draw never clips.
**Path**: `conf.d/04-statusbar.conf` → `@sl_tw` → `@sl_windows_fmt` truncate + pad.
**RED**: `tests/statusbar-tablist-test.bats` #4 — `wait`-free, asserts `'/v/m/d/u/j/s/overlay/0a7ad04db0… '` (32-col margin + single `…`); fails today because `#{=/0/:x}` renders the whole title.
**GREEN change** (conf only):
1. define the field once: `set -g @sl_tw "#{?#{@fixed_w},#{e|max:1,#{e|-:#{client_width},#{@fixed_w}}},32}"`
2. active branch uses `#{=/#{E:@sl_tw}/…:pane_title}` and pad `#{R: ,#{e|-:#{E:@sl_tw},#{w:pane_title}}}` (the TW expression appears once in the conf instead of three times).
**REFACTOR**: none beyond the above.
**Side effect to confirm**: `floax-test.bats` #7 goes green here (`@fixed_w` 0 ⇒ fallback 32 ⇒ no clipping) — if it does, T7 becomes a *re-pin* ticket, not a fix ticket; record which.
**Confirmed at T1 landing**: floax #7 went green with T1 (fallback 32, budget inert). T7 is therefore a **re-pin** ticket — it must stay green once T2 publishes a real budget, which is where the narrow-client budget/width interaction is actually at stake.
**Done**: full suite green; sweep rows show a 32-col field with `fixed_w: 0`.

### T2 — the budget counts the rendered left block

**Value**: `@sl_tw` stops over-counting ~40 phantom columns, which is what pushed the floax popup's indexes off the bar.
**Path**: `scripts/statusbar.sh` `_sb_sl_tw` → `tmux display -p '#{E:status-left}'` fed through `_sb_out_w` (cells, T5) → publish.
**RED**: new test — publish `@sl_tw` for a known 3-window config, then assert it equals the hand-counted terms from a sweep row (left chip ends col 17, right block 34, chrome from T4). Assert against the *rendered row*, never against a formula duplicated in the test.
**GREEN change**: replace `tmux show -p status-left` + `_sb_visible` with the single `#{E:status-left}` read; `_sb_visible` becomes unused → delete it (ponytail: no dead helper).
**Done**: landed as a side effect of T5 (`statusbar.sh:96` measures the left block in cells); no separate ticket code. **Caveat that keeps T3 honest**: `#{w:}` renders `#()` jobs as **zero width** (probe54: a status-right that is only a job measures 0), so "rendered" here excludes the lockchip — see T3.

### T3 — the lock glyph is inside the budget

**Value**: with the leader locked (`prefix None`) the pad still abuts the right block instead of leaving a 3-col gap.
**Path**: `tests/statusbar-e2e-test.bats` — `set -g prefix None` is exactly what `lockchip.sh`'s `_is_locked` tests, so locking is drivable headlessly; redraw, then the flush oracle.
**RED**: new test; the left block's term excludes the job (T2's caveat), so the naive expectation is a 3-col shortfall.
**GREEN change**: **none — the mechanism is unnecessary.** The lockchip's 3 cells land in the same section as the pad, and the pad absorbs them: probe67 held the row flush and marker-free, locked, at 200/120/90/70 (`@sl_tw` 135/55/25/5), and `@sl_tw` is identical locked vs unlocked. The `@lc_w` publish the old plan proposed is deleted before it is written; the stale comment in `statusbar.sh` saying the lockchip is "a separate term" is corrected to name the pad.
**Done**: green e2e test (test 9), which is only meaningful because `load_real_script` now copies `lockchip.sh` — without it the job fails and the claim is vacuous (that is the test-harness bug this ticket found).

### T4 — the window-list chrome's terms are measured in cells, not hand-counted

**Value**: the bar is flush at any window count and bell state. Round 3's route
A (measure the composed format) is **falsified** — probe42/43: `list-windows
-F` evaluates per window and a nested `#{E:…}` inside it resolves in the
command's pane, so `#{w:#{E:@sl_windows_fmt}}` returns one chip (160,160,160),
never the list. The chrome therefore stays a term list; what must not be
hand-counted is the **unit** and the **per-window fields**.
**Path**: `scripts/statusbar.sh` `_sb_sl_tw` → one `list-windows -F` call with
`|`-separated fields (`#{window_index}|#{@bell}|#{window_active}`), per-window
terms read off that call, widths taken from `_sb_out_w` (cells, see T5).
**RED**: the sweep row is short by 7 at 3 windows — 6 from the space-separated
`read` collapsing the empty `#{@bell}` (phantom +2 per window) and 1 from
`wc -m` counting characters instead of cells.
**GREEN change**: `|` separators (the empty bell field becomes a field, not a
slid value), the active chip's two spaces (`#I ` before the title **and** the
trailing space before `#[norange default]` — E4d: max no-clip field 171 with a
10-col stub block ⇒ chrome 11 for 2 windows), and cells instead of characters
(T5's helper). Net: same term list, every input measured.
**Done**: sweep rows flush at 200/140/90 with zero truncation markers; published
`@sl_tw` 132/72/22 linear in the client width; e2e test 8 green (row width ==
`#{client_width}`, no markers).

### T5 — the right block's variable width is inside the budget

**Value**: hiding the metrics (stub script / all blocks off) shrinks the budget by exactly the metrics width, so the pad still abuts.
**Path**: `_sb_sl_tw "$out"` already feeds the script's own rendered output, but measured with `wc -m`, which counts **characters** — round 3 showed 42 where tmux says 41. `_sb_out_w` publishes the output and asks tmux's own `#{w:}` primitive.
**RED**: the stub-script half of the sweep pair (T0's artifact) is not flush; the delta names the missing term.
**GREEN change**: one helper (`_sb_out_w`), and `wc -m` disappears (ponytail:
delete `_sb_visible` if it becomes unused — it does).
**Done**: green; `_sb_out_w` returns **cells** — `#{w:}` plus one per private-use
glyph (round 4: `#{w:}` reports the nf-icons as zero-width, the renderer draws
them in a cell), and the same helper measures the left block, so `wc -m` and
`_sb_visible` are gone.
**Class**: verification-only slice for the sweep artifact; the helper swap is the only behaviour change.

### T6 — a resize keeps the pad flush at every width

**Value**: dragging the terminal keeps the chip glued to the right block with no redraw churn.
**Path**: `tests/statusbar-e2e-test.bats` — attach an observer, `resize-window` 200→140→90, `refresh-client -S`, assert the pad's last column == right block's first column at each width. The row and the published field only agree once the fixed point converges, so the gate waits for **two consecutive identical rows** before asserting (proves convergence, no magic sleeps).
**RED**: new test (fails on the shipped `=/32/` baseline and on an unclamped budget).
**GREEN change**: none expected beyond T1–T4; the test is the deliverable.
**Done**: green e2e test; no `@fixed_w` re-publish churn when the value is unchanged.

### T7 — the floax popup's nested client keeps its inactive index visible

**Value**: the narrow nested client (its own `client_width`) shows ` 2` in its top row.
**Path**: `tests/floax-test.bats` #7 → `conf.d/05-floax.conf` (popup size) → nested client draw → `top_row_has " 2"`.
**RED**: existing test, `wait_until 5 top_row_has " 2"` fails.
**GREEN change**: expected to be satisfied by T1's clamp + T2's corrected budget. If it still fails, the cause is the *popup's* width vs the budget — name the term, do not add a per-session format (YAGNI: `client_width` is already per-client).
**Done**: floax suite 8/8 green.

### T8 — a client narrower than the budget clips the tail, not the indexes

**Value**: an absurdly narrow client degrades predictably (tail clipped, no garbage like `berly`, no zero-field full-title blowout).
**Path**: new e2e test at ~40 cols → `@sl_tw`'s `max:1` clamp → drawn row.
**RED**: new test asserting the row contains no negative-width artefacts and the active chip's index survives.
**GREEN change**: the clamp already in T1's `@sl_tw`; this ticket proves it and documents the ceiling.
**Done**: green at 40 cols; the known-limitation note lands in `conf.d/04-statusbar.conf` (one comment, not a doc file).

## Out of scope (YAGNI — do not plan these)

`scripts/tabwidth.sh`, baked literals, per-session `@sl_windows_fmt`, `@sr_w`,
tick hooks, a second truncation layer for fish's `…`, wide-char-aware display
width (chars vs columns — only if a test proves it drifts).

## Landing gate (per ticket)

1. RED gate written first (or the existing red test named) and shown failing for the right reason.
2. Minimum GREEN; delete anything the change makes dead.
3. Full `tests/*.bats` suite green + `.pi/capture-bar.sh` sweep pair regenerated.
4. Present evidence, **stop, ask "Approve commit?"** — no commit without owner approval.
