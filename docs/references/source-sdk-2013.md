# Source SDK 2013 Integration Reference

Technical reference for the `source-sdk-2013` submodule as a dependency of Zorcerer,
focused on what is needed to integrate Zorcerer with a running Team Fortress 2
dedicated server on Linux. Every claim is verified against the vendored checkout;
claims that require evidence from the installed TF2 binary are labeled explicitly.

Date of investigation: 2026-10-22.

All paths are relative to `extern/source/source-sdk-2013/` unless prefixed with `src/`.

## 1. Revision and provenance

| Item          | Value                                                           | Source                                                                                               |
|---------------|-----------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| Kind          | Git submodule of Zorcerer                                       | `.gitmodules:4-6` (url `https://github.com/ValveSoftware/source-sdk-2013.git`, **no branch pinned**) |
| Gitlink       | `be57e3d01ac7d7aa6a2cacbfef187c0b46616db0`                      | `git ls-files -s extern/source/source-sdk-2013` (mode `160000`)                                      |
| Checkout HEAD | Same commit, detached HEAD (`git symbolic-ref -q HEAD` fails)   | `git log -1` / `git rev-parse HEAD`                                                                  |
| Head commit   | *"Use dictionary when looking up itemdefs by name"*, 2026-10-09 | `git log -1`                                                                                         |
| Working tree  | Clean (`git status --porcelain` empty)                          | read-only git inspection                                                                             |
| Submodules    | **None** — no `.gitmodules` inside the SDK checkout             | `find . -maxdepth 2 -name .gitmodules`                                                               |

**No mismatch was found between the submodule gitlink and the checkout HEAD.** Because
`.gitmodules` pins no branch, upstream drift is normal behavior of `git submodule
update --remote`; any future refresh must be compared against the current commit
before analysis results here are trusted.

This is the newer SDK generation that ships **full Team Fortress 2 game code**
(`src/game/server/tf/` exists: `bot/`, `bot_npc/`, `entity_ammopack.cpp`,
`entity_currencypack.cpp`, …). It is not the classic 2013-era tree, which is visible
in interface versioning (see §3).

## 2. Top-level layout

```
game/                   # runtime output area: bin/linux64, bin/x64, mod_tf/, mod_hl2mp/
  mod_tf/               # runnable TF2 game dir: gameinfo.txt, materials/, resource/, steam.inf
src/
  public/               # cross-boundary headers — the critical surface
    tier0/              # tier0 HEADERS ONLY (platform.h, dbg.h, memalloc.h, ...)
    engine/             # IEngineTrace.h, IEngineSound.h, IStaticPropMgr.h, ivmodelinfo.h,
                        # iserverplugin.h, ivdebugoverlay.h, http.h, ... (NOT engine source)
    game/server/        # iplayerinfo.h, ientityinfo.h, igameinfo.h, pluginvariant.h
    vstdlib/            # IKeyValuesSystem.h, random.h, cvar.h, ...
  tier1/                # interface.cpp/.h, convar.cpp, KeyValues.cpp, strtools.cpp, bitbuf.cpp
  tier0/                # only tier0_exclude.vpc — tier0 .cpp is NOT shipped as source
  vstdlib/              # only vstdlib_exclude.vpc — vstdlib .cpp is NOT shipped as source
  engine/               # ONLY audio/ (engine/audio/public) — the engine itself is NOT in the SDK
  game/                 # client/, server/, shared/, msvc/ — server/ contains tf/ (full TF2 code)
  utils/serverplugin_sample/serverplugin_empty.cpp   # canonical 3rd-party server plugin
  vpc_scripts/          # VPC build config (VPC → ninja via buildallprojects)
  lib/public/linux64/   # PREBUILT libs: libtier0.so, libvstdlib.so, tier2.a, tier3.a,
                        # appframework.a, particles.a, choreoobjects.a, vpklib.a, ...
  lib/common/linux64/   # bzip2.a, jpeglib.a, libspng.a, lzma.a, replay_common.a
  thirdparty/           # protobuf-2.6.1, libspng, ...
game/bin/               # empty until build (linux64/, x64/ do not exist yet)
```

Key structural facts:

- **The engine source is entirely absent.** `src/engine/` contains only `audio/`
  (with `engine/audio/public`). Everything about engine internals comes from
  `src/public/` headers or from the installed TF2 binary.
