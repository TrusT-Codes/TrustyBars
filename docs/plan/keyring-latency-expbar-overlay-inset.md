# Follow-up: Key Ring / Latency Bar / Exp Bar overlay sizing

Status: **postponed, blocked on live-client verification** (no WoW client
available in the automated dev environment as of this writing).

## Background

The v1.0 polish pass (`Fix border-aware snapping and edit-mode overlay
accuracy`) made the edit-mode blue hitbox overlay and the drag-snap system
border-aware for default bars 1-5, whose native border texture
(`Button.lua`'s `self.border`) overhangs its button frame by design
(`BTV.BORDER_RATIO = 66/36`, `Core.lua`). See `BTV:GetElementVisualInset`
(`Core.lua`) for the mechanism.

Key Ring, Latency Bar, and Experience Bar are wrapped via
`DefaultBars.lua`'s `EnsureContainerOverlay`, called with the **raw native
Blizzard frame** (`KeyRingButton`, `MainMenuBarPerformanceBarFrame`,
`MainMenuExpBar`) and anchored with a flush `SetAllPoints(container)`. Key
Ring in particular is a native `ActionButtonTemplate`-style widget and may
have the same kind of oversized `NormalTexture` border that
`BTV.BORDER_RATIO` was built to correct for TrustyBars' own buttons - but
this can't be confirmed from source, since the native FrameXML art isn't in
this repo.

## What to do once a live client is available

Run `/btv diag1` in-game. This client caps a `/run` command at 511
characters including the leading `/run `, too short for a useful
multi-frame dump - so this is wired up as a permanent-until-resolved
`BTV:DiagKeyRingLatencyExpBar()` function (`Core.lua`, near the
`SLASH_BTVANILLA1`/`SlashCmdList["BTVANILLA"]` block) dispatched via the
existing `/btv` command's `msg` argument, alongside `diag2`/`diag3` for the
two sibling follow-ups. It prints exactly what the old inline script did:
`KeyRingButton`/`MainMenuBarPerformanceBarFrame`/`MainMenuExpBar`'s own
width/height, plus their `NormalTexture`'s width/height where one exists.

This is TEMPORARY diagnostic code - remove `BTV:DiagKeyRingLatencyExpBar`
and its `diag1` dispatch entry once this follow-up is resolved, the same
way Round 10's own temporary debug instrumentation was removed once it had
served its purpose (see `Core.lua`'s comment directly above the three
`Diag*` functions).

Also just eyeball the blue edit-mode overlay against each element's real
visible art in-game - border/background bleeding past the tint on any edge
is the actual symptom to look for.

- **If `KeyRingButton` reports a `NormalTexture` sized larger than its own
  frame**: extend `EnsureContainerOverlay` (`DefaultBars.lua`) with an
  optional `inset` parameter (mirroring `BTV:GetElementVisualInset`'s
  approach for default bars), and pass a Key-Ring-specific inset computed
  from the *confirmed* ratio - do not assume it reuses `BTV.BORDER_RATIO`
  (66/36) without confirming, since Key Ring may use a different
  template/asset than TrustyBars' own buttons.
- **If Latency Bar / Exp Bar report no oversized texture** (expected -
  they're plain `StatusBar`-style frames, not `ActionButtonTemplate`
  buttons): leave their `EnsureContainerOverlay` call sites unchanged.

This is a small, self-contained follow-up once the verification result is
known - see `Core.lua`'s `BTV:GetElementVisualInset` and
`DefaultBars.lua`'s `EnsureContainerOverlay` for the exact pattern to
extend.
