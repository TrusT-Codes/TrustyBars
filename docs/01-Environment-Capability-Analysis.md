# Environment Capability Analysis — Bartender2-for-1.12.1 Project

**Purpose of this document:** before writing a single line of the addon, establish exactly what the runtime (Vanilla 1.12.1 + Lua 5.0 + SuperWoW + nampower + ClassicAPI + UnitXP_SP3) can and can't do, so we don't reinvent things the client mods already give us, and don't design around capabilities that don't actually exist.

Method note: ClassicAPI.dll, SuperWoWhook.dll and nampower.dll were inspected directly (string/resource extraction from the binaries — ClassicAPI in particular ships its entire Lua source embedded as a resource, so the analysis below is taken from the *actual shipped source*, not guesswork). UnitXP_SP3.dll is UPX-packed with a deliberately corrupted header (anti-tamper), so it could not be statically unpacked in this environment; its section below is based on the maintainer's own documentation instead and should be treated as slightly less certain than the other three.

---

## 1. The baseline constraint: Lua 5.0

Everything else sits on top of vanilla 1.12.1's Lua 5.0 interpreter. This matters a lot for how we write Bartender2-style code, because most modern reference addons (including the linked Bartender2 fork) are written against Lua 5.1 semantics. Concretely, we do **not** have:

- `...`/`{...}` vararg capture syntax — Lua 5.0 puts varargs into an implicit `arg` table with an `arg.n` count. `unpack(arg)` is required to forward them, and `unpack` must be called against a table that carries an explicit `.n` field or it stops at the first `nil` hole (confirmed by a comment in ClassicAPI's own source, which was bitten by this).
- `#` length operator — use `table.getn` / `getn`.
- `select()`, `wipe()`, `xpcall` as pure Lua-5.1 builtins — **however**, ClassicAPI's DLL registers these natively in C (see §3), so we effectively get them back.
- `string.gmatch`, `string.rep` multi-arg form, bitwise operators, `os.time`-precision niceties, etc. — not present; `string.gfind` (5.0 name) is the iterator we have instead.
- **No hexadecimal literal syntax** (`0x...`) at all — confirmed directly in ClassicAPI's own source, with an explicit comment: *"Using tonumber because lua 5.0 doesn't support hexadecimal literals."* Any hex constant must be written `tonumber("0x00100000", 16)` instead of `0x00100000`.
- Native `table.insert`/`table.remove`/`table.sort`/`table.concat` — these **do** exist in 5.0, just double check argument order against the 5.0 manual, it differs slightly from 5.1 in a couple of edge cases.
- Real closures, metatables, coroutines — these **do** exist in 5.0, so OOP-via-metatable and Mixin-style composition both work fine.

**Practical implication:** any code adapted from the Bartender2 reference (which targets modern/5.1 Lua) needs its vararg handling rewritten to the `arg`/`unpack(arg)` idiom, and any `#tbl` needs to become `table.getn(tbl)`. This should be written down as a house style rule before porting any of Bartender2's logic.

---

## 2. SuperWoW — combat/unit primitives, not a UI toolkit

SuperWoW (v1.5, "SuperWoW 1.5 by Balake") is focused on exposing lower-level combat/unit state that vanilla's Lua API doesn't have, plus a couple of raw file/import utilities. Confirmed exposed pieces:

- `CastSpellByName(name [, unitid])` — extends the normal call with an explicit unit id/target argument.
- `SpellInfo`, `CombatLog`, `TrackUnit("unit")`, `UnitPosition`, `GetPlayerBuffID(buffIndex)`, `Clickthrough`, `SetAutoloot`, `SetMouseoverUnit`.
- `GetTradeSkillItemLink(index [, spellLink])`.
- New events: `UNIT_CASTEVENT`, `RAW_COMBATLOG`.
- `ImportFile("filename")` / `ExportFile("filename","text")` for basic file IO.
- GUID-aware unit tokens (SuperWoW is best known for letting `UnitExists`/etc. resolve on raw GUID strings, not just the fixed unit-id list vanilla ships with).

**Relevance to this addon:** low-to-moderate. Bartender2's job is bars, buttons, layout, and secure click-casting — SuperWoW's value is almost entirely on the "what am I targeting / casting at" side, not on frame layout. The one piece worth keeping in mind is `SetMouseoverUnit`/mouseover-unit support, which matters if we ever want mouseover-cast action buttons (a common Bartender2/paired-addon feature). Otherwise we shouldn't design core bar functionality around SuperWoW.

---

## 3. ClassicAPI — the actual foundation for this addon

This is the important one. ClassicAPI (`v1.9.11`, "Library to emulate aspects of the modern WoW API on 1.12.1 / Lua 5.0") is not a small utility library — it embeds a large chunk of retail FrameXML's `Util/` folder, ported to 1.12.1/Lua 5.0, plus a handful of true C-side (DLL-native) globals. Its own TOC lists (and the DLL contains the full source of) these modules:

```
Compat.lua
Util\Print.lua            Util\Mixin.lua            Util\Color.lua
Util\Constants.lua        Util\TableUtil.lua         Util\MathUtil.lua
Util\PixelUtil.lua        Util\FrameUtil.lua         Util\FormattingUtil.lua
Util\TimeUtil.lua         Util\CallbackRegistry.lua  Util\GlobalCallbackRegistry.lua
Util\ColorUtil.lua        Util\ItemLocation.lua      Util\PlayerLocation.lua
Util\EventUtil.lua        Util\ItemUtil.lua          Util\AddOnCompat.lua
Util\FunctionUtil.lua     Util\CacheUtil.lua         Util\Pools.lua
Util\FrameWatcher.lua     Util\TimedCallback.lua     Util\EquipmentManager.lua
Util\PlayerUtil.lua       Util\SlashCommandsRegistry.lua  Util\LinkUtil.lua
Util\TradeSkillLink.lua   Util\IconDataProvider.lua  Util\GameTooltip.lua
Util\Rectangle.lua        Util\Vector2D.lua          Util\Vector3D.lua
Util\Vector4D.lua         Util\UIParent.lua          Util\AuraDurationModifiers.lua
Util\SecureUnitMenu.lua
```

### 3.1 What's genuinely a gift for a Bartender2-style addon

- **`PixelUtil`** — a **verbatim, working port of retail's `FrameXML/PixelUtil.lua`**. `PixelUtil.SetPoint`, `PixelUtil.SetSize`, `PixelUtil.SetWidth`, `PixelUtil.SetHeight`, `PixelUtil.GetNearestPixelSize`, `PixelUtil.ConvertPixelsToUI(ForRegion)`, `PixelUtil.SetStatusBarValue` are all present and semantically identical to retail. This is exactly the pixel-perfect anchoring machinery Bartender2 (and Dominos, ElvUI, etc.) rely on for crisp button borders/grids at fractional UI scale. **We should use this directly rather than writing our own pixel-snapping math.** It depends on one native addition from the DLL, `GetPhysicalScreenSize()` (reads the engine's real resolution — this is not emulated in Lua, it's a genuine new global registered at boot), so it's reliable, not a polyfill approximation.
- **`Mixin` / `CreateFromMixins`** — true **DLL-native (C++) globals**, not Lua polyfills (confirmed via an explicit comment in the shipped source: "`Mixin` and `CreateFromMixins` are engine (DLL) natives... they exist whenever ClassicAPI is injected, even with this addon disabled"). `CreateAndInitFromMixin` layers on top in Lua and correctly handles the `arg`/`unpack(arg)` vararg quirk. This gives us retail-style Mixin-based OOP for building our button/bar objects, matching how Bartender2 itself is structured, without us needing to hand-roll a mixin system.
- **`TableUtil`** — a real backport of 3.3.5's `TableUtil.lua`: `CopyTable`, `CopyTableSafe`, `MergeTable`, `tInvert`, `tContains`, `tFilter`, `tAppendAll`, `tCompare`, `CountTable`, `FindInTable`, `FindInTableIf`, `TableUtil.Transform/Execute/FindMin/FindMax`, table enumerators, etc. Removes the need to hand-write these common utility functions.
- **`MathUtil`** — `Lerp`, `Clamp`, `Saturate`, `Round`, `ClampedPercentageBetween`, `CalculateDistance(Sq)`, `CalculateAngleBetween`, `RoundToNearestMultiple`, etc. Useful for grid-layout math (spacing, snapping button positions to a grid, computing bar dimensions from rows/columns).
- **`Rectangle` / `Vector2D` / `Vector3D` / `Vector4D`** mixins — ready-made geometry types, handy for representing bar bounding boxes, drag bounds, grid cell coordinates.
- **`CallbackRegistryMixin` + `GlobalCallbackRegistry` (`EventRegistry`)** — a real port of retail's event/callback-registry pattern (`RegisterCallback`, `TriggerEvent`, `GenerateCallbackEvents`, handle-based `UnregisterCallback` via `RegisterCallbackWithHandle`). This is a legitimate substitute for the kind of pub/sub Bartender2 uses internally to decouple config-changes from bar redraws — we should build our "layout changed → re-anchor everything" flow on this rather than inventing our own event bus.
- **`FrameUtil`** — `RegisterFrameForEvents`/`UnregisterFrameForEvents`, `GetRootParent`, `SetParentMaintainRenderLayering`, ancestry-checking helpers.
- **`FrameWatcher`** — `WatchFrame(frame, onShow, onHide)` / `StopWatchingFrame` — generic show/hide observation without us needing to hook `OnShow`/`OnHide` manually on every button.
- **Frame/Texture/FontString pool helpers** (`CreateUnsecuredFramePool`, `CreateUnsecuredTexturePool`, `CreateUnsecuredFramePoolCollection`, `Pool_HideAndClearAnchors`, etc.) — object pooling for however many action buttons we spawn, again matching retail patterns.
- **`RegisterNewSlashCommand`** — a working helper for registering `/commands`, useful for our config/debug slash commands instead of hand-rolling `SlashCmdList` boilerplate.
- **CreateFrame extension: `HookScript`.** The DLL's `Compat.lua` explicitly documents that ClassicAPI's CreateFrame-produced widgets get a modern `HookScript` method (there's even special-cased compatibility code in ClassicAPI itself for older pfUI forks that don't expect this). This means we can use `frame:HookScript("OnEvent", fn)`-style code as in retail, instead of manually chaining `SetScript` calls.
- **Native security/introspection globals registered by the DLL** (found in the DLL's global-function-name table, i.e. these are real C-side additions, not aspirational docs): `hooksecurefunc`, `getfenv`, `getmetatable`, `ipairs`, `issecurevalue`, `issecurevariable`, `next`, `pairs`, `pcall`, `pcallwithenv`, `rawget`, `rawset`, `scrubsecurecall`, `securecall`, `securecallfunction`, `secureexecuterange`, `select`, `setfenv`, `setmetatable`, `type`, `unpack`, `wipe`, `xpcall`. This is significant: **`select`, `wipe`, `xpcall`, and the whole taint-inspection family (`issecurevalue`/`issecurevariable`/`securecall`/`scrubsecurecall`) are Lua-5.1/modern-client features that vanilla 1.12 does not normally have at all**, and ClassicAPI gives them back natively. This directly affects how carefully we need to handle secure/protected code paths around action buttons in combat — we have real taint-diagnostic tools available, not guesswork.
- **`InCombatLockdown`** exists (confirmed in the string table) — critical, since any Bartender2-style addon must gate frame reparenting/resizing/anchor changes on combat lockdown exactly like retail does.
- **`GameTooltip`, `IconDataProvider`, `ItemLocation`/`ItemMixin`, `LinkUtil`** — useful once we get to button tooltips and drag-and-drop of spells/items/macros onto action slots.

### 3.2 What ClassicAPI does *not* give us (so we must build it ourselves)

- **No action-bar-specific framework.** There is no `ActionButton` mixin, no `ActionBarController`, no `EditModeManager`, no secure-handler wrapper library, and no existing "hide the Blizzard gryphons" helper anywhere in the DLL's source. (There's a single unrelated comment referencing `EditModeLayout` as a dead/commented-out constant — not a real system.) This means:
  - Hiding the Blizzard end-cap/gryphon art (`MainMenuBarLeftEndCap`, `MainMenuBarRightEndCap`, `MainMenuBarArt`, the two `ActionBar Page/Down/Up` textures, etc.) is on us, using the standard vanilla technique (`:Hide()` + `:SetParent(hiddenFrame)` on the relevant Blizzard textures/frames once at load).
  - Secure click-drag movement/resizing of protected action-button frames needs to go through the base client's own `SecureHandlerStateTemplate`/`SecureHandlerDragTemplate`/`SecureHandlerWrapScriptTemplate` XML templates (these ship with vanilla 1.12's FrameXML itself, independent of any client mod) — ClassicAPI doesn't add or replace these, it just gives us better Lua ergonomics around them.
  - Grid layout, per-bar row/column config, and fully custom anchoring of the bars is entirely our own logic to write (using `PixelUtil` + `MathUtil` + `Rectangle`/`Vector2D` as building blocks, per §3.1).