- **tier0 / vstdlib exist as prebuilt binaries** (`src/lib/public/linux64/libtier0.so`,
  `libvstdlib.so`) with headers in `src/public/tier0/`, `src/public/vstdlib/`.
- The build targets and libs are 64-bit Linux (`/linux64` VPC flag, `linux64/` dirs).

## 3. Build and platform assumptions

`src/buildallprojects` (verified, read only):

- Runs the toolchain inside the Steam Runtime **sniper** SDK container
  (`registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest`) via podman — `src/sdk_container`.
- Invokes VPC with `/hl2mp /tf /linux64 /ninja /define:SOURCESDK +everything` and
  generates `src/compile_commands.json` for ninja — this file, when produced, is
  directly consumable by Zorcerer's C++ analyzer.
- `SOURCESDK` is a conditional define (`src/vpc_scripts/source_base.vpc:21,32`) that
  switches between Valve-internal and public-SDK source paths.
- Linux `.so` output: `src/vpc_scripts/source_dll_posix_base.vpc` —
  `$ConfigurationType "Dynamic Library (.dll)"`, output into `game/bin`, guards
  `[$LINUX64 || $LINUXARM64]`.

## 4. Architecture overview

Two boundaries matter, and they are asymmetric.

```
                     ┌──────────────────────────────────────┐
 TF2 dedicated server│   TF2 engine (.so) — SOURCE NOT IN   │
                     │   SDK; owns: IVEngineServer (023),   │
                     │   IFileSystem, ICvar,                │
                     │   GAMEEVENTSMANAGER002               │
                     └──────────┬──────────────△────────────┘
       dlsym("CreateInterface") │              │ IServerPluginCallbacks vtable
       + Load(factories)        │              │ (the plugin hands nothing back)
                                ▼              │
 ─────────────────────────────────────────────────────────────────
 ┌──────────────────────────────────────────────────────────────┐
 │ tf server .so (SDK source: src/game/server/*, incl. tf/)     │
 │ exposes: ServerGameDLL012, ServerGameEnts001,                │
 │          ServerGameClients003/004/005, PlayerInfoManager001, │
 │          BotManager001, ...                                  │
 └──────────────┬───────────────────────────────────────────────┘
                │ gameServerFactory
                ▼   Zorcerer belongs here as ISERVERPLUGINCALLBACKS003
 ┌──────────────────────────────────────────────────────────────┐
 │ 3rd-party server plugin (Zorcerer: zorcerer.so)              │
 └──────────────────────────────────────────────────────────────┘
```

- **Engine → game DLL.** The engine `dlsym`s `CreateInterface` from the server .so
  and calls `IServerGameDLL::DLLInit(appSystemFactory, physicsFactory,
  fileSystemFactory, pGlobals)` (`src/public/eiface.h:475-483`).
- **Game DLL → engine.** The game DLL pulls all engine interfaces *from the
  factories it was handed*. Proof in implementation code:
  `src/game/server/gameinterface.cpp:569-631` (`CServerGameDLL::DLLInit`) acquires
  `IVEngineServer` via `appSystemFactory(INTERFACEVERSION_VENGINESERVER, NULL)`
  (line 587), plus `IVoiceServer`, `INetworkStringTableContainer`,
  `IStaticPropMgrServer`, `IUniformRandomStream`, `IEngineSound`,
  `ISpatialPartition`, `IVModelInfo`, `IEngineTrace`, `IFileSystem`,
  `IGameEventManager2`, `IDataCache`, `IServerPluginHelpers`, and others.
