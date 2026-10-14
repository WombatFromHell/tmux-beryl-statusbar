# FINDINGS — "grow-to-fill" smart-width tab chip

## Question
Can the active tab's title *grow to fill* the free space in the window-list,
updating live as the terminal is resized? (co-agent's `@fixed_w` + `@title_w`
approach: measure the fixed part in a script, publish it as an option, and let
`#{p...}` / `#{=N/...}` size the chip to `client_width − @fixed_w` at draw time.)

## Verdict
**No — not on tmux 3.8 (the installed version).** The live-resize mechanism
does not exist, and even the on-tick fallback cannot be built. The existing
fixed 32-char active chip is the practical maximum. Recommendation: do not
implement.

## Evidence (tmux 3.8, verified empirically against a scratch server)

1. **`#{p...}` / `#{=N/...}` do NOT expand their width argument.**
   - `display -p '#{p10:hi}'`            → 10 spaces (literal int works)
   - `display -p '#{p#{@tw}:hi}'` (@tw=12) → literal `p12:hi` (option-ref broken)
   - real attached-client draw: `#{p#{@tw}:X}` → `p10:X` (renders literally, no pad)
   - `#{=/#{@tw}/…:ABCDEFGHIJ}`            → empty
   ⇒ a chip width cannot be a format expression; it must be a literal integer
     baked into the format string.

2. **`#{client_width}` is only populated in a draw context.**
   - `display -p '#{client_width}'` → empty (script / display context)
   - real client draw                  → `100`
   ⇒ the free width `client_width − @fixed_w` is only knowable at draw time.

3. **Consequence:** the free width is only computable at draw time, and the only
   modifiers that could consume a width (`p` / `=`) refuse to expand their
   argument. tmux 3.8 has no mechanism to size a status segment to "fill the
   rest". No live-resize. An on-tick version is also not viable: the script
   cannot read `client_width` in its own context, and `tmux list-clients -F
   '#{client_width}'` returns *all* clients (fragile for multiple clients, and
   would still only update per tick / tab-switch / bell, not during a drag).

## Secondary issues in the co-agent's `tabwidth.sh`
- `left=$(tmux display -p '#{T:status-left}')` → `#{T:...}` returns **empty** in
  the script/display context on 3.8, so `l` is always 0. (If pursued, measure
  with `#{status-left}` instead.)
- `#{e|>:...}` comparison is fine (works on 3.8).
- The awk per-tab chrome constants are **correct** (verified: rendered
  chrome-only width == awk sum for a 3-tab case).
- Global `@fixed_w` vs the floax nested client: the co-agent's own "Also" note
  is right — a per-session override is needed for floax.

## Recommendation (YAGNI / KISS)
Do not implement. Keep the existing fixed 32-char active chip. "Grow to fill"
is a nice-to-have that requires an upstream tmux patch (make `p` / `=` expand
their width arguments) — not worth it for a personal config.
