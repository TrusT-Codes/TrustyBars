# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Chat output style: "Cavemen Speak"

All chat replies to the user in this repo (not code, not comments, not commit messages — just the conversational text) must use **Cavemen Speak**: short broken sentences, small words, drop filler words (no "I will now", "let me", "as you can see", "in order to"). State only what changed, what was found, or what is needed next. Cut connector words when meaning stays clear ("a", "the", "that", "which") — like a caveman talking, not a full grammatical sentence. No hedging, no repeating context back, no summarizing what was just done in a second sentence. One short line beats one long paragraph. Example: instead of "I have gone ahead and updated the function so that it now correctly handles the edge case you described" write "Fixed. Edge case handled now." Code blocks, diffs, file paths, and technical identifiers stay exact/unshortened — only the surrounding talk gets compressed.

## Comment style: WHAT, not WHY

Comments describe **what** the code does, not why it was decided that way — no rationale, no debugging history, no "confirmed via live testing" narratives. One short line max; no multi-paragraph blocks. Exception: if a specific ordering/pattern must stay exactly as written or a known bug reappears, keep a short warning saying so (e.g. `-- must run before X or the cooldown desync bug returns`) — that's the one case where WHY is allowed. Everything else that only explains past reasoning gets cut.

## What this is

TrustyBars (`BTVanilla`) is a Bartender2-style action bar addon for a **modified World of Warcraft Vanilla 1.12.1 client** (Turtle WoW-derived). The client is extended by four mods this addon depends on: **SuperWoW**, **nampower**, **ClassicAPI**, and **UnitXP_SP3**. There is no build step, no package manager, and no automated test suite — this is a pure Lua addon loaded directly by the WoW client via `BTVanilla.toc`.

## Commands

- **Syntax-check a file before considering any edit done:** `luac5.1 -p <File>.lua` (both `luac5.1`/`lua5.1` are available). There is no other automated verification — no unit tests, no linter config. Always run this on every file you touch.
- **No build/install command** — the addon runs by being present in the client's `Interface/AddOns/TrustyBars` folder; there's nothing to compile or bundle.
- Runtime testing happens live, in-game, via the user's client. When an API/CVar/event's exact behavior is uncertain, do not guess — see "Verifying uncertain client behavior" below.

## Critical constraint: Lua 5.0, not 5.1+

The client's interpreter is Lua 5.0 (manual: https://www.lua.org/manual/5.0/). Differences already baked into this codebase — never introduce 5.1+ syntax:

