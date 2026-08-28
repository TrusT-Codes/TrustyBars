# Default bar visual-inset feature: resolved

Status: **re-enabled with full per-side precision, live-tested working**.

## History (for context - not current state)

The v1.0 polish pass added `BTV:GetElementVisualInset` (`Core.lua`) to make
default bars' (id 1-5) edit-mode overlay and drag-snap boxes match their
*visible* border extent instead of their bare frame - since `Button.lua`'s
`self.border` texture is drawn at `BTV.BORDER_RATIO` (66/36) of the button
size, overhanging the frame on every side.

An early live-client test reported this as "way too big" and "impossible
to align" - the per-button formula's own math never explained that
magnitude on paper, so the feature was disabled (`GetElementVisualInset`
forced to return `0`) rather than guess further blind.

Two other bugs were found and fixed independently in the meantime:

- **Icon/border gap** - default bars' icon (`Button.lua`, `iconInset`) and
  backdrop background fill both had a leftover inset (2px / 1px
  respectively) that only ever mattered for custom bars' old
  SetBackdrop-drawn border. Default bars have had a separate overlay-layer
  border since round 15 that renders above the icon regardless of icon
  size, so the inset was unnecessary and left a real, live-confirmed gap
  (`/btv diag7` proved real vanilla's `ActionButton1Icon` is flush, 0px,
  with its frame). Both are now `0` for `hasNativeBorder` buttons.
- Border texture rendering itself (`/btv diag4`) is confirmed byte-for-byte
  identical to real vanilla's `ActionButton1` `NormalTexture` - same
  texture, size, and `TexCoord`.

## Root cause of the original "way too big" report

Never conclusively identified - but subsequent diagnostics (`/btv diag2`,
`/btv diag9`) directly measured the real border-vs-frame overhang on live
bars and found it exactly matches the intended formula: 15px left/right,
14px top / 16px bottom (the 1px top/bottom asymmetry is `Button.lua`'s
own `y = -1` border anchor offset, round 16 - a FIXED pixel offset, not
proportional to button size - now named `BTV.BORDER_Y_OFFSET`). Nothing in
the formula or its per-side breakdown is "way too big." The likely
explanation, in hindsight: the disabled version only ever applied ONE
uniform inset value to all 4 sides (ignoring the top/bottom asymmetry),
*and* the icon/backdrop bugs above were still present and unfixed at the
time - some combination of visual noise from those separate, now-fixed
bugs most likely made the overlay look far more wrong than the geometry
itself ever was.

## Current implementation

`BTV:GetElementVisualInset(frame)` (`Core.lua`) returns 4 independent
values - `left, right, top, bottom` - instead of one uniform number:

```lua
local uniform = buttonSize * (BTV.BORDER_RATIO - 1) / 2
-- left, right, top, bottom
return uniform, uniform, uniform - BTV.BORDER_Y_OFFSET, uniform + BTV.BORDER_Y_OFFSET
```

Threaded through:
- `Core.lua`'s `GetRealScreenBounds(region, insetLeft, insetRight, insetTop, insetBottom)`
  and `GetAllSnapTargetBoxes` (relies on Lua's trailing-call multi-value
  expansion: `GetRealScreenBounds(frame, self:GetElementVisualInset(frame))`
  passes all 4 return values positionally).
- `DefaultBars.lua`'s `ApplyDragSnap` (inflates/deflates the dragged
  element's proposed box by each side's own inset independently).
- `Bar.lua`'s `EnsureBarOverlay` (anchors the per-bar edit-mode overlay
  tint to each side's own inset).

Live-tested: default-bar-to-default-bar and default-bar-to-custom-bar
snapping/overlay now works correctly.

## Still open: Micro Menu / Page Indicator / general overlay accuracy

These turned out to be a *different* class of bug entirely - not
border-overhang, but `GetHitRectInsets()` (a real Button's clickable area
can be smaller than its own frame, independent of frame size). See the
git history around `GetHitInsets`/`ScaleRatio`/`ApplyChainAnchoredShape`
(`DefaultBars.lua`) for the fix applied to Bag Bar/Micro Menu/Stance Bar's
shared chain-anchoring code, and `BTV.MICRO_MENU_OVERLAY_TOP_FUDGE`
(`Core.lua`) for the small residual live-tuned constant on top of that.
Key Ring/Latency Bar/Exp Bar overlay sizing (native-wrapped single
frames, not chain-anchored) is still an open follow-up - see
`docs/plan/keyring-latency-expbar-overlay-inset.md`.