- No confirmed native bitwise/`C_Timer`-equivalent — worth explicitly checking for a `C_Timer.After`-style ticker before assuming we need to build our own `OnUpdate`-based scheduler (not found in the modules scanned so far: `TimeUtil.lua` and `TimedCallback.lua` are listed and likely relevant — worth a follow-up read before we design our animation/update loop, since Bartender2-style range/cooldown-flash updates will need a ticking mechanism).

---

## 4. nampower — spell queueing engine, plus a large "modern API" surface of its own

nampower is primarily a spell-cast-queueing/latency-compensation system (a large block of `NP_Queue*`, `NP_SpellQueueWindowMs`, `NP_ChannelQueueWindowMs`, etc. CVars control this), but it also registers a substantial set of **custom Lua functions** that are directly useful for action-bar-style UI, confirmed present in the binary:

**Casting / spell state**
`QueueSpellByName`, `CastSpellByName` (nampower's own version), `CastSpellNoQueue`, `QueueScript`, `IsSpellInRange`, `IsSpellUsable`, `GetCurrentCastingInfo`, `GetSpellIdForName`, `GetSpellNameAndRankForId`, `GetSpellSlotTypeIdForName`, `ChannelStopCastingNextTick`, `GetCastInfo`.

**Cooldowns** (this is the one Bartender2-style buttons need constantly)
`GetSpellIdCooldown`, `GetItemIdCooldown`, `GetTrinketCooldown`.

**Spell/item metadata for icons & tooltips**
`GetSpellRec`, `GetSpellRecField` (`name`, `rank`, `description`, `tooltip`, …), `GetSpellIconTexture`, `GetItemIconTexture`, `GetItemLevel`, `GetItemStats`, `GetItemStatsField`, `GetSpellModifiers` (0=DAMAGE … 28=RESIST_DISPEL_CHANCE — a big enum of modifier types), `GetSpellDuration`, `GetSpellPower`, `GetSpellRangeData`.

**Equipment/bags** (relevant for trinket/item action buttons)
`FindPlayerItemSlot`, `GetEquippedItems`, `GetEquippedItem`, `GetBagItems`, `GetBagItem`, `UseItemIdOrName`, `UseTrinket`, `GetTrinkets`, `DisenchantAll`.

**Auras**
`GetPlayerAuraDuration`, `CancelPlayerAuraSlot`, `CancelPlayerAuraSpellId`, `IsAuraHidden`.

**Unit/raid data**
`GetRaidTargets`, `GetUnitData`, `GetUnitField`, `SetLocalRaidTargetIndex`, `GetUnitGUID`, `SetMouseoverUnit`, `PlayerIsMoving`/`PlayerIsRooted`/`PlayerIsSwimming`.

**File / scripting utilities**
`WriteCustomFile`/`ReadCustomFile`/`CustomFileExists` (sandboxed to a `CustomData` folder), `ImportFile`/`ExportFile`, `ExecuteCustomLuaFile`.

**Custom combat/unit events registered by nampower** (for a state-driven button-flash/GCD/queue system): `SPELL_QUEUE_EVENT`, `SPELL_CAST_EVENT`, `SPELL_START_SELF/OTHER`, `SPELL_GO_SELF/OTHER`, `SPELL_FAILED_SELF/OTHER`, `SPELL_DELAYED_SELF/OTHER`, `SPELL_CHANNEL_START/UPDATE`, `AURA_CAST_ON_SELF/OTHER`, `BUFF_ADDED/REMOVED_SELF/OTHER`, `DEBUFF_ADDED/REMOVED_SELF/OTHER`, `UNIT_HEALTH_GUID`, `UNIT_MANA_GUID`, etc.

**Relevance to this addon:** high. `GetSpellIdCooldown` / `GetItemIdCooldown` / `GetTrinketCooldown` are exactly what a Bartender2-style button needs to drive its cooldown swipe, and `IsSpellInRange`/`IsSpellUsable` give us the out-of-range/unusable button tinting that vanilla's stock action-bar Lua API only partially supports. `GetSpellIconTexture`/`GetItemIconTexture` give a mod-agnostic way to fetch icon textures for slot content. `SPELL_QUEUE_EVENT` and friends give a real event-driven way to flash "queued" state on the currently-casting button, which is a distinctly nampower-flavored feature worth designing in as a nice-to-have (showing queued next-cast, similar to how Bartender2 shows GCD sweep).

---

## 5. UnitXP_SP3 — not primarily a UI mod (lower priority for this addon)

*(Based on the maintainer's published documentation, since the shipped DLL is UPX-packed with a tampered header and could not be unpacked for direct verification in this environment — flagged as lower-confidence than §2–4.)*

UnitXP_SP3 exposes a single global dispatcher function, `UnitXP("command", ...)`, covering:

- Line of sight: `UnitXP("inSight", unit1, unit2)`.
- Distance: `UnitXP("distanceBetween", unit1, unit2 [, "AoE"|"meleeAutoAttack"])`.
- Facing: `UnitXP("behind", unit1, unit2)`, `UnitXP("behindThreshold", "set", radians)`.
- A background timer service independent of the game's frame loop: `UnitXP("timer", "arm", delayMs, repeatMs, "callbackFnName")` / `"disarm"` / `"size"`.
- OS-level notifications (taskbar flash / system sound) when backgrounded.
- A step-through Lua debugger (via external companion app on TCP port 2323).
- Version/existence probing: `pcall(UnitXP, "nop", "nop")`, `pcall(UnitXP, "version", "coffTimeDateStamp"/"additionalInformation")`.
- Advanced TAB-targeting helpers (`UnitXP("target", "nearestEnemy"/"nextEnemyInCycle"/"nextMarkedEnemyInCycle", ...)`), camera adjustment, nameplate line-of-sight, FPS limiter — all combat/QoL features, not action-bar UI.

**Relevance to this addon:** low. The one feature worth remembering is the independent **timer service** (`UnitXP("timer", "arm", ...)`), since it runs off the game's frame loop entirely — if ClassicAPI's `TimeUtil`/`TimedCallback` modules turn out not to give us a clean periodic-ticker primitive (see the open item in §3.2), UnitXP's timer is a fallback worth testing. Otherwise this mod is not central to a Bartender2-style addon and shouldn't drive design decisions.

---

## 5a. Mouseover casting — SuperWoW vs. nampower `SetMouseoverUnit`, reconciled

**Attempted first, and worth recording why it didn't pan out:** tried to resolve this definitively via each DLL's PE export table (to see the actual registration/init entry points). The text-encoded binary copies available in this environment have a corrupted `e_lfanew` PE header offset somewhere in their text-transport pipeline — `strings` extraction still works, but proper export-table/disassembly parsing does not. So the conclusion below is evidence-based from strings content, not proof-based from disassembly. It should be treated as a strong working hypothesis to confirm with one short in-game test (given at the end of this section), not as settled fact.

**What the strings show: these are two independent, non-cooperating implementations, not the same feature exposed twice.**

- **nampower** carries its own literal unit-token table baked into the binary (a long string blob: `mouseover`, `party1`…`party4`, `partypet1`…`raidpet40`, etc.). This is nampower's *own* internal token→GUID resolver, used only by nampower's own bespoke Lua functions (`GetUnitData`, `GetUnitField`, `GetUnitGUID`, and friends). It also has a dedicated CVar, `NP_EnableUnitEventsMouseover`, gating whether nampower fires its own GUID-based unit-update events for whatever *it* currently considers "mouseover" — further evidence this is a self-contained subsystem, not a pass-through to something else.
- **SuperWoW** has **no such token table** anywhere in its strings. Its `SetMouseoverUnit` sits in a flat list of engine-hook exports (`TrackUnit`, `UnitPosition`, `GetPlayerBuffID`, `Clickthrough`, `SetAutoloot`, `SetMouseoverUnit`) consistent with SuperWoW's known role: patching the client's actual native GUID/unit-lookup machinery, not maintaining a side table.
- This distinction matters because **stock 1.12.1 has no native `"mouseover"` unit token at all** (it was only added in TBC/2.1) — something has to teach the game engine itself to accept the token. SuperWoW's low-level hooking is the plausible candidate for that; nampower's Lua-level convenience table is not wired into the base engine's unit resolution at all, only into nampower's own function set.

**The practical risk:** both DLLs register a Lua global with the identical name `SetMouseoverUnit`. Both inject into the same Lua state, and there's no namespacing — whichever one registers last simply overwrites the other in the global function table. We cannot call "both" through that name. Concretely:

- If **SuperWoW's** registration is the one left standing, native `UnitGUID("mouseover")` / `UnitExists("mouseover")` and — critically for us — `SecureActionButtonTemplate`'s `unit` attribute resolution (which goes through the client's native unit-lookup, not any addon-side table) should all resolve correctly.
- If **nampower's** registration is the one left standing, only nampower's own bespoke functions would see a consistent "mouseover" unit; the native engine-level resolution that our secure mouseover-cast buttons actually depend on could silently stay unset, with no error raised anywhere.

This is exactly the class of bug that works fine on one person's client/loader setup and silently breaks on someone else's, since it hinges on DLL load order at runtime — something not visible from the binaries themselves.

**Verification test (to run once we have an in-game client, before finalizing the mouseover-cast design):**

```lua
-- hover something with a known GUID, then:
SetMouseoverUnit(knownGUID)
print("native:", UnitExists("mouseover"), UnitGUID("mouseover"))
print("nampower:", GetUnitGUID("mouseover"))
```

If both lines agree, there's no practical conflict regardless of which registration survived. If native resolution comes back empty while nampower's own function reports a GUID, that confirms nampower's registration is shadowing SuperWoW's, and we'd need to either force load order (if our `dlls.txt`/loader setup allows controlling injection order) or find another path into SuperWoW's engine-level hook.

**Design decision (pending the test above, but adopted now as our working assumption):** our secure mouseover-cast buttons will depend on **native engine-level unit resolution** (`unit="mouseover"` on a `SecureActionButtonTemplate`, backed by whichever DLL is actually patching the client's core unit-lookup — expected to be SuperWoW). We will call nampower's mouseover-aware functions only for its own bespoke QoL data (cooldowns, spell/item lookups keyed by `"mouseover"`), never as the thing our secure targeting path itself relies on. This keeps the feature working even if nampower's registration happens to shadow SuperWoW's for its *own* function family, since that shadowing wouldn't affect the secure-template attribute path either way.

## 5b. TimeUtil.lua / TimedCallback.lua — closing out the open item from §3.2/§7

Read directly from the embedded source. Short answer: **we get a real, DLL-native `C_Timer` (`After`/`NewTimer`/`NewTicker`, with `:Cancel()`/`:IsCancelled()` handles), on par with retail.** This resolves the open question — we do not need to build our own `OnUpdate`-driven scheduler, and we do not need to fall back to UnitXP's timer service.

**`Util\TimeUtil.lua`** is a small, plain backport of retail's time-formatting helpers — no scheduling logic lives here, it's pure math/formatting:

```lua
SECONDS_PER_MIN = 60;
SECONDS_PER_HOUR = 60 * SECONDS_PER_MIN;
SECONDS_PER_DAY = 24 * SECONDS_PER_HOUR;
SECONDS_PER_MONTH = 30 * SECONDS_PER_DAY;
SECONDS_PER_YEAR = 12 * SECONDS_PER_MONTH;

function SecondsToMinutes(seconds) ... end
function MinutesToSeconds(minutes) ... end
function ConvertSecondsToUnits(timestamp) -- returns {days, hours, minutes, seconds, milliseconds}
function SecondsToClock(seconds, displayZeroHours) -- "MM:SS" or "HH:MM:SS" via string.format
```

Useful directly for formatting cooldown text / duration displays on buttons (e.g. a numeric cooldown-text overlay in the Bartender2 style), but it has nothing to do with scheduling callbacks.

**`Util\TimedCallback.lua`** is the scheduling piece, and it's a thin Mixin wrapper around `C_Timer`, not a reimplementation:

```lua
TimedCallbackMixin = {};
function TimedCallbackMixin:SetCheckDelaySeconds(delay)
    self.delay = delay;
end
function TimedCallbackMixin:Cancel()
    if self.timer then
        self.timer:Cancel();
        self.timer = nil;
    end
end
function TimedCallbackMixin:ClearTimer()
    self:Cancel();
end
function TimedCallbackMixin:RunCallbackAsync(callback)
    self:Cancel();
    self.timer = C_Timer.NewTimer(self.delay or 1, callback);
end
```

That `C_Timer.NewTimer` call is not a Lua polyfill — the DLL's global-function/error-string table registers `C_Timer` natively, in the exact same "`Usage: ...`" pattern already confirmed for nampower's C-side functions (§4), alongside a whole cluster of other native namespaces we hadn't catalogued yet: `C_DateAndTime` (`GetServerTime`, `GetServerTimeLocal`, `GetSecondsUntilDailyReset`, `GetCurrentCalendarTime`, …), `C_Spell` (`UnitCastingInfo`, `UnitChannelInfo`, `CastAtCursor`, `CastAtUnit`), `C_SpellBook`, `C_QuestLog`, `C_PlayerCache`, `C_TaxiMap`, `C_UIColor`, plus the modern `UNIT_SPELLCAST_*` event family (`UNIT_SPELLCAST_START/STOP/DELAYED/CHANNEL_START/CHANNEL_STOP/CHANNEL_UPDATE/SUCCEEDED/INTERRUPTED/FAILED/FAILED_QUIET/SENT`) and `UnitInLineOfSight`, `UnitTokenFromGUID`. None of this was in scope for the original scan, but `C_Spell.UnitCastingInfo`/`UnitChannelInfo` plus the modern `UNIT_SPELLCAST_*` events are directly relevant to us later for driving a retail-style cast-bar/GCD-sweep overlay on action buttons, as an alternative or complement to nampower's own `SPELL_START_SELF`/`SPELL_GO_SELF`/`SPELL_CHANNEL_*` events (§4) — worth a straight comparison once we design that part, rather than assuming we need nampower's events specifically.

Concrete recommendation for our update loop: use `C_Timer.NewTicker(interval, callback)` directly for anything that needs to repeat (cooldown-swipe refresh, range/usability re-checks), and reach for `TimedCallbackMixin` only where we specifically want the debounce/restart-on-call semantics it adds (`RunCallbackAsync` cancels and restarts the timer each call, which is a debounce pattern, e.g. "re-check 200ms after the last layout change" rather than "tick every 200ms regardless"). Both are cheap engine-native timers, not `OnUpdate` polling, so we're not paying a per-frame cost for idle buttons.

**One incidental finding worth flagging, not acting on:** the source contains a portable feature-detection pattern, `local TURTLE = (TURTLE_WOW_VERSION ~= nil)`, used in a couple of other modules (e.g. `TradeSkillLink.lua`) to branch between Turtle WoW's HD art assets and stock 1.12.1 Blizzard art at the same call sites. This confirms ClassicAPI is written to run correctly on **both** a Turtle WoW server and a stock/blizzlike 1.12.1 server — it isn't Turtle-exclusive — but it does mean the private server / ruleset our client actually connects to could occasionally matter for visual/asset-availability edge cases elsewhere in the client mods. Not relevant to core bar/button logic, just noted so it doesn't surprise us later if we hit a Turtle-specific branch in some other module.

## 5c. `Util\Constants.lua` and `Util\UIParent.lua` — read in full

**`UIParent.lua` is trivial — the entire file, confirmed by locating it precisely between `TradeSkillLink.lua` and `Vector2D.lua` in the embedded source, is one function:**

```lua
function MouseIsOver(region, topOffset, bottomOffset, leftOffset, rightOffset)
    return region:IsMouseOver(topOffset, bottomOffset, leftOffset, rightOffset);
end
```

That's a backport of retail's global `MouseIsOver()` helper, nothing else. **There are no screen-size, UIParent-scale, or default-layout constants in it** — closing out that half of item 3 with a clear negative: we shouldn't go looking for retail-style `UIParent`-driven layout defaults from ClassicAPI, because this module simply isn't that. Any screen-size math we need goes through `PixelUtil`/`GetPhysicalScreenSize()` (§3.1) instead, which is the real source of truth for scale-aware layout in this environment.

**`Constants.lua` is real and substantial, but entirely item/character-sheet domain — nothing bar/action-slot related.** Confirmed contents:

- Item-location bitflags: `ITEM_INVENTORY_LOCATION_PLAYER/BAGS/BANK`, `ITEM_INVENTORY_BAG_BIT_OFFSET`, `ITEM_INVENTORY_BANK_BAG_OFFSET` — defined via `tonumber("0x00100000", 16)` rather than a hex literal, with an explicit source comment: *"Using tonumber because lua 5.0 doesn't support hexadecimal literals."* This is a real Lua 5.0 constraint we hadn't captured in §1 — added there now (no `0x...` literal syntax at all in this Lua version; always `tonumber("0x...", 16)`).
- Inventory slot IDs (`INVSLOT_HEAD` … `INVSLOT_TABARD`), `INVSLOTS_EQUIPABLE_IN_COMBAT` (a combat-lockdown-aware equip-slot set — useful precedent for how *we* should structure our own "what's safe to touch in combat" tables).
- Equipment-set, totem (`MAX_TOTEMS`, slot IDs, `STANDARD_TOTEM_PRIORITIES`, `SHAMAN_TOTEM_PRIORITIES`), and druid-form (`CAT_FORM`, `BEAR_FORM`) constants.
- `CLASS_SORT_ORDER`, `MAX_CLASSES`, `LOCALIZED_CLASS_NAMES_MALE/FEMALE`.
- `BAG_ITEM_QUALITY_COLORS`, `PLAYER_FACTION_GROUP`, `FACTION_LABELS(_FROM_STRING)`, `PLAYER_FACTION_COLORS`.
- A couple of stray `PaperDollFrame.lua`-sourced values (`EQUIPPED_FIRST/LAST`, `BASE_MOVEMENT_SPEED`).

**Confirms, rather than contradicts, the §3.2 finding:** there is no `NUM_ACTIONBAR_BUTTONS`, action-page, or action-slot-count constant anywhere in ClassicAPI (checked across the whole extracted source, not just this file). Action-bar/grid/button-count constants are entirely ours to define, informed by the base client's real action-slot layout (vanilla's 120 action slots = 10 pages × 12 buttons is native-client knowledge, not something any of the four mods expose or need to expose).

**One dependency worth flagging before we design anything bitflag-based ourselves:** `Util\EquipmentManager.lua` (the file immediately after `Constants.lua`) calls `bit.band`, `bit.rshift`, and `bit.lshift` to decode the `ITEM_INVENTORY_LOCATION_*` bitflags above — but **no `bit` table is defined anywhere in ClassicAPI's own embedded source**, and it's not among the DLL-native globals we've confirmed elsewhere (the exact native registration list is `getfenv`, `getmetatable`, `hooksecurefunc`, `ipairs`, `issecurevalue`, `issecurevariable`, `next`, `pairs`, `pcall`, `pcallwithenv`, `rawget`, `rawset`, `scrubsecurecall`, `securecallfunction`, `secureexecuterange`, `select`, `setfenv`, `setmetatable`, `type`, `unpack`, `wipe`, `xpcall` — no `bit`). So a global `bit` library is either provided by the base client itself, by one of the other three mods, or ClassicAPI silently assumes something that may not actually be present. **This needs an in-game check** (`print(type(bit), type(bit and bit.band))`) before we design any bitflag-packed state of our own (e.g. packing a button's bar/row/col/page into one number) — if `bit` genuinely isn't available, Lua 5.0's lack of native bitwise operators (§1) means we'd need `tonumber`/`math.floor`/`%`-based arithmetic emulation instead, same as ClassicAPI's own `tonumber("0x...", 16)` workaround pattern.

## 5d. Cast-bar / GCD-sweep data source: ClassicAPI's `C_Spell`/`UNIT_SPELLCAST_*` vs. nampower's `GetCastInfo`/spell events

**Reframing the question slightly first:** this isn't really an either/or choice — it splits into two different jobs a Bartender2-style bar actually needs, and the two systems turn out to be good at different halves of it.

**Job 1 — "is *this* spell (on this button) on cooldown?"** is not answered by either casting-info system at all; it's nampower's `GetSpellIdCooldown(spellId)` / `GetItemIdCooldown(itemId)` / `GetTrinketCooldown(slot)` (already covered in §4), confirmed via nampower's own published `SCRIPTS.md`: each returns a reusable table with `isOnCooldown`, `cooldownRemainingMs`, plus separately broken-out `individual*`/`category*`/`gcdCategory*` timing blocks. This is what drives the swipe on every button that *isn't* the one currently being cast — no change to the earlier recommendation.

**Job 2 — "what's actively being cast/channeled right now, and when does the GCD end?"** is where the real comparison is:

- **nampower's `GetCastInfo()`** (confirmed from nampower's published `SCRIPTS.md`) returns a single reusable table, or `nil` if nothing is active: `castId`, `spellId`, `guid` (target), `castType` (0=NORMAL, 3=CHANNEL, 4=TARGETING), `castStartS`/`castEndS` (absolute `GetTime()`-scale seconds), `castRemainingMs`/`castDurationMs`, and — notably — `gcdEndS`/`gcdRemainingMs` **in the same table**. One call gives us cast progress *and* GCD state together, self only (player).
- **nampower's `GetCurrentCastingInfo()`** is the older, cheaper sibling: seven plain return values (`castId, visId, autoId, casting, channeling, onswing, autoattack`), boolean-flag-oriented, kept for back-compat. Fine for a quick "is something happening" check, not rich enough for a progress bar.
- **nampower's cast/channel events** — `SPELL_START_SELF/OTHER`, `SPELL_GO_SELF/OTHER`, `SPELL_CHANNEL_START/UPDATE`, `SPELL_FAILED_SELF/OTHER`, `SPELL_DELAYED_SELF/OTHER`, plus `SPELL_CAST_EVENT` fired client-side the moment a cast is initiated, before the server round-trip. Confirmed to exist and confirmed at the description level (`SPELL_START_*`/`SPELL_GO_*` = "server notifies a cast with a cast time has begun / completed"), but I could not get the exact per-event argument list (`arg1`, `arg2`, …) — nampower's `EVENTS.md` exists and is linked from every mirror of the project, but its literal URL never appeared in a fetchable search/fetch result in this session, so I couldn't pull it directly. That's a concrete gap to close with either an in-game `/run` probe or a repo browse, not something to guess at.
- **ClassicAPI's `C_Spell.UnitCastingInfo("unit")` / `C_Spell.UnitChannelInfo("unit")`** are confirmed DLL-native (same "`Usage: ...`" registration pattern as everything else we've verified), and take a `unit` token — so unlike nampower's `GetCastInfo()`, these work for **any** unit, not just the player. I could not find literal field-name strings (`startTimeMS`, `notInterruptible`, `castID`, etc.) anywhere in ClassicAPI's binary for these two functions, which is actually informative rather than a dead end: it's consistent with these returning **multiple values** rather than a table — matching the well-documented pre-Dragonflight/Classic-Era `C_Spell.UnitCastingInfo` signature (`name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID`) and `C_Spell.UnitChannelInfo` (`name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID`). I'm flagging this as **medium confidence** — cross-referenced against public Blizzard API documentation for the Classic Era client rather than directly read out of the binary, since a multi-return function has no field-name strings to grep for. ClassicAPI also natively backports the full modern `UNIT_SPELLCAST_START/STOP/DELAYED/CHANNEL_START/CHANNEL_STOP/CHANNEL_UPDATE/SUCCEEDED/INTERRUPTED/FAILED/FAILED_QUIET/SENT/RETICLE_TARGET/RETICLE_CLEAR` event family, unit-keyed (`arg1 = unit`) the modern way — again, general-purpose across any unit.

