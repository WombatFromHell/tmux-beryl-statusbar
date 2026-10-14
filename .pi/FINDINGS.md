# FINDINGS — "grow-to-fill" smart-width tab chip

## Question
Can the active tab's title *grow to fill* the free space in the window-list,
updating live as the terminal is resized? (co-agent's `@fixed_w` + `@title_w`
approach: measure the fixed part in a script, publish it as an option, and let
`#{p...}` / `#{=N/...}` size the chip to `client_width − @fixed_w` at draw time.)

## Verdict (corrected — the previous "No" was wrong)
**Yes — tmux 3.8 does it, live on resize, with no script and no baked literal.**
The old run concluded "no" because it tested the width *argument* in a `display
-p` context, where `p`/`=` refuse to expand. Inside `status-format` — the only
place a chip is ever drawn — they expand normally. The missing piece was the
**repeat** modifier: `#{R: ,N}` pads, and it takes an expanded arithmetic
argument. Truncation + pad together, both fed from `#{client_width}`, are the
whole mechanism.

## Evidence (scratch server, tmux 3.8, real attached client; harness = facts18/19/20)

| Probe | Result |
|---|---|
| `list-clients -F '%l %w'` | `tmux/obs 200` — `%w` is the live client width |
| `list-clients -F '#{client_width}'` | `200 140` — per-client, live |
| `#{client_width}` inside `status-format[0]` | **140 on a 140-col client, 200 on a 200-col client** — tracks resize, per client |
| `#{=/#{e\|-:#{client_width},#{@fixed_w}}/…:pane_title}` | renders; at client 90 / `@fixed_w` 55 a 40-char title → 34 chars + `…` (field = 35) |
| `#{R:.,#{e\|-:#{e\|-:#{client_width},#{@fixed_w}},#{w:pane_title}}}` | renders; 40-char title at client 200/`@fixed_w` 55 → **105 dots** (field = 145); at client 140 → 45 dots |
| `#{w:pane_title}` at draw time | display width of the title (pad count) |
| `#{w:status-left}` / `#{w:@sl_session}` | **unusable** — counts the literal option text (`#()` jobs are not run during expansion; `status-right` measured 43 = the byte length of `#(bash …/statusbar.sh)`) |
| `#{p#{@tw}:hi}`, `#{=/#{@tw}/…:x}` in `display -p` | literal / empty — the old finding; irrelevant to the draw path |

Widths measured from `.pi/golden-pre.txt` (200-col client, real `statusbar.sh`):

- left chip ` base ` ends at col 17 → left block = **17**
- right metrics block ` 33%|99%   4%|77%   10.14 | 11:14` = **34** cols, right-aligned
- inter-chip chrome (` ` + `@sl_gap_pad` + ` #I` + ` `) = **4**
- ⇒ `@fixed_w` = 17 + 34 + 4 = **55** for this configuration

## Round 2 — measuring the parts (scratch server, tmux 3.8, real attached client)

The mechanism is settled; the open half is **what `@fixed_w` is made of**. Probes
(`.pi` harnesses `probe2`/`probe3`/`probe5b`):

| Probe | Result |
|---|---|
| `#{w:status-left}` **at draw time** (`status-format[0]`, nested client) | `L28\|16R` — still the literal option text; `#()` jobs never run during expansion, in **any** context |
| `#{E:status-left}` from a script context | `#(echo XY)abc` → `abc` — `#{E:}` expands `#{}` refs and **drops** `#()` jobs |
| `#{w:#{E:status-left}}` | `3` — left block width *excluding* job output. **The usable measurement primitive** |
| `tmux show -p status-left` (what `statusbar.sh` used) | the raw option text: `#{E:@sl_session}` refs + the literal `#(bash …/lockchip.sh)` → ~60 cols for a 17-col block. **Over-estimate, and it is what dropped the floax popup's indexes** |
| `#{=/0/:x}` | full string — a zero field means "no limit" |
| `#{=/-5/:x}` | `berly` — garbage; a negative field is unsafe |
| `#{R:x,0}` / `#{R:x,-5}` | empty — negative pad counts are safe |
| `#{?#{client_width},A,B}` | `B` when no client is attached — usable fallback switch |
| `#{E:@tw}` (option holding an arithmetic expr) inside `#{=/…/}` | expands at the use site ⇒ TW can be written **once** in the conf and reused twice |
| man-page variable list (tmux 3.8) | no "remaining list width" variable exists ⇒ the budget must be computed by us |

Consequences for the budget:

- The left block is measurable **except** for its `#()` jobs; the only one is
  `lockchip.sh` (3 cols locked, 0 unlocked). Owner of that variable part is
  `lockchip.sh` itself → it publishes `@lc_w`, the script adds it.
- `TW` must be clamped: `#{?#{@fixed_w},#{e\|max:1,#{e\|-:#{client_width},#{@fixed_w}}},32}`
  — `32` when the budget is unpublished (no client at `display -p`, or the first
  draw before `statusbar.sh` runs), `max:1` so a client narrower than the budget
  degrades by clipping the tail instead of rendering garbage.

## What this deletes vs the co-agent's plan (REVIEW.md)
- `scripts/tabwidth.sh` and the "bake a literal integer into `@sl_windows_fmt`
  every tick" mechanism: **not needed**. `#{client_width}` is live at draw time,
  so the format is static and resize-correct for free (the baked-literal route
  only updated per tick / tab-switch / bell, and never during a drag).
- `#{T:status-left}` measurement (returns empty in a script context): **not
  needed**; one user-set integer replaces the whole measurement.

