# TrustyBars — Custom-Bar Keybinding: Native DLL Development Environment

## Context

Live testing conclusively proved that this vanilla 1.12.1 client cannot bind a raw keypress to a non-native action (no `SetBindingClick`, and the `SetBinding(key, "CLICK <frame>:<button>")` command is recorded correctly both live and in `bindings-cache.wtf` but is never dispatched — confirmed via direct file inspection, not a guess). Combined with the earlier-confirmed absence of `SecureActionButtonTemplate` and the confirmed fact that `EnableKeyboard(true)` blocks ALL other input (movement, chat) while active, there is currently no way, from Lua alone, to bind a key to one of TrustyBars' custom-bar buttons (the 48 free slots on pages 7-10).

The real, durable fix is a custom client-injected DLL — the same category of mod as SuperWoW/nampower/ClassicAPI/UnitXP_SP3, which this addon already runs on top of — that can detect a specific keypress at a level below WoW's own Lua-frame keyboard focus, and call into the Lua state without stealing all other input. This is a genuinely separate, native-code project. The user wants a dedicated Claude Code project set up for it, with Visual Studio 2022 (already installed) as the primary toolchain, so they can develop and test the injection against their live client themselves.

This plan is meant to be picked up in its own session whenever the user is ready to start that native-development track — it is intentionally kept separate from the Lua addon work happening in TrustyBars itself.

---

## Prerequisites

- **Visual Studio 2022** (already installed) with the **"Desktop development with C++"** workload enabled, including the **MSVC v143 x86/x64 build tools** and the **Windows 10/11 SDK**. The output must target **x86 (32-bit)** — Wow.exe (1.12.1) is a 32-bit process; a 64-bit DLL cannot be injected into it. VS Code/Rider aren't needed for the C++ build itself (MSVC's toolchain is what actually compiles), but VS Code is genuinely useful as the day-to-day editor for Claude Code to drive, with the build invoked through MSBuild/`cl.exe` from the integrated/Developer Command Prompt.
- **A disassembler for finding hook points**: Ghidra (free, no license) or IDA Free are the standard choices for locating the right function/offset in this exact Wow.exe build (1.12.1.5875 is the common vanilla client build — confirm the user's exact build/version first, since offsets are build-specific).
- **The existing 4 mods' source, as reference**: SuperWoW, nampower, ClassicAPI, and UnitXP_SP3 already prove hooking/injecting into this exact client works, and at least SuperWoW and nampower are open-source community projects — their source (once located by the user, since guessing at repo URLs should be avoided) is the single best reference for the exact hooking technique, calling convention, and Lua-registration pattern that's already confirmed compatible with this client build. Locate and read through whichever of these have public source before writing new hook code — don't reinvent the injection/registration mechanism from scratch.
- **Knowledge of how the current 4 DLLs are actually loaded** into the client right now (a proxy DLL sitting next to Wow.exe with a hijacked system-DLL name like `dbghelp.dll`/`winmm.dll`, vs. a separate injector executable, vs. a custom launcher). This determines how the 5th DLL should be loaded too — check the WoW client's install folder for what's actually there (unusual/renamed DLLs sitting next to Wow.exe, a modified launcher, etc.) and use that same mechanism for consistency, rather than adding a second, different loading method.
- **A disposable test target**: since this involves reverse-engineering and hooking a live game client, test against a private/offline server or a throwaway character first — a hook that's wrong can crash the client, and if this is a shared/monitored server, an unrecognized injected DLL could also trip anti-cheat scanning depending on the server's policy. Confirm this is either the user's own server or one where custom client mods of this kind are already an accepted/known part of the environment (which seems to be the case already, given SuperWoW/nampower/etc. are already in use) before testing on a live shared realm.

---

## Step-by-step setup

1. **Confirm the exact client build** (`Wow.exe` version, e.g. via its file properties) and locate the current mods' install layout (folder listing of the WoW install directory) to see how SuperWoW/nampower/ClassicAPI/UnitXP_SP3 are currently being loaded.
2. **Create a new, separate Claude Code project folder** for this (distinct from the TrustyBars Lua repo — different language, different toolchain, different concerns). Initialize it as its own git repo.
3. **Set up the VS2022 project as a DLL**: New Project → "Dynamic-Link Library (DLL)" template, C++, Platform = Win32 (x86), Configuration = Debug and Release both x86. Confirm it builds and produces a `.dll` before writing any real logic.
4. **Add a `CLAUDE.md`** at the new project's root documenting: the target client build/version, the confirmed absence of `SetBindingClick`/working `CLICK` binding dispatch and of `SecureActionButtonTemplate` (so Claude doesn't re-suggest solving this from the Lua side), the goal (detect a specific keypress at a level below WoW's own Lua-frame keyboard focus, then call a registered Lua function so TrustyBars can react without blocking any other input), and a link/pointer to wherever the SuperWoW/nampower reference source ends up living locally once the user retrieves it.
5. **Pull in a minimal hooking library** (MinHook is the common lightweight choice for this class of project) via vcpkg or a git submodule, rather than hand-rolling inline-assembly trampolines from scratch.
6. **Reference the existing mods' source** for exactly how they register new Lua-callable C functions into the running Lua state (this part — "add a new Lua global function from native code" — is already solved by nampower/UnitXP_SP3 and directly reusable) and for whichever of them do any kind of persistent background hook (UnitXP_SP3's independent background timer is the closest existing precedent for "run native code on every tick without going through WoW's own frame/Lua update loop").
7. **New research needed beyond what the existing 4 mods already do**: none of them currently expose anything keyboard/input-related (confirmed via this project's research), so finding the right hook point for "detect a raw keypress independent of WoW's Lua keyboard focus" is genuinely new work — likely hooking the client's low-level Win32 message loop or DirectInput read call, not anything already solved by SuperWoW/nampower. This is the part Ghidra/IDA will be needed for.
8. **Test loop**: build the DLL, drop it into the client folder using the same loading mechanism identified in step 1, launch the client, confirm the existing 4 mods still work (to catch any accidental interference), then test the new hook in isolation (e.g., have it just print/log a detected keypress first, before wiring it to actually trigger a button click).

This part of the work happens in its own project/session — the eventual Lua-side integration point (what the native→Lua callback signature should look like so TrustyBars' `HoverBind.lua` can consume it cleanly) can be designed together whenever the native side is far enough along to test against, but the actual C++ hook development itself needs to happen in this dedicated project with the user's own testing against the live client.

---

## Verification

No in-repo verification — this is native-code work in a separate project. Success is measured by the DLL loading alongside the other 4 without crashing the client, and the new hook firing (initially just logging a detected keypress) without blocking movement/chat, before ever wiring it to a real button click.