- No `...`/`{...}` vararg capture — use the implicit `arg` table (`arg.n` for count) and `unpack(arg)` to forward.
- No `#` length operator — use `table.getn`.
- **No `%` operator at all** — use `n - (math.floor(n/d)*d)`.
- No hex literals (`0x...`) — use `tonumber("0x...", 16)`.
- No `string.gmatch` — use `string.gfind`.
- `select`, `wipe`, `xpcall`, `hooksecurefunc` are not native Lua 5.0 but ARE available (registered natively by ClassicAPI's DLL) — safe to use. `issecurevalue`/`issecurevariable`/`scrubsecurecall`/`securecallfunction`/`secureexecuterange`/`pcallwithenv` are confirmed live to be **unavailable** despite appearing in ClassicAPI's string table — do not use them.
- Closures, metatables, coroutines, `table.insert`/`remove`/`sort`/`concat` all work, but double-check argument order against the 5.0 manual before assuming 5.1 behavior.

Code ported from any modern (5.1+) reference addon — including retail Bartender2 — needs its vararg/`#` usage rewritten to these idioms as part of the port.

## `this` vs `:method()` convention

Engine-invoked script handlers (`OnClick`, `OnEvent`, `OnEnter`, `OnLeave`, `OnDragStart`, `OnReceiveDrag`, …) receive the frame via the global `this`, **not** a `self` parameter — this client predates that convention. Only methods called explicitly with `:` receive `self`. Mixing these up is an easy, silent bug; every handler in this codebase follows this split deliberately.

## No secure-handler system

There is **no `SecureHandler*`/`SecureActionButtonTemplate` system on this client** (that's a 2.0/TBC-era addition). `InCombatLockdown()` exists but always returns `false` here — never gate logic on it. Plain `CreateFrame` buttons repositioned with ordinary `SetPoint`/`SetSize` are confirmed unrestricted even during real combat (bracket real combat-state checks with `PLAYER_REGEN_DISABLED`/`PLAYER_REGEN_ENABLED` instead, if ever needed).

## Prefer upstream mod APIs over hand-rolled code

Before writing new logic, check whether SuperWoW, nampower, ClassicAPI, or UnitXP_SP3 already expose it — see `docs/01-Environment-Capability-Analysis.md` §2–§6 (§6 is a live summary table of what to reuse vs. build). Load-bearing facts:

- Custom action buttons are backed by real vanilla **action slots 73–120** (pages 7–10, unused by the default UI — 48 slots max), driven through native `UseAction`/`PlaceAction`/`PickupAction`/`HasAction`/`GetActionTexture`/`GetActionCooldown` — the `ButtonForge Classic` pattern (MIT-licensed reference addon, read in full during research).
- Mouseover-*casting* requires SuperWoW's `CastSpellByName(spellName, "mouseover")` as a per-button `OnClick` override, bypassing `UseAction` only for that button.
- Player's own cast-bar/GCD: nampower's `GetCastInfo()` — `C_Spell.UnitCastingInfo("player")` is confirmed non-functional. Any other unit: ClassicAPI's `C_Spell.UnitCastingInfo(unit)`/`UnitChannelInfo(unit)` + `UNIT_SPELLCAST_*` events.
- Cooldowns: nampower's `GetSpellIdCooldown`/`GetItemIdCooldown`/`GetTrinketCooldown`. Range/usability: `IsSpellInRange`/`IsSpellUsable`.
- Scheduling: ClassicAPI's DLL-native `C_Timer.NewTicker`/`NewTimer`/`After` — never hand-roll an `OnUpdate` polling loop.
- Reuse ClassicAPI's `PixelUtil`, `Mixin`/`CreateFromMixins`, `TableUtil`, `MathUtil`/`Rectangle`/`Vector2D`, `CallbackRegistryMixin`/`EventRegistry`, frame/texture pool helpers, and `RegisterNewSlashCommand` rather than reimplementing them.
  - **Caveat:** `PixelUtil.SetPoint(region, point, relativeTo, ...)` calls `GetEffectiveScale()` on both arguments, which FontString/Texture (`Region`-derived, not `Frame`) objects don't have. Guard on `region.GetEffectiveScale`/`relativeTo.GetEffectiveScale` existing and fall back to plain `:SetPoint(...)` when chain-anchoring a mix of Button and FontString/Texture globals (see `DefaultBars.lua`'s `PixelSetPoint` helper).
- `bit` (`band`/`rshift`/`lshift`) is available, but its source is most likely the Turtle WoW base client itself, not one of the four target mods — re-verify if this addon is ever run against a non-Turtle 1.12.1 server.

## Verifying uncertain client behavior

Do not guess, and do not write multiple defensive/fallback code paths to hedge against uncertainty about how a CVar/API/event behaves in this client. Instead:

1. Write a small, standalone verification script (a `/run` one-liner or throwaway `.lua` snippet) the user can run on their real client — e.g. `print(GetCVar("SomeName"))`. For anything too big for a one-liner (this client caps `/run` at 511 characters), add a temporary numbered `/btv diagN` slash command in `Core.lua`'s dispatcher, in the style the git history shows for `diag1`–`diag26`; better still, when manual command timing could race the thing you're measuring, put the trace directly in the code path so it fires by itself. **Remove it once the finding is confirmed** — none are kept in the shipped code.
2. Hand it to the user with exactly what to run and what output confirms which hypothesis; wait for their result before writing the real implementation.
3. Only if several such scripts genuinely can't cover the needed scope should you propose a small dedicated debugging addon — never build one preemptively.

Never ship production code that silently tries several different CVar names, event signatures, or API shapes "just in case" one works — resolve the ambiguity first via a live diagnostic, then write one correct implementation. This addon has extensive precedent for this in `docs/01-Environment-Capability-Analysis.md` — its whole §5 is a log of exactly this process, and §5af is the cautionary case: when a change of "only debug prints" flips real behavior, restore the working text byte-for-byte and bisect it one variable at a time rather than rewriting it into what it obviously means.

## Architecture

Single global table `BTVanilla` (locally aliased `local BTV = BTVanilla` in every file); `BTVanillaDB` is the account-wide SavedVariable, `BTVanillaProfilesDB` holds saved profiles, `BTVanillaCharDB` is per-character. `BTV:EnsureDB()` in `Core.lua` is the pattern for adding new persisted fields with migration-safe defaults. Files load in this order (`BTVanilla.toc`):

1. **`Core.lua`** — addon bootstrap, action-slot pool management (pages 7–10), slash command dispatch (`SlashCmdList["BTVANILLA"]` — `/btv` opens the settings window, `/btv recapture` re-captures default-bar native anchors; temporary `/btv diagN` diagnostics get added here and removed again once their finding is confirmed), `BTV:EnsureDB()`.
2. **`DefaultBars.lua`** — owns bars 1–5, the "default bars" that wrap Blizzard's **own** real frames (`MainMenuBar`/`MultiBarBottomLeft`/`MultiBarBottomRight`/`MultiBarRight`/`MultiBarLeft` and the native Stance/Bag/Micro-menu/Latency/Experience Bar frames). These are already backed by real action-slot bindings on the default UI's own paging — this file only repositions/reflows/resizes/shows-hides them, it never touches their action-slot bindings. Frame-name mapping is centralized in one table since exact FrameXML names are inferred, not guaranteed, on this client fork.
3. **`Bar.lua`** — the multi-bar grid engine for TrustyBars' own custom bars (6+), backed by the action-slot pool from `Core.lua`. Bar IDs are persistent identities, **not** array indices. Each bar's saved config: `id`, `point`, `relativePoint`, `x`, `y`, `cols`, `rows`, `buttonSize`, `slotStart`, `buttonCount`.
4. **`Button.lua`** — single action-slot-backed button, following the `ButtonForge Classic` pattern: plain non-secure frame driven entirely through native `UseAction`/`PlaceAction`/`PickupAction`/`HasAction`.
5. **`HoverBind.lua`** — hoverbind keybinding mode (hover a button, press a key to bind). Default-bar buttons bind via real native action names (`ACTIONBUTTON1-12`, `MULTIACTIONBAR#BUTTON1-12`); custom-bar slots have no native per-slot binding action, so they're bound through a shipped `bindings.xml` — `SetBindingClick`/`"CLICK <frame>:<button>"` and `SetBinding(key, "BONUSACTIONBUTTON1")` are both confirmed dead ends on this client.
6. **`Minimap.lua`** — minimap launcher button (angle-based positioning around the minimap circumference).
7. **`Menu.lua`** — right-click context menu off the minimap button, via vanilla's native `UIDropDownMenuTemplate` (transient popup) — a separate code path from `UIWidgets.lua`'s persistent inline dropdown, though both wrap the same underlying FrameXML template.
8. **`UIWidgets.lua`** — small reusable Mixin-based widget kit (dialogs, inline dropdowns, list rows, fade-strip highlight effects), built on ClassicAPI's `Mixin`/`CreateFromMixins`. This is the pilot for the addon's "modern" button/list styling that `Settings.lua` is being rolled out to use everywhere (`BTV:StyleModernButton`, `BTVListRowMixin`, `BTV:CreateFadeStrip`).
9. **`Settings.lua`** (by far the largest file) — the unified settings window: default bars (1–5), Extra Bars (6–9), native-frame "simple" pages, one shared bar list, a "Bars" view and a "General" view. Every control is live — no pending/Apply state anywhere; a slider/checkbox/swatch click writes straight to `BTVanillaDB` and re-applies immediately.
10. **`bindings.xml`** — static keybinding-action declarations consumed by `HoverBind.lua`'s custom-bar binding path.

`Mixin(table, mixinTable)` (used throughout `UIWidgets.lua`/`Bar.lua`/`Button.lua`) does a **direct table copy** of mixin functions onto an instance. This means capturing a frame's "native" method reference (e.g. `SetWidth`) must happen **before** calling `Mixin()`, or the capture grabs the mixin's own override instead of the real native method — a recursion bug from getting this order wrong has bitten this codebase before (see `UIWidgets.lua`'s `CreateListRow`).

`CreateFrame(type, name, parent, template)` with a name that's already a global does **not** return the existing frame — it creates a **brand new** one that merely shares the name (live-confirmed: two consecutive rebuilds produced two different `tostring()` identities from the identical name string). Since native `UIDropDownMenu_*` code resolves its sub-widgets via `getglobal(self:GetName() .. "Text")`-style lookups, two live frames answering to one name corrupt each other's rendering — hiding the older one does not help. Never reuse a name across rebuilds expecting frame identity to persist; make each rebuild's names unique instead (see `Settings.lua`'s `RebuildMainBarAssignmentRows`, which suffixes a per-rebuild counter). Separately, native dropdown popouts (`DropDownList1`) are a **single shared global**, not owned per-instance.

## Research doc

`docs/01-Environment-Capability-Analysis.md` is the authoritative, empirically-verified record of what SuperWoW/nampower/ClassicAPI/UnitXP_SP3 can and cannot do, built up over many live-testing rounds. Its §6 summary table and the §5 live-confirmation subsections are ground truth — prefer them over general/retail WoW addon knowledge, which frequently does not apply to this client. `docs/plan/` holds smaller scoped design docs for specific features/bugs (custom-bar keybinding, bonus action bar, visual-inset regressions).

## Style already established in this codebase

- New files must be added to `BTVanilla.toc` in load order, respecting inter-file dependencies (see the ordered list above).