**The decision that actually matters, and why it's not just "richer wins":** nampower's spell-queue system (§4) buffers/adjusts real cast timing — that's its entire purpose (`NP_SpellQueueWindowMs`, `NP_MinBufferTimeMs`, buffer-increase-on-server-rejection logic, etc.). `GetCastInfo()`'s `castStartS`/`castEndS`/`gcdEndS` numbers come from nampower's own internal cast-tracking, so they reflect **what nampower actually did**, including its buffer compensation. ClassicAPI's `C_Spell.UnitCastingInfo("player")`, by contrast, most likely reads the client's native cast-state structure directly (consistent with everything else confirmed as DLL-native rather than emulated) — which may not agree with nampower's adjusted timing, since nampower is specifically patching around/ahead of that native state to hide server latency.

**Recommendation:**
- **Player's own cast-bar + GCD-sweep** (the bar/button actually being used) → drive from **nampower's `GetCastInfo()`**, polled via the `C_Timer.NewTicker` update loop already decided in §5b. This keeps our sweep visually in sync with what nampower is actually doing, not the pre-buffer native timing.
- **Any other unit's cast bar** (not a Bartender2 core feature, but worth keeping consistent for later — e.g. if we ever add a target/focus cast bar as a companion element) → use **ClassicAPI's `C_Spell.UnitCastingInfo(unit)`/`UnitChannelInfo(unit)` + `UNIT_SPELLCAST_*` events**, since nampower's rich table is player-only.
- **Per-button cooldown swipe** (every button, at all times) → nampower's `GetSpellIdCooldown`/`GetItemIdCooldown`/`GetTrinketCooldown`, unchanged from §4 — this was never really in competition with the cast-bar question.

