# Source Engine File System — Analysis Report

Analysis of the Source Engine's own file-system implementation, derived from
`docs/references/source-sdk-2013.md` (§4, §10) and extended / re-verified directly
against the committed SDK checkout (`extern/source/source-sdk-2013/` @
`be57e3d01ac7d7aa6a2cacbfef187c0b46616db0`).

Date of investigation: 2026-10-22.

Claim labels, matching the parent reference's convention:

- **[checkout]** — verified in the vendored SDK source.
- **[doc]** — taken from `docs/references/source-sdk-2013.md`.
- **[binary]** — unverified; requires probing the installed TF2 dedicated server binary.

Unless a path starts with `src/` or is otherwise explicit, paths are relative to
`extern/source/source-sdk-2013/`.

## 1. Architectural placement — the FS is engine-owned, not SDK-owned

Consistent with the parent reference's §4 finding that *everything engine-side is
absent from the SDK*, the file-system implementation lives entirely inside the
TF2 engine binary:

- **[doc]** The engine owns `IFileSystem`; the game DLL only holds a pointer to it.
- **[checkout]** The game DLL acquires it inside `CServerGameDLL::DLLInit`:
  `src/game/server/gameinterface.cpp:605` —
  `filesystem = (IFileSystem *)fileSystemFactory(FILESYSTEM_INTERFACE_VERSION, NULL)`,
  failed-init is fatal (`return false`).
  Note it uses the **distinct `fileSystemFactory` parameter** of `DLLInit`
  (`src/public/eiface.h:475-483`), not the general `appSystemFactory` — the engine
  treats the FS as a special-cased boundary.
- The engine's actual implementation classes (`CBaseFileSystem`, `SearchPaths`,
  `filesystem_stdio`/`filesystem_steam` DLLs) have **no .cpp in the tree** — the
  same gap as the rest of `src/engine/`. What the SDK ships instead: headers
  (`src/public/filesystem.h`, `filesystem_init.h/.cpp`, `filesystem_passthru.h`,
  `filesystem_helpers.h`), the prebuilt **`src/lib/public/linux64/vpklib.a`**, and
  a passthru wrapper header.

## 2. Interface layering (two versions, dual inheritance)

**[checkout]** (`src/public/filesystem.h`)

| Interface | Version string | Role |
|---|---|---|
| `IBaseFileSystem` | `"VBaseFileSystem011"` (line 499) | Minimal contract: `Read/Write/Open/Close/Seek/Tell/Size/Flush/Precache/FileExists/GetFileTime/ReadFile/WriteFile/UnzipFile`. Designed so *other subsystems* (e.g. `CPackedStore`, VMPI) can be implemented against "a named set of files" without needing the full FS. |
| `IFileSystem` | `"VFileSystem022"` (line 539) | Full engine FS. Declared as `: public IAppSystem, public IBaseFileSystem` (line 541) — **dual inheritance**. |

Zorcerer-relevant ABI facts:

- `FileHandle_t` is a plain `void *` (line 38) — fully opaque; nothing can be done
  with a handle except pass it back.
- `IFileSystem` extends `IAppSystem`, so the first several vtable slots are the
  AppSystem group (`Connect/Disconnect/GetDependencies/IsSingleton/Init/Shutdown`)
  before any FS method. Any vtable-index hypothesis must account for both base
  subobjects; like `IServerPluginCallbacks` + `IGameEventListener` in the sample
  plugin, this is a multiple-inheritance case where secondary-vtable adjustor
  thunks apply (**[doc]** §6.3).
- Append-compatibility rule (parent reference §5.1) applies; the interface has
  accumulated "post Lost Coast (7/05)" methods trailing at the end of the class
  (line 774 onward).

## 3. The search-path model — the heart of the design

**[checkout]** `filesystem.h:86,129-147,260-268,569-601`, `filesystem_init.cpp`,
plus the TF2 `gameinfo.txt`.

Resolution is **not** a plain OS filesystem: a logical name + optional **pathID**
is resolved against an ordered list of search paths, each tagged:

