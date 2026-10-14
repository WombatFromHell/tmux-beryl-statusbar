# PLAN — status bar render fixes (ticket ledger)

**Status**: Landed (S1-S5) · **Branch**: trunk
**Goal**: four render defects fixed, no new options, no new files, no new layers.

Grounding: the shipped bar, probed against a throwaway server on tmux 3.8
(`probe-widths.sh`, `probe-row.sh`, `probe-terms.sh` — scratch only, not shipped).
`DESIGN.md` is the mechanism map; two of its claims are now false and are re-pinned
in S5.

## Owner-approved decisions (this session)

1. **No padding at all.** The active chip's coloured band hugs its content; tmux's
   own fill takes the rest of the bar, in the bar's colour. Grow-to-fill is kept only
   as the *truncation* budget, never as drawn space.
2. **`#313244` (`@c_s0`) is the chip background** for metrics, calendar and clock.
   The time block is already right; the metric chips are the bug.
3. **The title shrinks first, markers come after.** `@sl_tw` stays the truncation
   limit so every index survives before tmux marks the list.
4. **Keep the 4-cell floor**: below 4 free columns the title group is dropped whole
   (the shipped `#{?#{@sl_tw},…}` guard and the `field < 4 → 0` clamp stay).
5. **Click range = the chip only.** No invisible pad to keep `#[range=window|…]` wide.

## Evidence (measured, not reasoned)

| Defect | Measured | Cause |
|---|---|---|
| 1 metrics chip background | drawn metric runs carry `bg=#1e1e2e`; the calendar/clock run carries `bg=#313244`; the state file's line 2 literally holds `#[bg=] #[fg=]…` | `compose_metrics` runs in the detached `_sb_fetch` subshell, and `_sb_opts` (the palette read) only runs in the renderer's `_sb_stamp` |
| 2 title band fills | the `bg=#45475a` run spans 133 cells at `@sl_tw` 131 = `sl_tw + 2` | `#{R: ,#{e|-:…}}` pads *inside* the styled title group |
| 3 no overflow markers | 3 and 12 windows at 200 cols: no markers; 20 windows at 90 cols: `>` renders and chops the tail | the pad makes the list exactly the section width, so tmux never truncates until the chrome alone overflows |
| 4 far-right gap | drawn row = 195 cells for a 200-col client; 5 cells of bar colour sit between the last tab chip and the metrics chip | `_sb_out_w` adds 1 per private-use glyph, but tmux 3.8's `#{w:}` already counts them as 1: left block +1, right block +4 |

Width probe (this machine, `LANG=en_US.UTF-8`): `#{w:}` of four Nerd Font icons = 4,
of `☁` = 1, of ` ☁ base ` = 8. The glyph add-back is a stale ceiling, not a live one.

False oracle found while reproducing: `row_width() { obs_row | wc -m; }` measures a
`capture-pane -p` row, which tmux pads to the client width, so `row_width == client_width`
passes whether or not the bar is flush. It is why defect 4 shipped green.

## Ticket ledger

Work top to bottom; each ticket leaves the full suite green.

| # | Ticket | Class | Gate |
|---|---|---|---|
| S1 | The metric chips get the palette the conf owns. | behaviour change | new e2e: the drawn metric cells carry `bg=#313244`, same as the calendar/clock cells | done |
| S2 | `_sb_out_w` stops double-counting the glyphs tmux already measures. | behaviour change | new e2e: the published field equals the cells the bar actually draws (measured from the styled row), so the 5-cell sliver is gone | done |
| S3 | The pad term is deleted; the title group is content-width. | behaviour change | tablist tier: the active chip's styled run = 2 + title cells, not `@sl_tw + 2` | done |
| S4 | The three "flush" e2e oracles are re-pinned to the new invariant. | re-pin (test-only) | budget / locked-leader / resize tests assert: no markers, row never overflows, a long title truncates at the published field with one `…` | done |
| S5 | `DESIGN.md` re-pinned: the budget is a truncation limit, not drawn space; the private-use-glyph ceiling is retired. | docs | prose only | done |

### S1 — the metric chips get the palette

**RED**: new e2e test — `capture-pane -e` the bar row, assert every metric chip's
background equals `@c_s0`. Fails today: the metric runs hold the bar default.
**GREEN change** (`scripts/statusbar.sh`, one move): call `_sb_opts` once at the top
level, before the detached fetch is forked, and drop the call from `_sb_stamp`. The
fetch subshell inherits the palette, so `compose_metrics` paints real colours and the
state file stops holding `#[bg=]`. One tmux read instead of two; no new option.
**Side effect to confirm**: the unit tier sets the palette as a fixture, so the
existing compose tests stay green untouched — they never covered this path.

### S2 — `_sb_out_w` stops double-counting

**RED**: new e2e — publish the field, then measure the drawn bar's own cells from the
styled row and assert they agree. Fails today by 5 (left +1, right +4).
**GREEN change**: `_sb_out_w` becomes publish + `#{w:}` only; the private-use diff
(`plain=${1//…/}`) and its comment go with it. `#{w:}` is the measure, unchanged.
**Done when**: the published field is 5 cells larger, the sliver is gone, and the
narrow-client test still drops the title at the same widths.

### S3 — the pad term is deleted

**RED**: tablist tier — style-strip is not enough, so assert on the styled row: the
`bg=#45475a` run must be `2 + #{w:pane_title}` cells, not `@sl_tw + 2`.
**GREEN change** (`conf.d/04-statusbar.conf`, one deletion): drop
`#{R: ,#{e|-:#{E:@sl_tw},#{w:pane_title}}}` from the active branch. The title group
becomes `#[bg=@c_s1]#[fg=@c_t1] #{title}#{bell} ` — content-width, one leading and one
trailing margin, same as every other chip.
**Keeps**: `#{=/#{E:@sl_tw}/…:pane_title}` (decision 3: the title shrinks first), the
`#{?#{@sl_tw},…}` guard (decision 4), the chip's `#[range=window|…]` (decision 5).
**Effect on defect 3**: the list is content-width, so tmux marks the list when the
tabs themselves stop fitting instead of absorbing them into a pad.

### S4 — the flush oracles are re-pinned

**Value**: three e2e tests assert `wc -m` of a padded capture, which is vacuous. Once
the pad is gone, "flush" is not the invariant, so the tests must say what actually
holds: the row never overflows the client, no markers while everything fits, and a
title longer than the field truncates at the field with exactly one `…`.
**GREEN change**: test-only. Add one assertion that fails if the pad returns
(the active chip's styled run stays content-width at every width).

### S5 — DESIGN.md re-pin

Two claims go stale: the width-budget paragraph ("pads the remainder", "the window
list is as wide as the client") and the Ceilings line about `#{w:}` measuring private-use
glyphs as zero width. Both are re-pinned to what the shipped code now does on tmux 3.8.

## Out of scope (YAGNI — do not plan these)

A second truncation layer, per-session formats, a `@lc_w` publish, wide-char-aware
display width, a pad that is drawn in another colour, per-client `@sl_tw` state.

## Landing gate (per ticket)

1. RED gate written first and shown failing for the named reason.
2. Minimum GREEN; delete anything the change makes dead.
3. Full `tests/*.bats` green + the sweep harness regenerated.
4. Present evidence, stop, ask "Approve commit?" — no commit without owner approval.