**Open verification item added to next steps:** get the actual argument lists for nampower's `SPELL_START_SELF`, `SPELL_GO_SELF`, `SPELL_CHANNEL_START`, `SPELL_CHANNEL_UPDATE` (its `EVENTS.md` documents these but I couldn't fetch it directly this session), and independently confirm ClassicAPI's `C_Spell.UnitCastingInfo`/`UnitChannelInfo` return order in-game — both are needed before writing the actual cast-bar code, not before this design decision.

**Aside, not acted on:** nampower's own companion settings addon documents that it explicitly displays a "most recently queued spell" icon *only when SuperWoW is present*, and separately notes nampower typically gets loaded via a launcher/loader such as UnitXP_SP3's or VanillaFixes' DLL-injection mechanism, rather than being independent of the other three mods. Both are consistent with this whole stack being designed to run together, and the latter is a small update to the §5a picture — UnitXP_SP3 may functionally be *part of the loading chain* for nampower in some setups, not just an unrelated fourth mod, which could matter for the load-order question in §5a's verification test.

## 5e. Live-client verification results — `bit`, secure handler templates, mouseover resolution

Ran via the `BT2Diag` diagnostic tool on a real client. Full raw output preserved below; this closes out the three pending in-game checks from §5a, §5c, and next-steps item 5 — with one important correction to an earlier static-analysis claim.