```c
PATH_IS_NORMAL, PATH_IS_PACKFILE, PATH_IS_MAPPACKFILE, PATH_IS_REMOTE   // PathTypeQuery_t
FILTER_NONE / FILTER_CULLPACK / FILTER_CULLNONPACK                      // pack vs non-pack filtering
PATH_ADD_TO_HEAD / PATH_ADD_TO_TAIL                                     // priority ordering
```

- `AddSearchPath(pPath, pathID, addType)` — the *first* `.pak`/`.bsp`-embedded
  PAK encountered during path addition is layered *above* the mod dir (comment at
  `filesystem.h:562-568`); a `.bsp` PAK becomes the highest-priority path
  ("looked at first even before the mod's file system path").
- `MarkPathIDByRequestOnly` (line 582) — opt-in laziness for expensive path IDs;
  mirrors the parent reference's observation that TF2 gameinfo uses
  `|appid_440|` VPK entries that shouldn't be probed eagerly.
- **[checkout]** TF2's `game/mod_tf/gameinfo.txt:52-56` shows the deployed shape:
  `game+mod |appid_440|tf/tf2_misc.vpk` etc. — multiple VPKs layered per
  search-path category (`game`, `game+mod`, `game+mod+vgui`).
- **Naming tokens** are interpreted in `filesystem_init.cpp`
  (`FileSystem_LoadSearchPaths`, line 643): `|gameinfo_path|` (line 661),
  `"VProject"` as the `GAMEDIR_TOKEN` (line 21), and base paths
  `EXECUTABLE_PATH` / `BASE_PATH` set at `:1254,1266`.
- Write behavior: `RemoveFile`/`RenameFile` operate "on the WritePath", and
  `SetWriteProtectionEnable` (line 933) exists because "the game client locks us
  down to writing in specific places... remote users can coerce us into
  writing" — the FS arbitrates writes, not just reads.

## 4. Bootstrapping: `filesystem_init` (this part *is* shipped as source)

Unlike the engine FS itself, **[checkout]** `src/public/filesystem_init.h/.cpp`
contains the full startup choreography, and it defines what a filesystem even
*is* at load time:

1. `FileSystem_GetFileSystemDLLName` — locates the FS as a **loadable DLL**:
   `filesystem_stdio_<ext>` (line 1285); the Steam variant is legacy — `:1370`
   states "Should not be using filesystem_steam anymore!". So on this SDK
   generation the FS is already a **stdio-backed, engine-independent module**
   that the engine loads and connects.
2. `FileSystem_SetupSteamEnvironment` → gameinfo.txt discovery
   (`gameinfo.txt` / alternate, lines 42-51), `-vproject`/`-game` resolution,
   `FS_MISSING_GAMEINFO_FILE`… error taxonomy (lines 31-39).
3. `FileSystem_LoadSearchPaths` — the search-path population described in §3.
   This is the code path that turns `gameinfo.txt` into the runtime layered
   namespace; it is usable headroom for Zorcerer because it's plain source, not
   binary.

## 5. The packfile layer: VPK (`vpklib.a`, header-only here)

**[checkout]** `src/public/vpklib/packedstore.h`; implementation ships only as
prebuilt `vpklib.a` (parent reference §2 — prebuilt lib list). Notable verified
facts:

- Two-file design: a **directory file** (`*_dir.vpk`) plus multi-GB **chunk
  files**; `k_nVPKDefaultChunkSize = 200 MB` (line 29). Files are split
  `(m_idxChunk, m_iOffsetInChunk)` with optional **preload bytes** embedded in
  the directory (lines 150-177).
- Integrity is built into the format, driven by pure-server needs:
  per-1MB-fraction `ChunkHashFraction_t` MD5 list (lines 35-57),
  directory/chunk/master MD5s (lines 333-339), and RSA **signing** of the
  directory file (`VPK_ENABLE_SIGNING`, `ESignatureCheckResult`, lines 369-381).