- **Engine → plugin (Zorcerer's slot).** The engine-side plugin manager is NOT in
  the SDK source (engine is absent); behavior is described only in the header
  contract `src/public/engine/iserverplugin.h`. The engine dlopens plugin .so files
  from `addons/`, `dlsym`s `CreateInterface`, constructs the plugin's exposed
  interface, and calls `IServerPluginCallbacks::Load(interfaceFactory,
  gameServerFactory)` (`iserverplugin.h:59`). The plugin receives both the engine
  factory and the game-server factory.
- **Entity layer.** `edict_t` (`src/public/edict.h:429`, subclass of `CBaseEdict`)
  is the shared engine↔DLL entity representation. `CBaseEdict`'s layout is frozen
  by Valve: `// NOTE: YOU CAN'T CHANGE THE LAYOUT OR SIZE OF CBASEEDICT ...`
  (`edict.h:164`). Shared change-info structures: `CSharedEdictChangeInfo`
  (`edict.h:106-127`). Global state travels through `CGlobalVars`
  (`edict.h:41`, extends `CGlobalVarsBase` in `src/public/globalvars_base.h`).

## 5. Interface discovery

### 5.1 The registration machinery (verified end to end)

1. **Convention:** interfaces must be all-pure-virtual classes with no data
   members; versioning rule: appending to the end keeps binary compatibility, and
   both old and new names are exposed in that case
   (`src/public/tier1/interface.h:9-21`).
2. **Base:** all interfaces derive from `IBaseInterface` (`interface.h:55-59`).
3. **Export macros:** `EXPOSE_INTERFACE`, `EXPOSE_SINGLE_INTERFACE`,
   `EXPOSE_SINGLE_INTERFACE_GLOBALVAR` (`interface.h:98-136`) generate a
   singleton-returning static thunk plus a static `InterfaceReg`.
4. **Registry:** `InterfaceReg` head-inserts itself into static linked list
   `s_pInterfaceRegs` in its constructor (`src/tier1/interface.cpp:46-54`).
   Registration order is therefore **reverse** of registration COMPILE-TIME
   order (static initialization, linker-merged order).
5. **Linux loading:** `interface.h:39-49` includes `<dlfcn.h>` and defines
   `#define GetProcAddress dlsym` (line 43). `CREATEINTERFACE_PROCNAME =
   "CreateInterface"` (`interface.h:62`). `CreateInterface` is
   `DLL_EXPORT` = `extern "C" __attribute__((visibility("default")))`
   (`src/public/tier0/platform.h:649`).
6. **Lookup:** `CreateInterfaceInternal` does a linear `strcmp` scan of
   `s_pInterfaceRegs` and invokes the thunk, returning `IFACE_OK`/`IFACE_FAILED`
   (`interface.cpp:68-94`).
7. **Process-wide symbol coalescing pitfall (documented in source):** on
   GCC/Linux, the single `CreateInterface` symbol coalesces process-wide, so
   `Sys_GetFactoryThis()` must go through `CreateInterfaceInternal` to return the
   DSO-specific factory (`interface.cpp:61-66`).

### 5.2 Interface version strings present in this checkout

| Interface | Version string | Declared at |
|---|---|---|
| `IVEngineServer` (engine → game DLL) | `"VEngineServer023"` | `src/public/eiface.h:78` (`INTERFACEVERSION_VENGINESERVER`), class at `:98`, `IVEngineServer021/022` typedefs at `:459-460` |
| `IServerGameDLL` (game DLL → engine) | `"ServerGameDLL012"` | `eiface.h:467-468`; `COMPILE_TIME_ASSERT(INTERFACEVERSION_SERVERGAMEDLL_INT == 12)` at `gameinterface.cpp:567` |
| `IServerGameClients` | `"ServerGameClients005"` (+003, 004 kept exposed) | `eiface.h:690-692`; all three exposed `gameinterface.cpp:2676-2678` |
| `IServerGameEnts` | `"ServerGameEnts001"` | `eiface.h:660`; exposed `gameinterface.cpp:2416` |
| `IServerPluginCallbacks` (engine → plugin) | `"ISERVERPLUGINCALLBACKS003"` | `src/public/engine/iserverplugin.h:47-50` |
| `IGameEventManager2` | `"GAMEEVENTSMANAGER002"` | `src/public/igameevents.h:22` |
| `ICvar` | `"VEngineCvar004"` | `src/public/icvar.h:190` |
| `IPlayerInfoManager` / `IBotManager` | `"PlayerInfoManager001"` / `"BotManager001"` | exposed `src/game/server/playerinfomanager.cpp:132-133` |
| `IServerTools` | `VSERVERTOOLS_INTERFACE_VERSION` | `gameinterface.cpp`-adjacent: `entity_tools_server.cpp:86-88` |

All version strings above are **declared in this checkout's source**. Whether the
installed TF2 dedicated server carries the same strings is a binary question (§7).

### 5.3 Registration sites (source → implementation links)

- `gameinterface.cpp:564` — `g_ServerGameDLL` (a `CServerGameDLL`) exposed as
  `ServerGameDLL012`.
- `gameinterface.cpp:587` — the *implementation* requests `VEngineServer023` from
  the engine's factory. This is in-source proof that the string is the live
  interface tag under this SDK revision.
- `gameinterface.cpp:2416` — `CServerGameEnts` exposed as `ServerGameEnts001`.
- `gameinterface.cpp:2676-2678` — `CServerGameClients` exposed as
  `ServerGameClients003`, 004, and 005 simultaneously (append-compatibility
  demonstrated in practice).
- `src/game/server/playerinfomanager.cpp:74,132-133` —
  `PlayerInfoManager001` and `BotManager001` exposure.

### 5.4 `VEngineServer023` — explicit finding

`#define INTERFACEVERSION_VENGINESERVER "VEngineServer023"` **does occur** in this
checkout, at `src/public/eiface.h:78`; the companion integer is
INTERFACEVERSION_VENGINESERVER_INT = 23 (line 79) and previous-generation typedefs
`IVEngineServer021/022` exist (lines 459-460). It is consumed by name at
`gameinterface.cpp:587`. No other occurrence of the string exists in the tree
(repository grep, one match). Consistent with this era of the SDK, the interface
the game DLL receives from the engine was bumped to 023 (021/022 kept as typedefs).

### 5.5 How a plugin acquires interfaces (the pattern Zorcerer follows)

`src/utils/serverplugin_sample/serverplugin_empty.cpp` is the canonical template:

- `CEmptyServerPlugin: public IServerPluginCallbacks, public IGameEventListener`
  (line 69) — note the **multiple inheritance**.
- Exposed as `ISERVERPLUGINCALLBACKS003` via `EXPOSE_SINGLE_INTERFACE_GLOBALVAR(
  CEmptyServerPlugin, IServerPluginCallbacks,
  INTERFACEVERSION_ISERVERPLUGINCALLBACKS, g_EmtpyServerPlugin)` (line 110).
- Inside `Load(interfaceFactory, gameServerFactory)` (line 127 onward):
  - `ConnectTier1Libraries`, `ConnectTier2Libraries` (lines 129-130) — this is
    what binds `icvar` / `filesystem`-family globals (the `Load` body later
    relies on `g_pFullFileSystem` at line 162).
  - From `gameServerFactory` (lines 132-153), all treated as optional (warning
    on failure, not fatal): `IEntityInfoManager` (line 132),
    `IPlayerInfoManager` (line 138), `IBotManager` (line 144),
    `IGameInfoManager` (line 149).
  - From `interfaceFactory` (lines 155-159), **required** by the existence
    check at lines 162-165: `IVEngineServer` (line 155), the OLD
    `IGameEventManager` — `INTERFACEVERSION_GAMEEVENTSMANAGER` (v1), not v2 —
    (line 156), `IServerPluginHelpers` (line 157), `IEngineTrace` (line 158),
    `IUniformRandomStream` (line 159).
  - `CGlobalVars` (declared line 54) is filled from the game DLL, not from the
    engine: `gpGlobals = playerinfomanager->GetGlobalVars()` (lines 167-170).
    So `gpGlobals` is only available if `gameServerFactory` handed out
    `IPlayerInfoManager` — an important constraint for Zorcerer's adapter.
  - `MathLib_Init(2.2f, 2.2f, 0.0f, 2.0f)` then `ConVar_Register(0)`
    (lines 172-173) — the plugin's own ConVar/ConCommand registration point.
- `Unload()` (line 180): symmetrical teardown — `RemoveListener` (line 182),
  `ConVar_Unregister` (line 184), `DisconnectTier2Libraries` (line 185).

## 6. ABI and virtual-function findings

### 6.1 What the source confirms

- On PC, `abstract_class` expands to plain `class` (`src/public/tier0/platform.h:379`)
  — the `NO_VTABLE` divergence is Windows/X360-only (comment at `platform.h:369-377`),
  so Linux layout practice follows plain Itanium-ABI vtables.
- `DLLEXPORT` is **empty** on non-Win32 (`src/public/eiface.h:70-74`). On Linux,
  exported symbols rely on `DLL_EXPORT`
  = `extern "C" __attribute__((visibility("default")))` (`platform.h:649`) and
  `DLL_CLASS_EXPORT` / `DLL_LOCAL` (`platform.h:653,660`).
- No explicit calling convention is forced on Linux: the tentative
  `#define __stdcall __attribute__ ((__stdcall__))` is **commented out**
  (`platform.h:690`). Layout assumptions must come from the platform ABI
  (SysV x86-64 Itanium ABI), not from Valve macros.
- Linux-specific alignment and init-order macros that can affect layouts or
  static-init debugging: `DECL_ALIGN(x) __attribute__((aligned(x)))`
  (`platform.h:522`), `CONSTRUCT_EARLY __attribute__((init_priority(101)))`
  (`platform.h:603`), `SELECTANY __attribute__((weak))` (`platform.h:614`),
  FMTFUNCTION using `format(printf, ...)` (`platform.h:623`).
- Versioning-by-append is a documented invariant (`interface.h:17-21`;
  "only adding things to the end" comment at `gameinterface.cpp:562`). The
  IVEngineServer 021 → 022 → 023 evolution in `eiface.h:455-460` is consistent
  with this, indicating earlier vtable indices stayed stable for appends.
- Frozen layouts exist and are asserted in comments, e.g. `CBaseEdict`
  (`edict.h:164`), and shared structs (`CSharedEdictChangeInfo`,
  `CEdictChangeInfo`) live in `public/edict.h` — mirror evidence for the engine
  and the game DLL to agree on layout without link-time type checking.
- Multiple inheritance is used in real plugin code
  (`serverplugin_empty.cpp:69`: `IServerPluginCallbacks` + `IGameEventListener`)
  — any secondary-base pointer substitute is important to account for in vtable
  analyzers.

### 6.2 What depends on platform, compiler, or binary evidence

- Vtable layout in the live TF2 server .so is governed by the **Itanium C++ ABI**
  as emitted by the build toolchain (sniper / GCC/Clang). Whether the binary
  includes RTTI (typeinfo pointer at vtable[-1]) is **not answerable from
  headers**; it depends on `-fno-rtti` in the build. AGENTS.md describes
  Zorcerer's analyzer as RTTI-free by design — verify against the SDK build flags
  and against the target binary.
- `edict_t`, `CGlobalVars`, `CBaseEdict`, and `CSharedEdictChangeInfo` field
  offsets in the binary are only pinned by the frozen-layout comments; numeric
  offsets must be confirmed from the binary (DWARF debug info if the target
  was built with it, or runtime probing), not from reading headers alone.
- The mapping from "count of virtual methods in the header" to numeric vtable
  index in the running TF2 binary is **not** a fact from headers alone. Itanium
  ABI tables are (offset-to-top, typeinfo?, then method pointers) and
  implementation ordering can differ from source ordering after class
  transformations made by the compiler (inlining does not change order, but
  default-argument thunks and covariant-return thunks DO insert extra entries).
  Treat any claimed numeric index as a **hypothesis needing binary confirmation**.

### 6.3 Pitfalls for `zig-hooks` and the vtable analyzer

- **Reverse registration order**: `InterfaceReg` ctor head-inserts
  (`interface.cpp:53`), so a hook that iterates `s_pInterfaceRegs` sees the last
  registered interface first. Order is also derived from static initialization
  order across translation units, which is unspecified by the C++ standard —
  hooks must not assume reproducible list order between builds.
- **`CreateInterface` symbol coalescing**: on Linux, `Sys_GetFactoryThis()` must
  return `CreateInterfaceInternal` (`interface.cpp:61-66`) because there is a
  process-wide `CreateInterface` symbol after dynamic linking. A hook library
  hooking `CreateInterface` by symbol may capture a different DSO's single
  coalesced definition; per-DSO interception must target `CreateInterfaceInternal`
  or the `InterfaceReg` list.
- **Multiple-inheritance thunks**: with a secondary base (as in
  `serverplugin_empty.cpp:69`), method pointers in the *secondary* vtable may be
  dedicated thunks (adjustor slots), so a naive vtable reconstruction off the
  primary base pointer misses/breaks on secondary-base calls.
- **Static initialization across DSOs**: `CONSTRUCT_EARLY` (`platform.h:603`)
  forces `init_priority(101);` this is one of the few compiler-provided ordering
  mechanisms, and it only orders within a single DSO — cross-DSO order stays
  unspecified.
- **RTTI-free assumption**: Zorcerer's vtable analyzer is documented (AGENTS.md)
  as building without RTTI. Whether the TF2 binary ships RTTI is unverified
  (§9). If the binary has no typeinfo pointer in vtables, any analysis that
  assumes `vtable[-1]` is typeinfo is wrong for the target binary; if it does,
  all Itanium-ABI offsets shift by one slot. **Verify in the binary first.**

## 7. Known unknowns

These cannot be answered from this SDK checkout alone. Verify against the
installed TF2 dedicated server binary when and as authorized:

1. **Live interface versions.** Does the installed `server.so`/TF2 engine actually
   carry `VEngineServer023`, `ServerGameDLL012`, `ISERVERPLUGINCALLBACKS003`, and
   the `PlayerInfoManager001` version tag? Verify by strings/nm/objdump probing
   (read-only binary inspection).
2. **Numeric vtable indices** for `IVEngineServer`, `IServerPluginCallbacks`,
   `IGameEventManager2`, `ICvar` in the deployed binaries. Requires typeinfo /
   vtable symbol extraction from the engine .so files.
3. **RTTI presence** in the TF2 engine and server .so files
   (`-fno-rtti` or not). Decides the vtable offset convention the analyzer uses.
4. **CGlobalVars / edict offsets** in the deployed binary — required before
   Zorcerer can safely read them from plugin code.
5. **Engine plugin-loading rules** (addons/ path, plugin list, invocation
   ordering, pause/unpause semantics) live in the engine binary, not in the SDK.

## 8. Recommended file map

| File (relative) | Contents | Why it matters to Zorcerer | What to pull next |
|---|---|---|---|
| `src/public/eiface.h` | `IVEngineServer`, `IServerGameDLL`, `IServerGameClients`, `IServerGameEnts`, `IVoiceServer` | Engine↔server contract; `VEngineServer023` source-of-truth | Enumerate `IVEngineServer` method list for the adapter stub table; verify against binary |
| `src/public/engine/iserverplugin.h` | `IServerPluginCallbacks003`, `PLUGIN_RESULT`, `EQueryCvarValueStatus` | The exact interface Zorcerer's binary must expose | Derive the full callback vtable; build Zorcerer's `IServerPluginCallbacks` skeleton |
| `src/utils/serverplugin_sample/serverplugin_empty.cpp` | Reference consumer of `IServerPluginCallbacks`, wiring of both factories | Valve's own template for a third-party server plugin — the blueprint for `zorcerer.so` | Extract `Load()` acquisition order, gpGlobals handling, `ClientCommand` samples |
| `src/public/tier1/interface.h` | `IBaseInterface`, `InterfaceReg`, `EXPOSE_INTERFACE*`, `CreateInterfaceFn`, dlsym shim on Linux | Registration machinery Zorcerer's hook library will hook or inspect | How `_STATIC_LINKED`, `_SUBSYSTEM` change which name is emitted |
| `src/tier1/interface.cpp` | `InterfaceReg` ctor, `CreateInterface`, `CreateInterfaceInternal`, `Sys_GetFactoryThis`/module API | First hook point of the registration chain | Determine which variant hooks must target on Linux; confirm module API |
| `src/public/igameevents.h` | `IGameEventManager(001)/(002)` contract | Zorcerer event bridge is expected to come from here | Extract `AddListener`-level event contracts |
| `src/public/icvar.h` | `ICvar` (`VEngineCvar004`), `ConCommandBase` registration | ConCommand/ConVar hook + registration layer | Enumerate `ICvar` accessors for Zorcerer's plugin-facing API |
| `src/game/server/gameinterface.cpp` | Engine-interface acquisition cascade (`DLLInit`), all `EXPOSE_*` sites | Ground truth on init ordering; when each interface pointer becomes non-null | Confirm CGlobalvars flow and `CDLLInit` event contexts |
| `src/game/server/playerinfomanager.cpp` | `PlayerInfoManager001` / `BotManager001` constructors | Stable non-engine access point for player-level queries | Game-side `IPlayerInfo` probe methodology for the adapter |
| `src/public/edict.h` | `edict_t`, `CBaseEdict`, `CSharedEdictChangeInfo` | Frozen entity representation the adapter must understand | Extract binary-mirrored offsets into `codegen_generated` |
| `src/public/globalvars_base.h` | `CGlobalVarsBase` layout (realtime, framecount, curtime, ...) | Globals the adapter and hooks read | Cross-check binary offsets when the TF2 binary inspection is authorized |
| `src/vpc_scripts/source_dll_posix_base.vpc` | Linux `.so` VPC template | Same build platform Zorcerer uses (linux64) | Confirm the preprocessor definition set inherited by TF2 server sources |
| `src/lib/public/linux64/` | Prebuilt `libtier0.so`, `libvstdlib.so`, `tier2.a`, `tier3.a`, ... | tier0/vstdlib are available as binaries, not source | Symbol/nm analysis of `libtier0.so` for ABI confirmation needs |

## 9. Recommended follow-up investigations

Ranked; each task is small, independent, read-only on the repository side, and
safe to run. Binary-probing tasks require explicit user authorization for a
TF2 server install (out-of-repo).

| Priority | Task | Goal | Expected result |
|---|---|---|---|
| **P0** | Enumerate all `IVEngineServer` virtual methods from `src/public/eiface.h` (header-driven) | Build Zorcerer's adapter-side interface table skeleton | A source-indexed method list ready to be validated against the binary |
| **P0** | Same enumeration for `IServerPluginCallbacks003`, `IGameEventManager2`, `ICvar` | Mapped callback chains for hooks, events, commands | Method lists with per-index hypotheses clearly labeled as source-derived |
| **P1** | Probe the installed TF2 dedicated server `.so` files (strings/nm/readelf) for interface version tags | Confirm which source-declared versions exist in the deployed binary | Confirmed list of live `INTERFACEVERSION_*` tags and any mismatches flagged |
| **P1** | Extract vtable symbols (`_ZTV...`) and analyze them for the interfaces above | Decide RTTI presence and derive numeric indices | A confirmed vtable index map for Zorcerer's adapter |
| **P1** | Analyze `src/game/server/gameinterface.cpp:569-631` init cascade in depth | Identify exact order in which engine pointers become valid, and which are optional | A verified init ordering so Zorcerer's `Load` reads only live interfaces |
| **P2** | Run `src/buildallprojects` (with authorization; requires podman + network) | Produce `src/compile_commands.json` for the C++ analyzer + build the SDK libs | reproducible compile DB consumed by our analyzer |
| **P2** | Map `ConnectTier1/2/3Libraries` behavior for the plugin (`tier1/`, `tier2/`, `tier3/` sources) | Understand what the adapter must initialize before plugin code runs | A checklist of global pointers and hook ordering prerequisites |
| **P2** | Cross-check `CBaseEdict`/`CGlobalVars` source layouts against TF2 binary debug info when available | Validate Zorcerer's `codegen_generated` offsets against reality | Confirmed offset table or a delta list |
| **P3** | Inventory the engine-side plugin manager operations (pause/unpause/notify) from the TF2 engine binary | Recreate engine-side plugin lifecycle semantics in documentation | A verified list of lifecycle callbacks and their firing conditions |

## 10. Summary

- The submodule is a clean, pinned snapshot (no nested submodules, no pinned
  branch) — the newer SDK generation that ships **full TF2 game code**.
- `VEngineServer023` **is present in this checkout** (`src/public/eiface.h:78`,
  consumed at `gameinterface.cpp:587`), alongside `ServerGameDLL012`,
  `ServerGameClients005`, `IServerPluginCallbacks003`, `GAMEEVENTSMANAGER002`,
  and `VEngineCvar004`.
- All dynamic discovery flows through `InterfaceReg` + `CreateInterface`
  (`src/tier1/interface.cpp:46-94`), and the Linux-specific symbol coalescing
  issue at `interface.cpp:61-66` is exactly the kind of pitfall `zig-hooks` must
  account for.
- Every numeric vtable index, RTTI presence, `CGlobalVars` offset, and engine
  lifecycle rule is a **binary-side question** that must be resolved against the
  installed TF2 dedicated server before Zorcerer's hook library or vtable
  analyzer can be trusted against the running target.