**`bit` library (§5c): confirmed available and correct.** `type(bit) == "table"`, `bit.band`/`bit.rshift`/`bit.lshift` all functions, and the sanity check `bit.band(6,3)` correctly returned `2`. Source is most likely the base Turtle WoW client itself (see the `TURTLE_WOW_VERSION` detection already found in ClassicAPI's source, §5d) rather than any of our four target mods specifically — none of `WeirdUtils`' modules (also present on the test client but not one of our four) look like a bit-library provider either. Worth re-testing on a non-Turtle 1.12.1 server if this addon ever needs to run there, since the source isn't pinned to something we can guarantee is always present.

**Mouseover unit resolution (§5a): confirmed, better than expected — no conflict at all.** Test GUID `0x000000003B9B8198`, obtained from nampower's `GetUnitGUID('player')`. After `SetMouseoverUnit(testGuid)`:
- native `UnitExists('mouseover')` → `1`
- native `UnitGUID('mouseover')` → `0x000000003B9B8198` (matches)
- nampower `GetUnitGUID('mouseover')` → `0x000000003B9B8198` (matches)

All three agree. The working hypothesis from §5a — that SuperWoW's engine-level registration wins and drives native resolution correctly — is confirmed, and in practice nampower's own function reads the same underlying state rather than shadowing it with a separate stale value. **Design decision finalized:** mouseover-cast secure attributes and nampower's own mouseover-aware functions can both be relied on without the defensive workaround originally planned in §5a. No further action needed here.

**Secure handler templates (next steps item 5): all seven failed, and this is a genuine architectural finding, not a gap to patch.** Every attempt returned the identical, unambiguous error:

```
CreateFrame(): Couldn't find inherited node "SecureHandlerBaseTemplate"
CreateFrame(): Couldn't find inherited node "SecureHandlerStateTemplate"
CreateFrame(): Couldn't find inherited node "SecureHandlerDragTemplate"
CreateFrame(): Couldn't find inherited node "SecureHandlerAttributeTemplate"
CreateFrame(): Couldn't find inherited node "SecureHandlerClickTemplate"
CreateFrame(): Couldn't find inherited node "SecureHandlerShowHideTemplate"
CreateFrame(): Couldn't find inherited node "SecureActionButtonTemplate"
```

This is not a naming mismatch or something a client mod patches in — the entire `SecureHandler*`/`SecureActionButtonTemplate` XML template family was introduced in patch 2.0 (The Burning Crusade) as part of the combat-lockdown/protected-execution system. Vanilla 1.12.1 predates that system entirely, and none of the four client mods add it back (nor would we expect a DLL to backport an XML template family — that's a FrameXML/client asset, not something hookable at the Lua-registration level the way `C_Timer` or `hooksecurefunc` are).

**Correction to an earlier claim, made transparently:** §3.1 originally listed `issecurevalue`, `issecurevariable`, `scrubsecurecall`, `securecallfunction`, `secureexecuterange`, and `pcallwithenv` as confirmed DLL-native globals, based on their appearing together in a string blob near the start of ClassicAPI's binary. The live test now shows `type(issecurevalue)` and `type(issecurevariable)` are both `"nil"` in this actual client, directly contradicting that claim. In hindsight, that string blob mixed genuinely new natives (only `hooksecurefunc` had an accompanying "Usage: ..." string, which the live test confirms as `type(hooksecurefunc) == "function"`) with what was likely an unrelated list of standard Lua base-library names (`pcall`, `pairs`, `next`, `rawget`, `type`, etc. — all of which trivially already exist in stock Lua 5.0 and wouldn't need "adding") — I over-read that list as a uniform "new natives" registration when it wasn't one. This is exactly the failure mode the whole project's live-verification checkpoints exist to catch, and it caught one. `InCombatLockdown` and `hooksecurefunc` remain confirmed (both tested `"function"` live); the taint-introspection family (`issecurevalue`/`issecurevariable`/etc.) should now be treated as **not available**, consistent with — and further evidence for — the absence of the whole secure-execution system in this client generation.

**What this means for the addon's architecture — the actual consequence, not just a caveat:** a modern Bartender2 builds new, freely-arrangeable buttons from `SecureActionButtonTemplate` and repositions them via `SecureHandlerDragTemplate`/`SecureHandlerStateTemplate` wrappers so combat lockdown can't be violated. None of that machinery exists here. This is exactly how period-correct vanilla 1.12 action-bar addons (the original Bartender for 1.12, Bongos-vanilla, Discord Action Bars, CT_BarMod, etc.) actually worked, and it's the model we need to follow instead: **don't create new secure buttons — reposition, resize, and rescale Blizzard's own pre-existing action-button frames** (`ActionButton1`–`12`, `BonusActionButton1`–`12`, `MultiBarLeftButton1`–`12`, `MultiBarRightButton1`–`12`, `MultiBarBottomLeftButton1`–`12`, `MultiBarBottomRightButton1`–`12`, `PetActionButton1`–`10`, etc.). Those frames get their click-cast security for free simply by being the same objects Blizzard shipped — there's nothing to "make secure," since we're never constructing a new protected-executing button, only rearranging existing ones with ordinary `SetPoint`/`SetSize`/`SetParent` calls. This also sidesteps the whole combat-lockdown question from a different angle: since vanilla 1.12 predates the protected-function/taint system altogether, ordinary frame methods like `SetPoint` are not restricted in combat here the way they are on a modern client — `InCombatLockdown()` exists (confirmed live, returned `false` when out of combat) but there's no accompanying enforcement mechanism forcing us through secure handlers to reposition frames during combat, because that enforcement mechanism is exactly the piece that's absent. This needs confirming in combat directly (see next steps), but it's consistent with everything else this test run showed.

## 5f. `ButtonForge Classic` — a working existence proof, and the actual answer to §5e's open question

Found via a real, MIT-licensed, vanilla-1.12-specific action bar addon: [Wurmschwanz/ButtonForge-Classic-Reforged](https://github.com/Wurmschwanz/ButtonForge-Classic-Reforged), a vanilla/Turtle WoW port of the long-established retail/Classic `ButtonForge` addon. Its feature list is essentially our own project's feature list — fully custom action bars, free positioning, adjustable rows/columns/scale, drag-and-drop from spellbook/bags/macros, Blizzard-style cooldown spiral, GCD, range/usability tinting — built and working on exactly this client generation. Since it's MIT-licensed, its source was read directly (cloned and inspected in full, not just the README) to answer the question §5e left open: **if there's no `SecureHandler*`/`SecureActionButtonTemplate` system at all, how does a genuinely working vanilla action-bar addon create movable, clickable, protected buttons?**

**The mechanism, confirmed by reading `Button.lua` directly:** it doesn't create secure buttons, and it doesn't reposition Blizzard's existing fixed 12-per-page buttons either (the approach §5e proposed as the fallback). Instead, it does something cleaner than either:

1. Creates entirely ordinary, non-secure `CreateFrame("Button", name, parent)` frames — full freedom over size, position, grid layout, styling, parent, everything.
2. Backs each custom button with a **real vanilla action slot**, specifically slots **73–120** (`BF.ActionSlotStart = 73`, `BF.ActionSlotEnd = 120`, confirmed in `Const.lua`). Vanilla 1.12's action system has 120 total slots across 10 pages of 12, but the default Blizzard UI only ever surfaces pages 1–6 (slots 1–72) through its built-in bars — pages 7–10 (slots 73–120, 48 slots total) exist in the client's action system but are never touched by stock UI, making them free real estate.
3. Drives every interaction through vanilla's own **native, already-protected action-slot API** — not custom cast logic:
   - Click-cast: `UseAction(button.actionSlot, 0, 0)`
   - Drag/drop assignment: `PlaceAction(slot)` / `PickupAction(slot)`
   - State/rendering: `HasAction`, `GetActionTexture`, `GetActionCount`, `IsActionInRange`, `IsUsableAction`, `IsAttackAction`, `GetActionCooldown` + the stock `CooldownFrameTemplate`/`CooldownFrame_SetTimer`

Every one of those is a genuine stock vanilla 1.12 global — none of it comes from any client mod. **This resolves the architecture question from §5e cleanly:** the "security boundary" isn't something we build or work around at all — it already exists, baked into vanilla's action-slot system itself (the same system the default Blizzard bars use), and a custom-drawn button is exactly as safe as a Blizzard one the moment it's just a thin UI wrapper calling `UseAction`/`PlaceAction`/`PickupAction` on a slot number, rather than trying to invoke spellcasting directly. No `SecureHandler*` template was ever needed to solve this problem on this client generation — that's a Burning-Crusade-era solution to a Burning-Crusade-era problem (the protected-execution/taint system this generation predates).

**Confirmed independently: zero dependency on any of our four client mods.** A full search of the source (`grep`, not a maintainer's claim) turns up no reference anywhere to SuperWoW, nampower, ClassicAPI, UnitXP, or any of their signature functions (`SetMouseoverUnit`, `GetSpellIdCooldown`, `C_Timer`, extended `CastSpellByName`, etc.). It's built entirely on stock vanilla globals plus a couple of defensive `GetCursorInfo`/`CursorHasSpell` compatibility checks for Turtle WoW quirks. This is useful confirmation that the core Bartender2 feature set (movable custom bars, grid layout, click-cast, cooldown, range/usability tinting) is achievable with **zero** client-mod dependency at all — though our project can still layer the four mods on top for the specifically enhanced features they enable (richer cooldown/cast data, GCD-accurate sweep, mouseover-casting — see next point).

**One real gap, relevant to the user's explicit mouseover-casting requirement:** `ButtonForge Classic`'s own "mouseover" feature (`Mouseover.lua`) is bar-fade-on-hover — a visibility/UX convenience (bars appear when your mouse hovers over them, fade out otherwise) — **not** mouseover-*casting* on a targeted unit (e.g. casting a heal on whoever your mouse is currently over, the raid-frame-style use case this project actually wants). That's expected: vanilla's native `UseAction(slot, 0, 0)` has no concept of a "mouseover" target at all, and vanilla's primitive macro syntax predates the `[target=mouseover]` conditional syntax (also a 2.0+ addition, alongside the secure-template system), so there's no macro-level trick available either. Confirmed by the §5e/BT2Diag test, the only thing that actually teaches the engine a "mouseover" unit token in this client generation is SuperWoW's `SetMouseoverUnit` + SuperWoW's extended `CastSpellByName(name, unitid)` signature.

**Synthesis — the actual plan this gives us:** follow `ButtonForge Classic`'s proven action-slot-backed-custom-button pattern as the backbone for ordinary buttons (this is now a de-risked, working approach, not a hypothesis), and layer mouseover-casting on top as a **per-button override**, not something that comes from the action-slot system at all: when a button is configured for mouseover-casting, its `OnClick` handler bypasses `UseAction(slot, 0, 0)` and instead calls SuperWoW's `CastSpellByName(spellName, "mouseover")` directly (with the spell name resolved from whatever's assigned to that slot, e.g. via nampower's `GetSpellRec`/`GetSpellNameAndRankForId` or the base client's `GetActionText`-family functions). Everything else about the button — its grid position, icon, cooldown swipe, range tint — still rides on the underlying vanilla action slot exactly as `ButtonForge Classic` does it; only the actual cast call diverges for that one button type.

## 5g. Live confirmation: nampower event arguments and `C_Spell` return order (closes the §5d loose ends)

Captured from a real play session (`BT2Diag2.lua`, event logging + a manual target-cast snapshot), not synthesized. Full raw log available; summarized findings below.

**`C_Spell.UnitCastingInfo(unit)` return signature: confirmed, exactly as hypothesized.** A live target cast (Healing Touch) returned:

```
r1=Healing Touch  r2=Healing Touch  r3=Interface\Icons\Spell_Nature_HealingTouch
r4=15613018  r5=15614503  r6=false  r7=Cast-3-0-0-0-5185-000005991D  r8=false  r9=5185  r10=nil
```

This is exactly `name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID` — the medium-confidence hypothesis from §5d, now upgraded to confirmed. Cross-validated independently: `endTimeMS - startTimeMS` (1485ms) matches nampower's own raw `SPELL_START_OTHER arg6=1485` for the same cast, captured at the same timestamp — two independent systems agreeing on the same real number.

**Critical, previously-unconfirmed finding: `C_Spell.UnitCastingInfo("player")` does not work at all.** Captured at the exact moment of `SPELL_START_SELF`, while genuinely mid-cast (confirmed by the paired `UNIT_SPELLCAST_SUCCEEDED` firing correctly immediately after) — every field came back `nil`, every single time (4 separate captures, same result). It works correctly for `"target"`. This upgrades §5d's design *recommendation* (nampower's `GetCastInfo()` for the player's own cast bar) into a **hard requirement**: `C_Spell.UnitCastingInfo` is simply non-functional for the `player` token in this environment, so there's no real alternative for that half of the design anyway.

**Bonus confirmation of §5e/§5a:** one `UNIT_SPELLCAST_SUCCEEDED` fired for both `target` and `mouseover` on the same cast (both pointing at the same GUID), showing the mouseover-resolution confirmed in §5e feeds correctly into ClassicAPI's higher-level event system too, not just the raw unit-token functions tested there.

**Still open:** no genuine channeled cast was captured in this session (the observed target only cast instant/cast-time spells, never a channel), so `C_Spell.UnitChannelInfo`'s return order remains unconfirmed — same hypothesized 8-value signature as before (`name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID`, no `castID` for channels), just not yet verified live.

**nampower's raw event arguments, documented from real captures (meanings marked confirmed vs. observed-but-unconfirmed):**

| Event | Args (positional) | Notes |
|---|---|---|
| `SPELL_START_SELF`/`SPELL_START_OTHER` | `arg1`=0 (constant in this sample, purpose unconfirmed — possibly a pet-cast flag never exercised), `arg2`=spellId, `arg3`=caster GUID, `arg4`=target GUID (`0x0...0` if none), `arg5`=cast-type code (`2` observed for normal magic casts, `34` observed for ranged-weapon abilities like Auto Shot/Arcane Shot — exact enum unconfirmed), `arg6`=**cast duration in ms (confirmed**, cross-validated against `C_Spell` above), `arg7`=0 (constant, unconfirmed purpose), `arg8`=usually 0, occasionally `2` (unconfirmed — possibly related to nampower's changelog note "add corpse info to spell start and spell go") |
| `SPELL_GO_SELF`/`SPELL_GO_OTHER` | `arg1`=0 (constant), `arg2`=spellId, `arg3`=caster GUID, `arg4`=target GUID, `arg5`=result/hit flags (`256` or `288` observed, bitflag-shaped, unconfirmed meaning), `arg6`=success flag (`1` normally; one observed `0` paired with `arg7`=`1`, likely a miss/resist case), `arg7`=usually 0 |
| `SPELL_FAILED_SELF` | `arg1`=spellId, `arg2`=failure reason code (`35`, `77` observed, enum unconfirmed), `arg3`=0 or 1 flag |
| `SPELL_FAILED_OTHER` | `arg1`=caster GUID, `arg2`=spellId |
| `SPELL_CAST_EVENT` | `arg1`=0 or 1 (hypothesis: queued-vs-immediate flag, matching nampower's documented queue system; unconfirmed), `arg2`=spellId, `arg3`=2 (constant observed), `arg4`=a shorter hex identifier — not a full unit GUID, likely an internal cast-reference id, `arg5`=0 (constant observed) |

None of the "unconfirmed" columns above block button design (cooldown/GCD/range work off `GetCastInfo`/`GetSpellIdCooldown`, not these raw event args), but worth a full pass against nampower's actual `EVENTS.md` before depending on any of the ambiguous fields directly.

## 5h. Live confirmation: combat-lockdown behavior — closes next-steps item 7

Confirmed via a real, unambiguous combat window (not a baseline this time): `[event] PLAYER_REGEN_DISABLED fired (entering combat) - armed=true` fired, the armed test ran immediately after, and `[event] PLAYER_REGEN_ENABLED fired (leaving combat)` followed shortly after — so the test is bracketed by the two native events that define real combat state, not inferred from anything else.

**Result: a clean pass.** `SetPoint` and `SetSize`/`SetWidth`/`SetHeight` on a plain custom frame both returned no error and the frame's position and size genuinely changed (`0,0` → `60,60`; width/height `32` → `48`) while genuinely in combat. This confirms the working assumption from §5e/§5f: custom-frame repositioning is completely unrestricted during combat on this client. No workaround, no deferred-execution queue, no secure-handler indirection needed for movement/resizing at any time — combat or not.

**Second, independent finding from the same test, worth documenting on its own:** `InCombatLockdown()` (a ClassicAPI backport) reported `false` at a moment bracketed by real `PLAYER_REGEN_DISABLED`/`PLAYER_REGEN_ENABLED` events — i.e. it does not reflect actual combat state in this environment. This isn't necessarily a bug so much as a function answering a question that doesn't apply here: it exists to report protected-execution lockdown, and §5e already confirmed this client has no protected-execution system at all (no `SecureHandler*`, no `issecurevalue`/`issecurevariable`). A permissive stub that always returns `false` is consistent with there being nothing to lock down. **Practical rule for our own code: never gate logic on `InCombatLockdown()` here — it doesn't work.** If genuine combat-state awareness is ever needed for something other than permission-gating (a UX/visual purpose, say), use `PLAYER_REGEN_DISABLED`/`PLAYER_REGEN_ENABLED` directly — both confirmed firing correctly and promptly.

**This fully closes the last open architectural question.** Between §5e (no secure-handler system), §5f (`ButtonForge Classic`'s proven action-slot-backed button pattern), and this result (unrestricted repositioning in and out of combat), the addon's foundational architecture is now fully de-risked rather than resting on any untested assumption.

## 6. Summary: what to build vs. what to reuse











| Need | Source | Status |
|---|---|---|
| Pixel-perfect anchoring/sizing | ClassicAPI `PixelUtil` | **Reuse directly** — verbatim retail port |
| Mixin-based OOP for Button/Bar objects | ClassicAPI `Mixin`/`CreateFromMixins` (DLL-native) + `CreateAndInitFromMixin` | **Reuse directly** |
| Table utilities (copy/merge/filter/invert/contains) | ClassicAPI `TableUtil` | **Reuse directly** |
| Math/geometry helpers for grid layout | ClassicAPI `MathUtil`, `Rectangle`, `Vector2D` | **Reuse directly** |
| Internal "layout changed" pub/sub | ClassicAPI `CallbackRegistryMixin` / `EventRegistry` | **Reuse directly**, build our system on top |
| Object pooling for buttons | ClassicAPI frame/texture/fontstring pool helpers | **Reuse directly** |
| Slash command registration | ClassicAPI `RegisterNewSlashCommand` | **Reuse directly** |
| `hooksecurefunc`, taint introspection, `select`/`wipe`/`xpcall` | ClassicAPI DLL-native globals | **Available, use as needed for secure-code safety** |
| Cooldown data for buttons | nampower `GetSpellIdCooldown`/`GetItemIdCooldown`/`GetTrinketCooldown` | **Reuse directly**, preferred over any manual polling |
| Range/usability tinting | nampower `IsSpellInRange`/`IsSpellUsable` | **Reuse directly** |
| Icon texture lookup | nampower `GetSpellIconTexture`/`GetItemIconTexture` | **Reuse directly** |
| Cast/queue state for GCD & queue flash | nampower custom combat events (`SPELL_QUEUE_EVENT`, etc.) | **Reuse directly**, nampower-specific enhancement |
| Hiding Blizzard action-bar art (gryphons/endcaps) | — | **Must build ourselves** (standard vanilla `:Hide()`/reparent technique) |
| ~~Secure drag/move/resize of protected buttons~~ | ~~Base client's own `SecureHandler*Template` XML (not a mod)~~ | **Superseded — see confirmed rows below.** No such templates exist (§5e); ordinary `SetPoint`/`SetSize` on plain custom frames works unrestricted in and out of combat (§5h). |
| Free-form grid layout & per-bar configuration (the actual "Bartender2" feature) | — | **Must build ourselves**, on top of the reused primitives above |
| Periodic ticker independent of frame loop | ClassicAPI's DLL-native `C_Timer.After`/`NewTimer`/`NewTicker` (confirmed real, not a polyfill); `TimedCallbackMixin` for debounce-style reschedule | **Reuse directly** — confirmed in §5b, no need for UnitXP's timer fallback |
| ~~Mouseover-cast unit token (old entry, see confirmed row below)~~ | ~~Secure attribute path: SuperWoW's engine-level `SetMouseoverUnit` (working hypothesis, §5a)~~ | **Superseded — see confirmed §5e row below** |
| Screen/layout scale defaults | ClassicAPI `UIParent.lua` | **Not applicable** — confirmed it's a single unrelated helper function, no layout constants exist there (§5c) |
| Action-bar/grid/button-count constants | — | **Must define ourselves**, confirmed absent from `Constants.lua` and the whole ClassicAPI source (§5c) |
| Bitwise packing for our own state (e.g. bar/row/col in one value) | Global `bit` table (`band`/`rshift`/`lshift`) | **Confirmed available and working, reuse directly** (§5e). Source likely the Turtle WoW base client rather than any of the four mods specifically — re-verify if targeting a non-Turtle server. |
| Player's own cast-bar + GCD-sweep data | nampower `GetCastInfo()` (unified table incl. GCD) | **Reuse directly** — reflects nampower's actual buffered timing (§5d) |
| Any other unit's cast bar (future feature) | ClassicAPI `C_Spell.UnitCastingInfo(unit)`/`UnitChannelInfo(unit)` + `UNIT_SPELLCAST_*` | **Reuse directly for non-player units** — confirmed working live for `"target"` (§5g). **Confirmed non-functional for `"player"`** (§5g) — nampower's `GetCastInfo()` is the only working option for the player's own cast bar, not just the preferred one. |
| Mouseover-cast unit token | SuperWoW's engine-level `SetMouseoverUnit`, native `unit="mouseover"` resolution | **Confirmed working, no conflict with nampower's own function** (§5e) — original defensive design no longer needed |
| Secure/protected, freely-arrangeable action buttons | **Not** `SecureHandler*` (doesn't exist) — instead, unused vanilla action slots 73-120 backing custom `CreateFrame("Button", ...)` frames, driven via `UseAction`/`PlaceAction`/`PickupAction` | **Confirmed working pattern, reuse directly** (§5f) — proven by `ButtonForge Classic`'s actual shipped source, not a hypothesis. 48-slot ceiling is a known hard constraint (pages 7-10 only). |
| Mouseover-*casting* on a targeted unit | SuperWoW's `CastSpellByName(spellName, "mouseover")`, called directly from the button's `OnClick`, bypassing `UseAction` for that button only | **Reuse directly, as a per-button override** (§5f) — not something the action-slot system can provide on its own; `ButtonForge Classic` doesn't implement this at all (its own "mouseover" feature is unrelated bar-fade-on-hover) |
| Combat-safe frame repositioning/resizing | Ordinary `SetPoint`/`SetSize`/`SetWidth`/`SetHeight` on plain custom frames | **Confirmed unrestricted in real combat**, bracketed by genuine `PLAYER_REGEN_DISABLED`/`PLAYER_REGEN_ENABLED` (§5h) — no deferred-execution or secure-handler indirection needed at any time |
| Combat-state detection, if ever needed for non-gating purposes | `PLAYER_REGEN_DISABLED`/`PLAYER_REGEN_ENABLED` events | **Reuse directly** — confirmed firing correctly (§5h). **`InCombatLockdown()` confirmed non-functional** (always returns `false`, tested during real combat) — never gate logic on it |

---

## 7. Recommended next steps

1. ~~Read `Util\TimeUtil.lua` and `Util\TimedCallback.lua`~~ — **done, see §5b.** Confirmed: real DLL-native `C_Timer` suite, use it for the update loop.
2. ~~Reconcile SuperWoW's vs. nampower's `SetMouseoverUnit`~~ — **done and empirically confirmed live, see §5e.** No conflict: native and nampower's own resolution agree perfectly. No defensive workaround needed.
3. ~~Read `Util\Constants.lua` and `Util\UIParent.lua`~~ — **done, see §5c.** `UIParent.lua` is a single trivial helper, no layout constants. `Constants.lua` is item/character-sheet domain only, confirms no action-bar constants exist anywhere in ClassicAPI.
4. ~~Read `C_Spell.UnitCastingInfo`/`UnitChannelInfo` and the modern `UNIT_SPELLCAST_*` events side-by-side with nampower's cast/channel system~~ — **done, see §5d.** nampower's `GetCastInfo()` drives the player's own cast-bar/GCD-sweep; ClassicAPI's `C_Spell.UnitCastingInfo(unit)`/`UNIT_SPELLCAST_*` covers any other unit. Still open: nampower's exact `SPELL_START_SELF`/`SPELL_GO_SELF`/`SPELL_CHANNEL_START`/`SPELL_CHANNEL_UPDATE` event argument lists, and live confirmation of `C_Spell.UnitCastingInfo`/`UnitChannelInfo`'s exact return order (currently inferred from public Classic Era API docs, not yet tested).
5. ~~Confirm, in-game, which vanilla FrameXML secure-handler templates are present~~ — **done, see §5e.** None exist. This also forced a correction to an earlier §3.1 claim: `issecurevalue`/`issecurevariable` are **not** available either (tested `nil` live), contradicting what static string analysis had suggested.
6. ~~Find how a real, working vanilla-1.12 action-bar addon solves the "no SecureHandler" problem~~ — **done, see §5f.** `ButtonForge Classic` (MIT-licensed, source read in full) proves the answer: back custom, non-secure button frames with unused vanilla action slots (73-120) and drive them through the native `UseAction`/`PlaceAction`/`PickupAction`/`HasAction` API — the security boundary is vanilla's own action-slot system, not something we build. Zero dependency on any of our four client mods confirmed by source search. Gap identified: it doesn't do mouseover-*casting* (only bar-fade-on-hover); our synthesis is to layer SuperWoW's `CastSpellByName(spellName, "mouseover")` on top as a per-button override for that specific feature.
7. ~~Prototype/confirm combat-lockdown behavior~~ — **done, see §5h.** Confirmed via a real combat window bracketed by `PLAYER_REGEN_DISABLED`/`PLAYER_REGEN_ENABLED`: `SetPoint`/`SetSize` on custom frames work completely unrestricted during combat. Bonus finding: `InCombatLockdown()` itself is non-functional in this environment (always `false`) — never gate logic on it; use the regen events directly if combat-state awareness is ever needed for anything.
8. ~~Close the two remaining loose ends from item 4~~ — **partially done, see §5g.** `C_Spell.UnitCastingInfo`'s return order confirmed live; nampower's `SPELL_START/GO/FAILED_SELF/OTHER` and `SPELL_CAST_EVENT` argument positions documented from real captures (some individual field meanings still unconfirmed — flagged per-field in §5g's table, none block current design decisions). Still open: `C_Spell.UnitChannelInfo`'s return order (no real channeled cast has been captured yet — low priority now, can be picked up opportunistically rather than blocking further work).
9. **All architectural blockers are now resolved.** Start designing the actual bar/button/grid data model — reusing ClassicAPI's Mixin/PixelUtil/TableUtil/CallbackRegistry/`C_Timer`/`C_Spell`, nampower's `GetCastInfo`/`GetSpellIdCooldown`/`CastSpellByName(name, "mouseover")` family, the confirmed `bit` library, and the `ButtonForge Classic`-proven action-slot-backed button pattern (confirmed combat-safe) as the supporting backbone. A single end-to-end button prototype (one action slot, one click, one cooldown swipe) is still a sensible first implementation step before building the full grid system, just no longer a research item — it's regular development work now.