- Runtime read path: `CPackedStoreReadCache` — 4 × 1 MB LRU buffers
  (lines 241-243), whose stated *primary purpose* is letting `FileTracker`
  compute chunk MD5s asynchronously "for free" while reads are served from cache
  (line 224 comment).
- It always caps **512 simultaneously open archive files**
  (`MAX_ARCHIVE_FILES_TO_KEEP_OPEN_AT_ONCE`, line 116) with per-handle mutexes
  (line 132) — VPK handles are pooled, so file-handle lifetime is not
  caller-owned.
- Cross-chunking note: VPK reads go *through* `IBaseFileSystem`, i.e. packs are
  implemented on top of the FS abstraction rather than beside it;
  `IFileSystem::AddPackFile` (line 601) is the "custom pack files > 4 Gb" entry
  hook.
- Sibling layer: **BSP-embedded PAKs** via `IBSPPack` (`"IBSPPACK004"`,
  `ibsppack.h`) — `GetPakFileLump/SetPakFileLump`, plus `UnzipFile` on the base
  interface.

## 6. Asynchronous I/O layer

**[checkout]** `filesystem.h:296-383,695-731`

- A first-class async subsystem: `FSAsyncControl_t` ref-counted handles,
  `AsyncReadMultiple` with priorities (`AsyncSetPriority`), suspend/resume of the
  whole queue, `AsyncFinishAllWrites`, and an interesting ownership matrix:
  `FSASYNC_FLAGS_ALLOCNOFREE/FREEDATAPTR`, custom `FSAllocFunc_t` allocators,
  `FSASYNC_FLAGS_SYNC` to collapse the async load path into sync semantics.