## Contract
- `@fixed_w` = columns consumed by everything **except** the active chip's title
  field: left chip + bell markers + the other window chips + the right block.
- Failure mode is asymmetric: **overshoot clips the window list** (facts11:
  `@fixed_w` 20 at client 200 dropped windows 1 and 3 from the bar), undershoot
  only leaves a base-colour gap. Keep the value conservative.
- The right block's width varies with the metrics (clock, battery %), so
  `@fixed_w` is an approximation; a 1–2 col gap is acceptable, clipping is not.

## Open lever (resolved — the lever is now taken)
`scripts/statusbar.sh` **does** publish `@fixed_w` every pull (user-approved), so
the right block's variable width (metrics on/off, bell dots) is tracked exactly.
The remaining approximation is the *window count* (the budget is per-server,
`client_width` is per-client) — see PLAN.md ticket T8.

## Round 3 — the row anatomy, and the chrome is **measurable** (probe38–probe41)

A 200-col client, 3 windows, active = 2, titles pinned to 3 chars, read as
colour runs off `capture-pane -e` (the only way to see which spaces belong to
which block):

```
[left 8][SP 1][chip 3][SP 1][idx 3][SP 1 title 3 pad 129][SP 1][chip 3][SP 6][right 41] = 200
```

The `SP 6` is the right block's separator (1) plus the unfilled budget (5) —
that is the gap, and it is now fully accounted for:

| term | script arithmetic | row says | delta |
|---|---|---|---|
| `vis` (this job's output) | 42 via `wc -m` | 41 via tmux `#{w:}` | −1 |
| phantom bells | +2 × 3 windows | 0 | +6 |

The +6 is a scan bug, not a model bug: `list-windows -F '#{window_index} #{@bell} #{window_active}'` emits `1  0` when `@bell` is empty, and `read -r idx bell act` collapses the run of spaces, so `window_active` lands in `bell` and every window looks bell-flagged.

**E4b — the format's rendered width is exactly `chrome + field`**, for every field at or above the title width (stub job, `@sl_tw` pinned, `#{w:#{E:@sl_windows_fmt}}`):

| `@sl_tw` | 5 | 50 | 131 | 200 |
|---|---|---|---|---|
| `fmt_w` | 18 | 63 | 144 | 213 |
| chrome | 13 | 13 | 13 | 13 |

So the window list's chrome — markers, gap pads, per-chip indexes, inactive
titles, the format spaces — is **one measurement**, not a term list. `chrome =
fmt_w − the field that measurement was taken at`, which makes the budget a
fixed point: `field = client_width − lw − lc − vis − chrome`, re-derived every
draw, self-correcting when the window count or the metrics change.

At `@sl_tw = 1` (below the title width) chrome reads 14, one too many: the
negative pad `#{R: ,-2}` emits a phantom space. Consistent with round 2's
"zero/negative fields are unsafe"; the `max:1` clamp keeps us above it.

Owner-approved (this session): measure the chrome (route A), keep `@lc_w` as the
lockchip's own term, and gate the e2e claim on a **stable row** (two
consecutive identical draws) rather than a sleep, so the test proves
convergence instead of luck.

## Round 4 — route A falsified; the measure is cells, not wcwidth (probe42–probe54)

Round 3's "measure the whole format" route does not work. `list-windows -F`
evaluates a format **per window**, and a *nested* expansion inside it is
evaluated in the command's own pane context, not the iterated window's:

- probe42: `list-windows -F '#{w:#{E:@sl_windows_fmt}}'` returned the same
  width for every window (160, 160, 160) while the list's real width was 147 +
  chrome — one chip, not the list.
- probe43: the direct per-window expansions (`#{window_index}`, `#{@bell}`,
  `#{window_active}`, `#{w:pane_current_command}`) **do** vary per window, so
  only the pieces are measurable, never the composed list.

So the chrome stays a term list; what must stop being hand-counted is the
**unit**. Two independent errors were hiding in it:

1. **Field alignment.** `read -r idx bell act` over a space-separated format
   collapses the empty `#{@bell}` field, sliding `window_active` into `bell` —
   every window looked bell-flagged, +2 phantom columns each (the 4 in a 2-window
   row). `|`-separated fields fix it: `1||0` vs `1|1|0`.
2. **`#{w:}` is not the drawing.** tmux's width primitive uses wcwidth, which
   reports the private-use nf-icons (U+E000–U+F8FF) as **zero**, while the
   renderer still draws each in one cell. probe54: the drawn left block is 8
   cells, `#{w:#{E:status-left}}` says 7. Every measured block is short by one
   per such glyph — the same class of error `wc -m` had, in the other direction.

`_sb_out_w` now returns **cells**: `#{w:}` plus one per private-use glyph in the
text (`${1//[$'\ue000'-$'\uf8ff']/}` — a `$'…'` per bracket end; a single
`$'\ue000-\uf8ff'` is a malformed range that matches nothing, which is why the
first attempt changed nothing).

Oracle note: the sweep harness must attach **one client per server**. `@sl_tw`
is a server-global option, so N clients of different widths overwrite each
other's field and only the last writer's client can be flush (probe47: 5 widths,
4 clipped). That is a real limitation of the mechanism, not a bug to fix here.

Landed evidence (sweep, one client per server, real script): rows at 200/140/90
are exactly 200/140/90 chars with **zero** tmux truncation markers; published
`@sl_tw` 132/72/22 (linear in the client width, as E4b predicted).
