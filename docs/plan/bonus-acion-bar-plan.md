# TrustyBars — Bonus Action Bar as a Stance-Independent Extra Bar

## Context

Custom-bar (bars 6+) hoverbind keybinding is a dead end on this client — confirmed this session via live testing (`SetBinding`'s `"CLICK <frame>:<button>"` command is recorded correctly but never dispatched, `EnableKeyboard(true)` blocks all other input, and `SecureActionButtonTemplate` doesn't exist here). The native fix for that is tracked separately (`CustomBarKeybinding_DLL.md`) as its own project.

As a nearer-term partial fix, vanilla's stance/form "bonus action bar" (`BONUSACTIONBUTTON1-12`) already has 12 genuine native, keybindable actions built into the client. The user wants this repurposed as one more fully independent, keybindable extra bar — modeled on how Bartender2 handles this (a toggle that stops the game auto-paging the bonus bar by stance, freeing those 12 native bindings for permanent, addon-controlled use), with a new **"General"** settings tab housing the toggle. This only adds 12 more bindable slots (not the full 48 the custom-bar pool has), and only cleanly applies to classes without a stance mechanic unless the paging-disable toggle genuinely works as Bartender2's does — both caveats need a short live-client check before implementation, using the same investigative method that already successfully nailed down `LOCK_ACTIONBAR` in this project (check Interface Options, toggle it, diff the WTF files).

---

## Step 0 — Live-client verification (do this before any implementation)

This mirrors the method that already successfully found `LOCK_ACTIONBAR`: check Blizzard's own UI, toggle it, diff the WTF files — rather than guessing at a mechanism a third time.

1. Open Interface Options → Action Bars (on a character that actually has a stance/form mechanic — Druid, Warrior, or Rogue is ideal) and look for a checkbox resembling "stance bar" / "bar changes with stance" / similar wording. Report back the exact wording if found.
2. Toggle it, log out, and diff `WTF\Account\<name>\SavedVariables.lua`, `WTF\Account\<name>\config-cache.wtf`, and `bindings-cache.wtf` the same way `LOCK_ACTIONBAR` was found — look for any new/changed global or CVar tied to the toggle.
3. On that same stance-having character, shift into a stance/form and run `/run print(GetBonusBarOffset())` both in and out of the stance, with the toggle in each state, to see whether the toggle actually freezes the offset (this confirms whether disabling it truly makes the bonus bar static, or just hides the stance-bar UI without changing the underlying paging).
4. On a character with **no** stance mechanic (Mage/Priest/Hunter/etc.), run the same `GetBonusBarOffset()` check to confirm it's always `0` there, and separately confirm whether `BONUSACTIONBUTTON1-12` visually renders through the same physical `ActionButton1-12` frames as the Main Bar, or has its own dedicated frames — hover/right-click one of the Main Bar buttons while nothing is queued into the bonus page and compare `ActionButton1:GetName()` continuity, or simpler: temporarily assign something distinct to a bonus-page slot via a test macro/manual placement and see whether it shows up overlaid on the Main Bar or elsewhere.

---

## Conditional design (exact shape depends on Step 0's results)

- **If a genuine native toggle exists and reliably freezes `GetBonusBarOffset()` at 0**: add a **"General"** tab to the Settings window (new top-level tab alongside the existing bar-list view) with a checkbox, worded along the lines of "Use Stance Bar as Extra Action Bar" (off by default — matches "keep vanilla" as the safe default). This checkbox only needs to be shown/enabled at all for characters with a stance mechanic — for stance-less classes, the bonus bar is already always static, so the extra bar can simply always be available with no toggle needed there.
- When enabled, treat `BONUSACTIONBUTTON1-12` as a 6th default-bar-like entry, following the exact pattern `DefaultBars.lua` already established for bars 1-5: a `BTV.DEFAULT_BAR_BINDING_PREFIXES`-style entry, reuse of `GetDefaultBarButtons`-style frame lookup (contingent on Step 0.4's finding of whether it has its own frames or shares Bar 1's), `ApplyDefaultBarShape`-style positioning if it does have independent frames, and hoverbind wiring through the exact same native-`SetBinding` path already confirmed working for bars 1-5 (this part needs no new binding mechanism — `BONUSACTIONBUTTON1-12` is structurally identical to `ACTIONBUTTON1-12`/`MULTIACTIONBAR#BUTTON1-12`, which are already proven to work).
- If it turns out `BONUSACTIONBUTTON` shares physical frames with the Main Bar (Bar 1) rather than having its own, the "extra bar" won't be independently movable/resizable the way bars 1-5 are — it would only be usable as "12 more keybind slots that show on your Main Bar specifically while the bonus page is engaged." That's still a real, working improvement (12 more genuinely native, hoverbind-capable slots) but a materially different, smaller feature than a fully independent 6th bar, and should be scoped/communicated to the user as such once confirmed rather than assumed now.
- **If no such native toggle exists at all**: this path is a dead end for classes with a stance mechanic (same conclusion as the CLICK-binding investigation — a hard client limitation, not a code bug), but the bonus bar would still be usable as a genuine, always-static, keybindable extra bar for the stance-less classes only, with no toggle required. This narrower version could still ship on its own.

---

## Integration points once the shape is confirmed

- `DefaultBars.lua`: extend the frame-prefix/binding-prefix tables with the bonus-bar entry (or add a parallel small table if it needs materially different handling per Step 0's findings).
- `HoverBind.lua`: `ForEachButton`'s default-bar branch needs to include this new entry when the feature is enabled — no new binding mechanism required, since it uses the same proven `SetBinding(combo, nativeActionName)` path.
- `Settings.lua`: new "General" tab alongside the existing bar-list tab; the toggle lives there, and (if the bar turns out to be independently positionable) a settings page for it slots into the existing unified bar-list/page-builder pattern (`GetOrCreateBarPage`) the same way bars 1-5 already do.
- `Core.lua`: `EnsureDB` gains the new toggle's schema field (default off), following the exact pattern already used for `hoverBindMode`/`lockActionBars`-style flags.

---

## Verification

After Step 0's findings are in and the feature is implemented — enable the toggle on both a stance-having and a stance-less character (if the toggle applies to both), confirm Hoverbind now tints and successfully binds keys on the bonus-bar slots exactly like it already does for bars 1-5, `/reload` to confirm the binding persists, and (for stance-having characters) shift stance while the toggle is on to confirm the bar's content stays static rather than swapping with the stance change.