- **`IAsyncFileFetch`** (lines 459-482): a pluggable fetcher hook ("load assets
  from the CDN via HTTP") where `Start()` returns `FSASYNC_ERR_NOT_MINE` to
  decline — this is *the* engine-vintage precedent for Zorcerer-style
  interception of I/O at an interface seam rather than by patching the FS.
- `FileAsyncRequest_t` even retains a compatibility comment: `pszPathID` "here to
  remain binary compatible with release HL2 filesystem interface" (line 380) —
  concrete evidence of the freeze-vtable-by-append discipline the parent
  reference describes abstractly.

## 7. Pure-server integrity machinery (security surface)

**[checkout]** `filesystem.h:48-80,386-452,851-921`

The FS is the enforcement point of `sv_pure`: `IPureServerWhitelist` classifies
files (`ePureServerFileClass_Any / AnyTrusted / CheckHash`);
`EnableWhitelistFileTracking`, `CacheFileCRCs`, `CheckCachedFileCRC`,
`GetUnverifiedFileHashes` (client ships unverified hashes in batches to the
server), `CheckVPKFileHash` (MD5 an arbitrary 1MB VPK fraction by
`(PackFileID, nPackFileNumber, nFileFraction)`), `MarkAllCRCsUnverified` on
connect, and explicit warnings that debug spew is a hack surface ("This spew can
be used by hackers... to bypass sv_pure", lines 51-55).

## 8. Memory-backed files and caching

**[checkout]**

- `CreateFileCache`/`AddFilesToFileCache`/`DestroyFileCache` — whole-file caches
  satisfying sync+async reads; the in-code comment (lines 900-905) admits keying
  is effectively `pathID == "GAME"` only.
- `RegisterMemoryFile`/`UnregisterMemoryFile` + `CMemoryFileBacking`
  (lines 941-960): ref-counted memory backings registered into the FS so reads
  can be served from RAM; a documented duplicate-registration race is handled by
  returning the existing ref-bumped entry.
- `GetOptimalIOConstraints` / `AllocOptimalReadBuffer` — alignment-aware
  "optimal IO" API (lines 827-830), the FS's way of exposing device/sector
  alignment without leaking the device.

## 9. How the globals get bound (the plugin-relevant seam)

**[checkout]**

- `extern IFileSystem *g_pFullFileSystem;` lives at `filesystem.h:1020` and
  `src/public/tier2/tier2.h:40`; the tier2 implementation is prebuilt
  (`tier2.a` — no `src/tier2/*.cpp` in the tree). `ConnectTier2Libraries(
  pFactoryList, nFactoryCount)` is the binder; the sample plugin calls it in
  `Load()` *before* first use of `g_pFullFileSystem` at
  `src/utils/serverplugin_sample/serverplugin_empty.cpp:162` (parent reference
  §5.5).
- `serverplugin_empty.cpp` proves the pattern works from a third-party plugin:
  an `ISERVERPLUGINCALLBACKS003` plugin routinely opens/reads files through the
  same process-wide `g_pFullFileSystem` the game DLL uses.
- **`src/public/filesystem_passthru.h` (268 lines)**: a complete forwarding
  `IFileSystem` wrapper calling into `m_pFileSystemPassThru`. This is Valve
  shipping a template for wrapped/proxy filesystems — directly reusable as the
  pattern for any Zorcerer-facing FS indirection (and for `zig-hooks` as
  evidence of how a base-interface swap is done without breaking
  append-compat: the passthru implements the interface surface itself).

## 10. What this means for Zorcerer (synthesis)

1. **The FS implementation is unreachable as source; the contract is reachable.**
   Everything actionable for Zorcerer is in 5 headers + 1 prebuilt lib:
   `filesystem.h` (the ABI), `filesystem_init.*` (search-path semantics, plain
   source), `filesystem_passthru.h` (wrap pattern), `packedstore.h` (VPK
   layout), `ibsppack.h` (BSP PAKs).
2. **Hook surfaces ranked for `zig-hooks`:**
   - Runtime interface lookup of `"VFileSystem022"` at
     `src/game/server/gameinterface.cpp:605` — but it uses the
     *fileSystemFactory* parameter, so interception points differ from other
     engine interfaces; the parent reference's `CreateInterfaceInternal`
     coalescing pitfall (§6.3) applies to whoever produces the FS pointer in
     `filesystem_stdio.so`.
   - `AddSearchPath`/`MarkPathIDByRequestOnly` virtuals would be the minimally
     invasive observation points for tracking plugin-introduced search paths.
   - vtable indices for `IFileSystem`/`IBaseFileSystem` are **[binary]**
     hypotheses only — dual inheritance + AppSystem base means header-derived
     indices need the P0/P1 binary verification the parent reference already
     lists (§9).
3. **Write-path semantics matter for a plugin manager.**
   `SetWriteProtectionEnable` shows the FS mediates all writes on servers; any
   Zorcerer feature that installs plugin files through the FS rather than the
   shell should go via pathIDs and respect the WritePath, not absolute paths.
4. **VPK complexity is prebuilt and reusable.** `vpklib.a` + `packedstore.h`
   means Zorcerer could read/mod VPK contents by linking the SDK's own lib
   rather than reimplementing the format; signature checks (`CheckSignature`,
   `ESignatureCheckResult`) suggest any *writing* of VPKs would also need the
   signing path for TF2's later VPKs — signing key handling would require
   user authorization.
5. **Unknowns (all [binary], consistent with parent reference §7):** live
   version string of the FS interface in the running TF2 engine (may exceed
   `022` with appended slots); number of AppSystem slots before
   `IBaseFileSystem` methods; whether `g_pFullFileSystem` in the deployed
   `server.so` resolves to the same engine instance; engine-side plugin-loading
   rules (parent reference §7.5) which govern *when* a plugin sees a
   fully-search-path-populated FS.

## 11. Relation to the parent reference

The parent reference's §4 correctly names the engine as the `IFileSystem` owner
but gives it no dedicated section; this report fills that gap. Two checkout
facts worth back-porting to `docs/references/source-sdk-2013.md`:

1. The FS is a loadable `filesystem_stdio` module on this SDK generation (not
   hard-internal to the engine) — `filesystem_init.cpp:1285,1370`.
2. `filesystem_init.cpp` is in-tree, engine-independent source, making
   search-path semantics *source-verifiable* rather than binary-only — useful
   for the parent reference's §8/§9 follow-up tables.
