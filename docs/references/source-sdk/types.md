# Source SDK Primitive Types — Inventory, Semantics, and `zostd` Shapes

Source-level inventory of the primitive types that cross Zorcerer's plugin
boundary, with the semantics, limits, sentinels, and lifetimes that matter when
they are mirrored into Zig. The report is grounded in the vendored
`source-sdk-2013` checkout and the existing references in `docs/references/`.

Date of investigation: 2026-10-28.

Unless a path starts with `src/` or is otherwise explicit, paths are relative to
`extern/source/source-sdk-2013/`.

Claim labels, following the convention in `filesystem.md`:

- **[checkout]** — verified directly in the vendored SDK source.
- **[doc]** — taken from `docs/references/source-sdk-2013.md`.
- **[binary]** — unverified; requires probing the installed TF2 dedicated
  server binary (out-of-repo, read-only inspection).

> Status: source-level report only. No build or test was run for this report.

## 1. Premise correction: `edict_t` is not an integer

A common shorthand is "an edict is an int". That is wrong for this SDK, and the
mistake propagates into every Zig type that follows from it.

**[checkout]** `edict_t` is a C++ class:

```cpp
// src/public/edict.h:429
struct edict_t : public CBaseEdict
{
public:
    ICollideable *GetCollideable();
    float freetime;
};
```

`edict_t*` is therefore an object pointer, not a 32-bit entity number. The
integer identity is a separate type, `CBaseHandle` (`src/public/basehandle.h:30`),
which stores an entry index plus a serial number in a `uint32`.

Two identities must remain distinct:

| Concept | C++ representation | ABI shape | Meaning |
|---|---|---|---|
| Entity slot view | `edict_t*` | pointer | Borrowed pointer to the engine's current slot occupant. Valid only while the engine keeps that slot alive. |
| Persistent identity | `CBaseHandle`, `CHandle<T>`, `EHANDLE` | 32-bit value | Entry index + serial. Survives slot reuse, but can become stale; a stale handle resolves to null. |

Consequences for the Zig side:

- Do not define `Edict = u32`, `Edict = c_int`, or an integer `Entity` that is
  passed where the C++ signature says `edict_t*`.
- Do not round-trip a raw pointer through an integer and expect it to remain a
  valid entity identity. The pointer names a slot, not an incarnation.
- Do not use an `edict_t*` as a long-lived cache key. Use `EntityHandle` and
  resolve it at use time.
- The pointer and the handle are not interchangeable: the pointer gives you the
  current object now; the handle gives you the ability to ask for the current
  object later.

**[checkout]** The slot layout is not free-form. The source marks `CBaseEdict`
as frozen: `// NOTE: YOU CAN'T CHANGE THE LAYOUT OR SIZE OF CBASEEDICT ...`
(`src/public/edict.h:164`), repeated at lines 202 and 239. The visible fields are
`m_fStateFlags`, `m_NetworkSerialNumber`, `m_EdictIndex`, `m_pNetworkable`, and
`m_pUnk`; `edict_t` adds `freetime` (`src/public/edict.h:199-246,429-436`).

**[binary]** The numeric offsets and the exact size of `CBaseEdict`/`edict_t` in
the deployed TF2 server are not established by reading the header. They must be
confirmed from the binary (DWARF if available, otherwise runtime probing or
disassembly). A source-derived x86-64 layout is useful as a hypothesis, never as
a constant to hardcode.

**[checkout]** `m_EdictIndex` is a cached index. The source explains that it
exists so code does not have to compute the index from the pointer by division
(`src/public/edict.h:212-220`). That comment is not permission to read the field
at a guessed offset; it is evidence that the engine itself treats the index as a
separate concern from the pointer.

## 2. Decoration rules for `zostd`

These rules follow from the SDK shapes, not from a preference for newtypes.

1. **Mirror ABI with `extern struct`, not with Zig `enum`.** C enums are
   `int`-sized values in the SDK's public signatures, and several of the TF2
   enums are explicitly append-only. A Zig `enum` creates a closed set and makes
   unknown values a safety error; that is the wrong contract for a value received
   from a newer server.
2. **Give every integer handle a distinct newtype.** `EntityHandle`,
   `EdictIndex`, and `EntityIndex` must not be interchangeable even when all
   three ultimately contain small integers. A single-field `extern struct`
   preserves the by-value ABI and removes accidental mixing.
3. **Use `bits: u32` for `CBaseHandle`.** The C++ object contains one `uint32`
   (`src/public/basehandle.h:80`), and the whole word—including the serial—must
   be preserved. Do not model it as an index alone.
4. **Use `value: u16` for slot indices.** `MAX_EDICTS` is 2048 and
   `NUM_ENT_ENTRIES` is 8192, both of which fit in 16 bits. The newtype's range
   documents which namespace the value belongs to.
5. **Keep raw pointers opaque.** `edict_t`, `model_t`, and `CSteamID` are not
   data structures Zorcerer may lay out itself. Declare `opaque {}` pointees or
   keep the pointer behind a host resolver.
6. **Represent append-only TF2 values as newtypes with constants.** A
   `TfWeaponId` is an integer whose known range grows. Validation against a
   revision-specific count is a policy decision, not a type invariant.
7. **Preserve unknown bits in bitmasks.** Damage flags, entity flags, and solid
   flags are bitfields whose unused bits are not guaranteed to stay unused.
   Copy the whole word and interpret only the bits you understand.
8. **Do not use Zig `packed struct` to mirror C bitfields.** C bitfield layout
   is compiler- and ABI-dependent. The SDK uses named integer bitmasks, not
   struct bitfields, at the public boundary.
9. **Use optional pointers for nullable C pointers.** `?*Edict` is the Zig
   spelling of a possibly-null `edict_t*`. Do not encode null as `0` in a
   newtype unless the C API itself does so.
10. **Document the sentinel separately from liveness.** `CBaseHandle::IsValid()`
    only means "not the invalid sentinel" (`src/public/basehandle.h:132-135`); a
    handle can be non-sentinel and still resolve to a freed entity. Zig should
    expose both a cheap `is_valid` and a resolver that can return null.

### Suggested naming

| SDK type | `zostd` name | Storage |
|---|---|---|
| `CBaseHandle` | `EntityHandle` | `bits: u32` |
| networkable edict index | `EdictIndex` | `value: u16` |
| full entity-list slot index | `EntityIndex` | `value: u16` |
| `edict_t*` | `*Edict` / `?*Edict` | opaque pointer |
| `string_t` | `StringToken` | `bits: usize` (mode-dependent) |
| model index | `ModelIndex` | `value: i32` |
| `FileHandle_t` | `FileHandle` | `raw: ?*anyopaque` |
| `TFClassType` / `ETFClass` | `TfClass` | `value: i32` |
| team value | `TfTeam` | `value: i32` |
| `ETFWeaponType` | `TfWeaponId` | `value: u32` |
| `ETFCond` | `TfCondition` | `value: i32` |
| `ObjectType_t` | `TfObjectType` | `value: u32` |
| `DMG_*` mask | `DamageMask` | `bits: u32` |
| `QueryCvarCookie_t` | `QueryCvarCookie` | `value: i32` |

The names are deliberately not the C++ names. `EntityHandle` describes the
contract, while `CBaseHandle` describes an implementation detail that Zorcerer
should not expose to plugins.

## 3. Tier 0 — entity identity

### 3.1 `edict_t*` and `CBaseEdict`

**[checkout]** `edict_t` derives from `CBaseEdict` and adds a `float freetime`
(`src/public/edict.h:429-436`). The base contains the state flags, the network
serial, the cached index, and two pointers:

| Field | Type | Purpose |
|---|---|---|
| `m_fStateFlags` | `int` | `FL_EDICT_*` state bits, including free/full/changed. |
| `m_NetworkSerialNumber` | `short` | Serial used by `CBaseHandle`. |
| `m_EdictIndex` | `short` | Cached slot index (little-endian ordering on PC). |
| `m_pNetworkable` | `IServerNetworkable*` | Networkable half of the entity. |
| `m_pUnk` | `IServerUnknown*` | Full entity half, when `FL_EDICT_FULL` is set. |

**[checkout]** The entity list makes a deliberate split: "The first MAX_EDICTS
entities are networkable. The rest are client-only or server-only."
(`src/game/shared/entitylist_base.h:107-108`). The array has
`NUM_ENT_ENTRIES` slots, but `AddNetworkableEntity` asserts the index is below
`MAX_EDICTS` (`src/game/shared/entitylist_base.cpp:173-176`).

Lifetime rules for the pointer:

- The engine owns the `edict_t` slot. The plugin must never free it or construct
  one.
- Treat the pointer as borrowed for the duration of the callback or engine call
  that supplied it. Storing it beyond that requires a documented engine
  lifetime guarantee that the SDK does not provide.
- A slot can be freed and reused. The pointer can therefore name a different
  entity incarnation later; the `EntityHandle` serial is what distinguishes the
  incarnations.
- `OnEdictFreed(const edict_t*)` is a notification, not a transfer of ownership.
  Use it to invalidate caches. Do not dereference the pointer after the engine
  has freed the slot.
- `OnEdictAllocated(edict_t*)` is the matching allocation notification. Cache
  the handle derived from the edict, not the raw pointer.
- `ServerActivate(edict_t* pEdictList, int edictCount, int clientMax)` passes a
  list pointer plus a count (`src/public/engine/iserverplugin.h:77`). The list is
  engine-owned and level-scoped; do not retain it across a level change.

**[binary]** Whether a plugin always receives a non-null pointer, whether the
edict array is contiguous in the deployed binary, and the exact offset of
`freetime` are binary questions. The source does not promise a public layout.

### 3.2 `CBaseHandle`

**[checkout]** `CBaseHandle` is a single `uint32 m_Index`
(`src/public/basehandle.h:30-81`). The bit split is defined in `const.h`:

| Constant | Value | Meaning |
|---|---:|---|
| `MAX_EDICT_BITS` | 11 | Bits needed for an edict index. |
| `MAX_EDICTS` | `1 << 11` = 2048 | Networkable edict slots. |
| `NUM_ENT_ENTRY_BITS` | 13 | `MAX_EDICT_BITS + 2`. |
| `NUM_ENT_ENTRIES` | `1 << 13` = 8192 | Full entity-list slots. |
| `NUM_SERIAL_NUM_BITS` | 16 | Serial bits in a 32-bit handle. |
| `NUM_SERIAL_NUM_SHIFT_BITS` | 16 | Serial shift. |
| `ENT_ENTRY_MASK` | `0xFFFF` | Low 16 bits are the entry index. |
| `INVALID_EHANDLE_INDEX` | `0xFFFFFFFF` | Invalid handle. |
| `NUM_NETWORKED_EHANDLE_SERIAL_NUMBER_BITS` | 10 | Serial bits on the wire. |
| `NUM_NETWORKED_EHANDLE_BITS` | 21 | 11 index bits + 10 serial bits. |
| `INVALID_NETWORKED_EHANDLE_VALUE` | `(1 << 21) - 1` | Invalid networked handle. |

**[checkout]** `Init(iEntry, iSerialNumber)` asserts that the entry fits in
`ENT_ENTRY_MASK` and the serial is below `1 << 16`, then packs
`iEntry | (iSerialNumber << 16)` (`src/public/basehandle.h:119-125`).

**[checkout]** `GetEntryIndex()` has a documented legacy hack: for the invalid
sentinel it returns `NUM_ENT_ENTRIES - 1` (8191) instead of `0xFFFF`, because old
code relied on the invalid handle looking up the always-empty last slot
(`src/public/basehandle.h:137-154`). Do not use `GetEntryIndex()` on an invalid
handle as an error signal, and do not assume its result is the raw low 16 bits in
that case.

**[checkout]** The game-side entity list reserves the high serial bit for static
props:

```cpp
// src/game/shared/entitylist_base.cpp:14-16
static const uint32 SERIAL_MASK =
    ( ( 1 << ( NUM_SERIAL_NUM_BITS - 1 ) ) - 1 );
```

That is a **15-bit server serial mask**. It is a property of the game-side
entity list, not of every `CBaseHandle` producer. Networked handles use 10 serial
bits (`const.h:87-89`). Therefore:

- Preserve all 32 bits in `EntityHandle`.
- Do not validate or truncate the serial to 15 bits at the type boundary.
- If Zorcerer needs to compare a handle to an engine-produced handle, compare the
  full word.
- The invalid sentinel is `0xFFFFFFFF`, not a zeroed handle.

**[checkout]** `IsValid()` is only `m_Index != INVALID_EHANDLE_INDEX`
(`src/public/basehandle.h:132-135`). It does not prove the entity still exists.
The actual lookup is in game code (`src/game/shared/ehandle.h:32-36`) and returns
null when the slot's serial no longer matches. A stale handle is "valid" in the
cheap sense but dead in the resolver sense.

**[checkout]** `ToInt()` casts the `uint32` to `int`
(`src/public/basehandle.h:161-164`). On a 32-bit `int` platform, a handle with
the high bit set produces a negative `int`. Zig should use `u32` and expose a
`toInt`-style bitcast only at a boundary that actually requires `c_int`.

**[checkout]** `CHandle<T>` adds type safety but no storage; it derives from
`CBaseHandle` and adds methods only (`src/game/shared/ehandle.h:49-106`).
`EHANDLE` is `CHandle<CBaseEntity>` (`src/public/isaverestore.h:27`). All three
are the same 4-byte handle at the ABI level.

### 3.3 `EdictIndex` versus `EntityIndex`

These are related but not the same namespace:

- `EdictIndex` — a networkable edict slot, `0..MAX_EDICTS-1` (`0..2047`).
- `EntityIndex` — a full entity-list slot, `0..NUM_ENT_ENTRIES-1`
  (`0..8191`). The first `MAX_EDICTS` are networkable; the rest are
  client-only/server-only.

**[checkout]** The `CBaseEntityList` constructor initializes the
non-networkable free list starting at `MAX_EDICTS + 1`
(`src/game/shared/entitylist_base.cpp:150-156`). Consequently slot 2048 is not
handed out by that path; the practical non-networkable range begins at 2049.
Do not invent a use for 2048 merely because it is numerically inside
`NUM_ENT_ENTRIES`.

**[checkout]** `GetNetworkableHandle(iEntity)` asserts `iEntity < MAX_EDICTS`
before constructing a handle (`src/game/shared/entitylist_base.h:126-133`). This
is the clearest source statement that an `EdictIndex` is not an arbitrary
`EntityIndex`.

Rule for Zig: `EntityHandle.entity_index()` returns an `EntityIndex` with the
full 16-bit low field, but converting to an `EdictIndex` must check `< 2048`.
The invalid sentinel and the `GetEntryIndex()` hack mean the conversion can
fail; make it return `?EdictIndex`.

### 3.4 `player_info_t`

**[checkout]** `player_info_t` is a fixed-layout engine struct
(`src/public/cdll_int.h:71-96`):

| Field | Shape | Note |
|---|---|---|
| `name` | `char[32]` | `MAX_PLAYER_NAME_LENGTH`; 31 chars + NUL. |
| `userID` | `int` | Local server user ID, not a stable global identity. |
| `guid` | `char[33]` | `SIGNED_GUID_LEN + 1`; text network ID. |
| `friendsID` | `uint32` | Friends identification number. |
| `friendsName` | `char[32]` | Same bound as `name`. |
| `fakeplayer` | `bool` | Bot flag. |
| `ishltv` | `bool` | HLTV proxy flag. |
| `customFiles` | `CRC32_t[4]` | `MAX_CUSTOM_FILES`. |
| `filesDownloaded` | `unsigned char` | Download counter. |

Copy the struct by value if you need it; do not retain pointers into it. The
`guid` field is a C string with its own lifetime inside the engine, and
`userID` is not the same thing as an `EdictIndex`.

## 4. Tier 1 — engine-owned tokens

### 4.1 `string_t`

**[checkout]** `string_t` is compile-time-selectable (`src/public/string_t.h`):

| Mode | Selection | Representation | Size on x86-64 |
|---|---|---|---:|
| Weak | `WEAK_STRING_T` | `int` offset/pointer | 4 |
| Strong | neither define | `struct { const char* pszValue; }` | 8 |
| None | `NO_STRING_T` | `const char*` | 8 |

**[checkout]** In this checkout, the server-side VPC files do not define
`WEAK_STRING_T` or `NO_STRING_T`, so the header selects the strong,
pointer-sized struct. The client VPC does define `NO_STRING_T`
(`src/game/client/client_base.vpc:57`). The two sides of the SDK are therefore
not forced into one mode by these files.

**[binary]** The mode used by the deployed TF2 server and by the game DLL that
hands `CGlobalVars` to a plugin is not established. This matters because
`CGlobalVars` embeds `string_t` fields (`mapname`, `startspot`) and every later
offset shifts if the size differs. Treat the live mode as a P0 binary question.

Semantics of the token, independent of mode:

- `NULL_STRING`/`MAKE_STRING("")` represent the empty string as a null token.
  `STRING(token)` returns `""` for a null token
  (`src/public/string_t.h:78-91` for strong mode; `:27-40` for weak).
- In strong mode, equality compares the `pszValue` pointer
  (`src/public/string_t.h:55-58`). Two tokens with identical text can compare
  unequal if they point at different copies. Do not substitute text comparison
  when the SDK contract is token identity.
- `ToCStr()` is explicitly documented as returning a transient pointer that
  should not be stored (`src/public/string_t.h:80-85`). Copy the bytes if they
  must outlive the call.
- `string_t` has no public constructor in strong mode because it is used in
  unions; `castable_string_t` is the constructible derived form
  (`src/public/string_t.h:68-72`). A Zig mirror should be a plain value struct,
  not an owning string.

For `zostd`, `StringToken` should be opaque: do not expose the pointer as a Zig
slice without a host decoder. If a plugin needs text, the host should copy it
into plugin-owned memory with an explicit lifetime.

### 4.2 Model indices and `model_t*`

**[checkout]** The model index encoding is documented in
`src/public/engine/ivmodelinfo.h:89-99`:

| Value | Meaning |
|---|---|
| `index >= 0` | Pre-cached model string-table index. |
| `index == -1` | Invalid model. |
| `index < -1` | Dynamic model; dynamic index is `-2 - index`. |
| dynamic index odd | Client-only model; lookup index is `dynamic >> 1`. |
| dynamic index even | Networked model; dynamic string-table index is `dynamic >> 1`. |

The helpers `IsDynamicModelIndex` and `IsClientOnlyModelIndex` are inline in the
same header. Note that `IsClientOnlyModelIndex` tests the sign bit and the low
bit of the original negative value; in Zig, compute the dynamic index first and
test its parity rather than applying `& 1` to a signed model index blindly.

`model_t*` is an opaque engine object. `GetModel(index)` returns a borrowed
pointer; it is not reference-counted by the caller and must not be freed.
`MDLHandle_t` is a separate 16-bit cache handle (`typedef unsigned short`,
`src/public/datacache/imdlcache.h:42`), not a model index. `MDLHANDLE_INVALID`
is `(MDLHandle_t)~0` (`:54-57`).

### 4.3 Filesystem handles

**[checkout]** The filesystem boundary uses several distinct opaque types
(`src/public/filesystem.h:38-42`):

| Type | Underlying type | Semantics |
|---|---|---|
| `FileHandle_t` | `void*` | Open-file handle; pass back to the same FS; null signals failure in practice. |
| `FileCacheHandle_t` | `void*` | Whole-file cache handle; destroy with the FS. |
| `FileFindHandle_t` | `int` | Directory-search cursor; not a file handle. |
| `WaitForResourcesHandle_t` | `int` | Resource-wait token. |
| `FSAsyncControl_t` | pointer handle via `DECLARE_POINTER_HANDLE` | Ref-counted async operation. |

`FSAsyncControl_t` is declared as a pointer to a dummy struct
(`src/public/tier0/basetypes.h:366`). The interface exposes `AsyncAddRef` and
`AsyncRelease` (`src/public/filesystem.h:730-731`), so ownership is ref-counted.
Balance the references and finish or abort the operation before discarding the
handle. Do not free the pointee.

`FileNameHandle_t` is `void*` (`src/public/tier1/utlsymbol.h:232`) and names a
symbol-table entry, not a path string. A `FileFindHandle_t` is an `int` and must
not be confused with `FileHandle_t`.

The full policy for engine `game://` content versus `std.Io`-backed
`plugin://` content is in `docs/references/source-sdk/filesystem.md` §12. The
type-level rule is simpler: a `FileHandle_t` is opaque, has no Zig-owned
lifetime, and must be closed by the FS that produced it.

### 4.4 Steam IDs, `CSteamID`, and `CGlobalVars`

**[checkout]** `CSteamID` is a class whose storage is a 64-bit union
(`src/public/steam/steamclientpublic.h:473-813`). `k_steamIDNil` is a
default-constructed value (`:883`), and `ConvertToUint64()` is the explicit
conversion (`:611`). `AccountID_t` is `uint32`, `AppId_t` is `uint32`
(`src/public/steam/steamtypes.h:85,100`).

Do not model `CSteamID` as a bare `u64` in a function signature unless the
calling boundary is known to pass it by value under a C-compatible ABI. For
storage, a `u64` mirror is reasonable; for calls, keep it behind a verified
wrapper.

**[checkout]** `CGlobalVars` derives from `CGlobalVarsBase`
(`src/public/edict.h:41-64`). The base fields
(`src/public/globalvars_base.h:33-76`) include:

| Field | Type | Meaning |
|---|---|---|
| `realtime` | `float` | Per-frame absolute time, not a high-precision clock. |
| `framecount` | `int` | Frame counter, not a tick. |
| `absoluteframetime` | `float` | Non-paused frame time. |
| `curtime` | `float` | Current simulation time; meaning is context-dependent on the client. |
| `frametime` | `float` | Last frame time. |
| `maxClients` | `int` | Current max-players setting. |
| `tickcount` | `int` | Simulation tick. |
| `interval_per_tick` | `float` | Tick interval. |
| `interpolation_amount` | `float` | Client-only interpolation fraction. |
| `simTicksThisFrame` | `int` | Ticks simulated this frame. |
| `network_protocol` | `int` | Protocol version. |
| `pSaveData` | `CSaveRestoreData*` | Engine save/restore state. |

`CGlobalVars` adds `mapname` (`string_t`), `mapversion`, `startspot`
(`string_t`), `eLoadType`, `bMapLoadFailed`, `deathmatch`, `coop`, `teamplay`,
`maxEntities`, and `serverCount` (`src/public/edict.h:47-64`).

Lifetime rules:

- `CGlobalVars*` is borrowed from the game DLL, not owned by the plugin. The
  sample plugin obtains it from `IPlayerInfoManager::GetGlobalVars()`
  (`src/utils/serverplugin_sample/serverplugin_empty.cpp:167-170`; [doc] §5.5).
  On the public surface inspected here, that manager is the only accessor, so
  the pointer is unavailable if the manager was not acquired.
- Do not cache the pointer across a level transition. Re-query it after
  `LevelInit`/`ServerActivate`.
- Do not use `realtime` as a monotonic gameplay clock; use `curtime` and
  `tickcount` according to the same rules as the game DLL.

### 4.5 Plugin cookies and results

**[checkout]** `QueryCvarCookie_t` is `int` and `InvalidQueryCvarCookie` is
`-1` (`src/public/engine/iserverplugin.h:43-44`). `StartQueryCvarValue` is
asynchronous; the cookie is the only way to match the later
`OnQueryCvarValueFinished` callback (`:153-160`). The interface declares no
cancel method, so a plugin must keep the cookie valid until the matching callback
arrives or it explicitly abandons the query. Do not reuse a cookie for a new
query while the old one may still complete.

`EQueryCvarValueStatus` is an `int`-sized enum with values
`0..3` (`:34-40`). `PLUGIN_RESULT` is `0..2`
(`PLUGIN_CONTINUE`, `PLUGIN_OVERRIDE`, `PLUGIN_STOP`) (`:26-31`).

## 5. Tier 2 — TF2 gameplay enums

All of these are C enums whose values are part of the game's demo and network
compatibility surface. The header repeatedly says to append rather than insert.
That makes a Zig `enum` with an exhaustive switch the wrong default.

### 5.1 Player classes — `ETFClass`

**[checkout]** `src/game/shared/tf/tf_shareddefs.h:203-222`:

| Name | Value |
|---|---:|
| `TF_CLASS_UNDEFINED` | 0 |
| `TF_CLASS_SCOUT` | 1 |
| `TF_CLASS_SNIPER` | 2 |
| `TF_CLASS_SOLDIER` | 3 |
| `TF_CLASS_DEMOMAN` | 4 |
| `TF_CLASS_MEDIC` | 5 |
| `TF_CLASS_HEAVYWEAPONS` | 6 |
| `TF_CLASS_PYRO` | 7 |
| `TF_CLASS_SPY` | 8 |
| `TF_CLASS_ENGINEER` | 9 |
| `TF_CLASS_CIVILIAN` | 10 |
| `TF_CLASS_COUNT_ALL` | 11 |
| `TF_CLASS_RANDOM` | 12 |

`TF_CLASS_COUNT` is `TF_CLASS_COUNT_ALL` (`:196`), which is 11.
`TF_FIRST_NORMAL_CLASS` is `TF_CLASS_UNDEFINED + 1` (1) and
`TF_LAST_NORMAL_CLASS` is `TF_CLASS_CIVILIAN` (10), exclusive
(`:198-199`). `IsValidTFPlayerClass` therefore accepts `1..9`, not
`CIVILIAN` and not `RANDOM` (`:224`).

Two traps:

- `TF_CLASS_RANDOM` has a numeric value greater than `TF_CLASS_COUNT`; it is a
  menu/selection value, not a player class.
- The enum order is not the menu order; the header exposes a remap table
  `iRemapIndexToClass` (`:246`). Do not use a class value as an index into a
  menu array without that remap.

### 5.2 Teams

**[checkout]** `src/game/shared/shareddefs.h:278-283` and
`src/game/shared/tf/tf_shareddefs.h:31-50`:

| Name | Value | Note |
|---|---:|---|
| `TEAM_ANY` | -2 | "Any team" selector, not a team. |
| `TEAM_INVALID` | -1 | Invalid sentinel. |
| `TEAM_UNASSIGNED` | 0 | Not on a team. |
| `TEAM_SPECTATOR` | 1 | Spectator. |
| `LAST_SHARED_TEAM` | 1 | Last shared team value. |
| `TF_TEAM_RED` | 2 | `LAST_SHARED_TEAM + 1`. |
| `TF_TEAM_BLUE` | 3 | |
| `TF_TEAM_COUNT` | 4 | |
| `TF_TEAM_AUTOASSIGN` | 5 | `TF_TEAM_COUNT + 1`. |
| `TF_TEAM_HALLOWEEN` | 5 | Alias of `AUTOASSIGN`. |

`TF_TEAM_PVE_INVADERS` aliases `TF_TEAM_BLUE` and `TF_TEAM_PVE_DEFENDERS`
aliases `TF_TEAM_RED` (`:49-50`). These are semantic aliases, not new values.
`IsValidTFTeam` accepts only RED and BLUE (`:225`).

### 5.3 Weapons — `ETFWeaponType`

**[checkout]** `src/game/shared/tf/tf_shareddefs.h:405-524`:

- `TF_WEAPON_NONE = 0`.
- Values are dense through the current checkout; the last named value is
  `TF_WEAPON_FLAME_BALL`, and `TF_WEAPON_COUNT` follows it.
- **In this checkout, `TF_WEAPON_COUNT == 110`** (values `0..109`).
  This is a revision-specific number, not a live-server guarantee.
- The header says "ADD NEW WEAPONS HERE TO AVOID BREAKING DEMOS" (`:519-521`).

Do not confuse the weapon enum with loadout capacity:

| Constant | Value | Meaning |
|---|---:|---|
| `MAX_WEAPONS` | 48 | Max number of weapons available in a loadout/array (`shareddefs.h:118`). |
| `MAX_WEAPON_SLOTS` | 6 | HUD item-selection slots (`shareddefs.h:115`). |
| `TF_PLAYER_WEAPON_COUNT` | 6 | Player weapon slots (`tf_shareddefs.h:375`). |
| `TF_PLAYER_GRENADE_COUNT` | 2 | Player grenade slots (`:376`). |
| `TF_PLAYER_BUILDABLE_COUNT` | 3 | Player buildable slots (`:377`). |

A weapon ID is an archetype, not an item definition index. Two econ items with
different attributes can share the same `TF_WEAPON_*` value. Conversely,
`item_definition_index_t` is a 16-bit econ namespace (see §6), not a weapon ID.

### 5.4 Conditions — `ETFCond`

**[checkout]** `src/game/shared/tf/tf_shareddefs.h:687-833`:

- `TF_COND_INVALID = -1`.
- Valid conditions start at `TF_COND_AIMING = 0`.
- The last explicitly numbered condition is `TF_COND_IMMUNE_TO_PUSHBACK = 130`.
- **`TF_COND_LAST == 131`** in this checkout.
- The header says "ADD NEW ITEMS HERE TO AVOID BREAKING DEMOS" (`:825-827`).
- `TFCondIndexToEnum` validates `nCond >= TF_COND_AIMING && nCond < TF_COND_LAST`
  (`:837-839`).

A condition ID is not a duration and not a provider. The game stores condition
state with timers/providers elsewhere; a plugin that only mirrors `ETFCond` is
not modeling the whole condition system. Unknown values from a newer server must
be preserved, not mapped to `INVALID`.

### 5.5 Objects — `ObjectType_t`

**[checkout]** `src/game/shared/tf/tf_shareddefs.h:1366-1383`:

| Name | Value |
|---|---:|
| `OBJ_DISPENSER` | 0 |
| `OBJ_TELEPORTER` | 1 |
| `OBJ_SENTRYGUN` | 2 |
| `OBJ_ATTACHMENT_SAPPER` | 3 |
| `OBJ_LAST` | 4 |

Object type is not the same as an entity classname, a building mode, or an econ
item definition. `BUILDING_MODE_ANY` is `-1` (`:1385`), while teleporter modes
and sentry modes are separate enums (`:1387-1397`). Keep them as distinct
newtypes; do not reuse one integer for all three concepts.

### 5.6 Hitgroups, damage flags, and engine enums

**[checkout]** Hitgroups are documented in `src/game/shared/shareddefs.h:376-384`:

| Name | Value |
|---|---:|
| `HITGROUP_GENERIC` | 0 |
| `HITGROUP_HEAD` | 1 |
| `HITGROUP_CHEST` | 2 |
| `HITGROUP_STOMACH` | 3 |
| `HITGROUP_LEFTARM` | 4 |
| `HITGROUP_RIGHTARM` | 5 |
| `HITGROUP_LEFTLEG` | 6 |
| `HITGROUP_RIGHTLEG` | 7 |
| `HITGROUP_GEAR` | 10 |

Values 8 and 9 are skipped. Do not validate a hitgroup by `<= 7` if the
`GEAR` case matters.

Damage flags are a 32-bit mask. `DMG_GENERIC` is 0; the named bits run from
`DMG_CRUSH` at bit 0 through `DMG_BUCKSHOT` at bit 29, and the header warns not
to add more generic flags (`src/game/shared/shareddefs.h:437-481`). Preserve the
whole word; a plugin that only knows bits 0..29 must not clear bits 30..31.

Other engine-side enums that appear in TF2-facing signatures:

| Type | Range / sentinel | Source |
|---|---|---|
| `MoveType_t` | 0..11; `MOVETYPE_LAST = MOVETYPE_CUSTOM` (11); `MOVETYPE_MAX_BITS = 4` | `src/public/const.h:192-211` |
| `MoveCollide_t` | 0..3; `MOVECOLLIDE_COUNT = 4`; `MOVECOLLIDE_MAX_BITS = 3` | `src/public/const.h:214-227` |
| `SolidType_t` | 0..6; `SOLID_BBOX` must be 2; `SOLID_VPHYSICS` must be 6 | `src/public/const.h:236-246` |
| `SolidFlags_t` | bitmask; `FSOLID_MAX_BITS = 10` | `src/public/const.h:248-263` |
| `RenderMode_t` | 0..`kRenderModeCount-1` | `src/public/const.h:351-366` |
| `RenderFx_t` | 0..`kRenderFxMax-1` | `src/public/const.h:368-396` |
| `Collision_Group_t` | 0..`LAST_SHARED_COLLISION_GROUP-1` | `src/public/const.h:398-424` |
| life state | `LIFE_ALIVE` 0 .. `LIFE_DISCARDBODY` 4 | `src/public/const.h:274-279` |
| entity effects | bitmask; `EF_MAX_BITS = 10` | `src/public/const.h:281-299` |
| entity flags | 32-bit `FL_*` family; `PLAYER_FLAG_BITS = 32` | `src/public/const.h:107-189` |

These are source-level ranges for this revision. A live server built from a
different SDK revision can have more values; use newtypes plus constants, not
closed Zig enums.

### 5.7 Limits and buffer sizes

**[checkout]** `src/public/const.h` and `src/public/edict.h`:

| Constant | Value | Use |
|---|---:|---|
| `ABSOLUTE_PLAYER_LIMIT` | 255 | Max players the engine can handle; not 256 so the limit fits a byte. |
| `MAX_PLAYER_NAME_LENGTH` | 32 | Name buffer, including NUL on PC. |
| `SIGNED_GUID_LEN` | 32 | Hashed CD key hex chars; buffer is 33 with NUL. |
| `MAX_NETWORKID_LENGTH` | 64 | Network ID buffer bound. |
| `MAX_MAP_NAME` | 96 | Decorated map name, including workshop suffixes. |
| `MAX_MAP_NAME_SAVE` | 32 | Save-file map-name bound. |
| `MAX_CUSTOM_FILES` | 4 | Custom logo/sound/model/text files. |
| `MAX_USER_MSG_DATA` | 255 | User-message payload. |
| `MAX_ENTITY_MSG_DATA` | 255 | Entity-message payload. |
| `MAX_SERVER_CLASS_BITS` | 9 | Server-class index bits. |
| `MAX_SERVER_CLASSES` | 512 | Networkable server classes. |
| `MAX_PACKEDENTITY_DATA` | 16384 | Packed-entity payload. |
| `MAX_PACKEDENTITY_PROPS` | 4096 | Delta'd properties. |
| `MAX_CHANGE_OFFSETS` | 19 | Per-edict changed-property list. |
| `MAX_EDICT_CHANGE_INFOS` | 100 | Shared change-info entries per frame. |

These are compile-time values of the SDK revision. They are not a promise about
the installed TF2 binary, especially `MAX_SERVER_CLASSES` and the packed-entity
limits. Validate against the target before relying on an array bound.

## 6. Tier 3 — secondary handles and econ

These types are lower priority because not every plugin needs them, but they
have the same "opaque handle, not an integer" property.

| Type | C++ shape | Sentinel / notes | Source |
|---|---|---|---|
| `FileHandle_t` | `void*` | Null on failure in practice; close through the owning FS. | `src/public/filesystem.h:38` |
| `FileCacheHandle_t` | `void*` | Destroy through the FS. | `src/public/filesystem.h:39` |
| `FSAsyncControl_t` | pointer handle | Ref-counted; `AsyncAddRef`/`AsyncRelease`. | `src/public/filesystem.h:304,730-731` |
| `FileNameHandle_t` | `void*` | Symbol-table handle, not a path. | `src/public/tier1/utlsymbol.h:232` |
| `MDLHandle_t` | `unsigned short` | `MDLHANDLE_INVALID = ~0`. | `src/public/datacache/imdlcache.h:42-57` |
| `HSOUNDSCRIPTHANDLE` | `short` | `SOUNDEMITTER_INVALID_HANDLE = -1`. | `src/public/SoundEmitterSystem/isoundemittersystembase.h:26-27` |
| `VPANEL` | `uintp` | UI panel handle; UI lifetime, not a server entity handle. | `src/public/vgui/VGUI.h:54` |
| `HTOOLHANDLE` | `unsigned int` | `HTOOLHANDLE_INVALID = 0`. | `src/public/toolframework/itoolentity.h:43-46` |
| `itemid_t` | `uint64` | `INVALID_ITEM_ID = (itemid_t)-1`. | `src/game/shared/econ/econ_item_constants.h:430,443` |
| `item_definition_index_t` | `uint16` | `INVALID_ITEM_DEF_INDEX = 0xFFFF`. | same, `:431,444` |
| `attrib_definition_index_t` | `uint16` | `INVALID_ATTRIB_DEF_INDEX = 0xFFFF`. | same, `:432,445` |
| `attrib_value_t` | `uint32` | Attribute value, type depends on the attribute. | same, `:433` |
| `style_index_t` | `uint8` | Style selector. | same, `:441` |
| `equip_region_mask_t` | `uint32` | Equip-region bitmask. | same, `:440` |
| `color32` | `byte r,g,b,a` | 4 bytes, no padding. | `src/public/tier0/basetypes.h:248-253` |
| `CSteamID` | 64-bit union | `k_steamIDNil`; use `ConvertToUint64()` at the boundary. | `src/public/steam/steamclientpublic.h:473-813,883` |
| `AccountID_t` | `uint32` | Steam account ID. | `src/public/steam/steamtypes.h:100` |
| `AppId_t` | `uint32` | Steam app ID. | `src/public/steam/steamtypes.h:85` |
| `VertexFormat_t` | `uint64` | Rendering bitmask; not plugin-core. | `src/public/materialsystem/imaterialsystem.h:61` |

Econ notes:

- `itemid_t` is a **Steam-backend unique item index**, not an entity index and
  not an item definition. All-ones is invalid.
- `item_definition_index_t` is a 16-bit schema index. It is not a weapon enum.
- Attribute values are untyped until the attribute definition says otherwise.
  Do not assume every `attrib_value_t` is a float or an int based on the field
  name.
- The econ schema and live item definitions are server/Steam-backed. The C++
  typedefs are stable; the values are not.

UI notes:

- `VPANEL` is pointer-sized and belongs to the VGUI/UI lifetime. A plugin that
  does not own a panel must not free or retain it.
- `HTOOLHANDLE` is a tool-framework handle with an explicit validity query
  (`IsValidHandle`); `0` is invalid.
- `HSOUNDSCRIPTHANDLE` is a signed 16-bit script handle; `-1` is the invalid
  sentinel.

## 7. Recommended `zostd` shapes

The following is the recommended shape for `src/zostd/types.zig`. It is
deliberately small and ABI-focused; it is not a wrapper framework.

```zig
//! Source-facing primitive types.
//!
//! These are ABI mirrors, not convenience wrappers. Every type here exists
//! because the SDK gives it a distinct C++ identity or a distinct sentinel.

/// A `CBaseHandle` value: low 16 bits are the entry index, high 16 bits are
/// the serial number. `0xFFFF_FFFF` is the invalid sentinel.
///
/// The whole 32-bit word is preserved. In particular, a server-side handle may
/// use only 15 serial bits because the game reserves the high bit for static
/// props; that is a producer policy, not a type invariant.
pub const EntityHandle = extern struct {
    bits: u32,

    pub const invalid: EntityHandle = .{ .bits = 0xFFFF_FFFF };
    pub const entry_mask: u32 = 0xFFFF;
    pub const serial_shift: u5 = 16;

    /// Build a handle from an entry index and a serial. The index is the raw
    /// 16-bit field, not an `EdictIndex`; the caller is responsible for using
    /// a producer-valid index.
    pub fn fromParts(index: u16, serial: u16) EntityHandle {
        return .{ .bits = @as(u32, index) | (@as(u32, serial) << serial_shift) };
    }

    /// True when the value is not the invalid sentinel. This does not prove
    /// that the target entity is alive; use a host resolver for that.
    pub fn isValid(self: EntityHandle) bool {
        return self.bits != invalid.bits;
    }

    /// Raw low 16 bits. For the invalid sentinel this returns `0xFFFF`, which
    /// is intentionally not the same as `CBaseHandle::GetEntryIndex()`'s
    /// legacy 8191 result.
    pub fn rawIndex(self: EntityHandle) u16 {
        return @truncate(self.bits & entry_mask);
    }

    /// High 16 bits. The server may use 15 meaningful bits; do not truncate
    /// here.
    pub fn serial(self: EntityHandle) u16 {
        return @truncate(self.bits >> serial_shift);
    }

    /// The full entity-list slot index, if the handle is not the sentinel.
    pub fn entityIndex(self: EntityHandle) ?EntityIndex {
        if (!self.isValid()) return null;
        return .{ .value = self.rawIndex() };
    }

    /// The networkable edict index, if the handle names a networkable slot.
    pub fn edictIndex(self: EntityHandle) ?EdictIndex {
        const index = self.entityIndex() orelse return null;
        return index.toEdictIndex();
    }
};

/// A full entity-list slot (`0..NUM_ENT_ENTRIES-1`, i.e. `0..8191`).
pub const EntityIndex = extern struct {
    value: u16,

    pub const max_value: u16 = 8191;

    pub fn toEdictIndex(self: EntityIndex) ?EdictIndex {
        if (self.value >= EdictIndex.max_count) return null;
        return .{ .value = self.value };
    }
};

/// A networkable edict slot (`0..MAX_EDICTS-1`, i.e. `0..2047`).
pub const EdictIndex = extern struct {
    value: u16,

    pub const max_count: u16 = 2048;

    pub fn toEntityIndex(self: EdictIndex) EntityIndex {
        return .{ .value = self.value };
    }
};

/// Opaque engine entity. Never construct, free, or lay out this type.
pub const Edict = opaque {};

/// Borrowed `edict_t*`. Nullable at callback boundaries where the engine may
/// pass null.
pub const EdictPtr = *Edict;

/// A `string_t` token. The size is build-mode dependent: 8 bytes for the strong
/// pointer form and `NO_STRING_T`, 4 bytes for `WEAK_STRING_T`. Do not expose
/// the token as text; decode through the host so the lifetime is explicit.
pub const StringToken = extern struct {
    bits: usize,
};

/// A model index. `-1` is invalid; values below `-1` are dynamic models.
pub const ModelIndex = extern struct {
    value: i32,

    pub fn isValid(self: ModelIndex) bool {
        return self.value != -1;
    }

    pub fn isPrecached(self: ModelIndex) bool {
        return self.value >= 0;
    }

    pub fn isDynamic(self: ModelIndex) bool {
        return self.value < -1;
    }

    /// Dynamic index `(-2 - value)`, or null for a non-dynamic value.
    pub fn dynamicIndex(self: ModelIndex) ?u32 {
        if (!self.isDynamic()) return null;
        return @intCast(-2 - self.value);
    }

    /// Dynamic models with an odd dynamic index are client-only.
    pub fn isClientOnly(self: ModelIndex) bool {
        const index = self.dynamicIndex() orelse return false;
        return (index & 1) != 0;
    }
};

/// Opaque `model_t`. Borrowed from `IVModelInfo`; never free.
pub const Model = opaque {};

/// Opaque engine file handle. The FS that produced it owns it.
pub const FileHandle = extern struct {
    raw: ?*anyopaque,

    pub fn isNull(self: FileHandle) bool {
        return self.raw == null;
    }
};

/// `TFClassType` / `ETFClass` value. Append-only; do not make this a Zig enum.
pub const TfClass = extern struct {
    value: i32,

    pub const undefined_class: TfClass = .{ .value = 0 };
    pub const scout: TfClass = .{ .value = 1 };
    pub const sniper: TfClass = .{ .value = 2 };
    pub const soldier: TfClass = .{ .value = 3 };
    pub const demoman: TfClass = .{ .value = 4 };
    pub const medic: TfClass = .{ .value = 5 };
    pub const heavyweapons: TfClass = .{ .value = 6 };
    pub const pyro: TfClass = .{ .value = 7 };
    pub const spy: TfClass = .{ .value = 8 };
    pub const engineer: TfClass = .{ .value = 9 };
    pub const civilian: TfClass = .{ .value = 10 };
    pub const count_all: TfClass = .{ .value = 11 };
    pub const random: TfClass = .{ .value = 12 };

    /// `IsValidTFPlayerClass`: normal classes are 1..9. Civilian and Random
    /// are not normal player classes.
    pub fn isNormalPlayer(self: TfClass) bool {
        return self.value >= 1 and self.value <= 9;
    }
};

/// Team value. Negative values are selectors/sentinels, not teams.
pub const TfTeam = extern struct {
    value: i32,

    pub const any: TfTeam = .{ .value = -2 };
    pub const invalid: TfTeam = .{ .value = -1 };
    pub const unassigned: TfTeam = .{ .value = 0 };
    pub const spectator: TfTeam = .{ .value = 1 };
    pub const red: TfTeam = .{ .value = 2 };
    pub const blue: TfTeam = .{ .value = 3 };
    pub const count: TfTeam = .{ .value = 4 };
    pub const autoassign: TfTeam = .{ .value = 5 };
    pub const halloween: TfTeam = .{ .value = 5 };
};

/// Weapon archetype ID. `count` is revision-specific, not a live-server
/// guarantee. Unknown IDs must pass through unchanged.
pub const TfWeaponId = extern struct {
    value: u32,

    pub const none: TfWeaponId = .{ .value = 0 };
    pub const count_in_this_sdk: TfWeaponId = .{ .value = 110 };

    pub fn isKnownInThisSdk(self: TfWeaponId) bool {
        return self.value < count_in_this_sdk.value;
    }
};

/// Condition ID. `-1` is invalid; `131` is the exclusive upper bound in this
/// SDK revision. Unknown values must pass through unchanged.
pub const TfCondition = extern struct {
    value: i32,

    pub const invalid: TfCondition = .{ .value = -1 };
    pub const first: TfCondition = .{ .value = 0 };
    pub const last_in_this_sdk: TfCondition = .{ .value = 131 };

    pub fn isKnownInThisSdk(self: TfCondition) bool {
        return self.value >= 0 and self.value < last_in_this_sdk.value;
    }
};

/// Object type. `obj_last` is the exclusive upper bound.
pub const TfObjectType = extern struct {
    value: u32,

    pub const dispenser: TfObjectType = .{ .value = 0 };
    pub const teleporter: TfObjectType = .{ .value = 1 };
    pub const sentrygun: TfObjectType = .{ .value = 2 };
    pub const attachment_sapper: TfObjectType = .{ .value = 3 };
    pub const obj_last: TfObjectType = .{ .value = 4 };
};

/// Damage flag mask. Preserve unknown bits.
pub const DamageMask = extern struct {
    bits: u32,
};

/// TF2 condition/query cookie. `-1` is invalid.
pub const QueryCvarCookie = extern struct {
    value: i32,

    pub const invalid: QueryCvarCookie = .{ .value = -1 };
};

// ABI size checks that are safe to assert from the SDK source. These do not
// replace binary verification of offsets inside CBaseEdict/CGlobalVars.
comptime {
    if (@sizeOf(EntityHandle) != 4) @compileError("EntityHandle must stay 4 bytes");
    if (@sizeOf(EntityIndex) != 2) @compileError("EntityIndex must stay 2 bytes");
    if (@sizeOf(EdictIndex) != 2) @compileError("EdictIndex must stay 2 bytes");
    if (@sizeOf(ModelIndex) != 4) @compileError("ModelIndex must stay 4 bytes");
    if (@sizeOf(TfClass) != 4) @compileError("TfClass must stay 4 bytes");
    if (@sizeOf(TfTeam) != 4) @compileError("TfTeam must stay 4 bytes");
    if (@sizeOf(TfWeaponId) != 4) @compileError("TfWeaponId must stay 4 bytes");
    if (@sizeOf(TfCondition) != 4) @compileError("TfCondition must stay 4 bytes");
    if (@sizeOf(TfObjectType) != 4) @compileError("TfObjectType must stay 4 bytes");
    if (@sizeOf(DamageMask) != 4) @compileError("DamageMask must stay 4 bytes");
    if (@sizeOf(QueryCvarCookie) != 4) @compileError("QueryCvarCookie must stay 4 bytes");
}
```

Notes on the code:

- `StringToken` has no size assertion. Its size is the exact thing that must be
  verified against the live build; asserting 8 here would hide the risk.
- `TfClass`, `TfTeam`, `TfCondition`, and `TfObjectType` use `i32`/`u32` to match
  the C `int`-sized ABI, not because the semantic range needs 32 bits.
- The `count_in_this_sdk`/`last_in_this_sdk` names are deliberate. Do not rename
  them to `count`; a future SDK revision will make the old constant wrong.
- The `EntityIndex.toEdictIndex()` check uses `EdictIndex.max_count` (2048).
  This is the networkable boundary, not `NUM_ENT_ENTRIES`.
- If `StringToken` is later confirmed to be the weak 4-byte form, change its
  storage to `u32` and update every ABI that embeds it.

## 8. Ownership and lifetime rules

| Type | Owner | Copyable? | Lifetime | Failure mode |
|---|---|---:|---|---|
| `edict_t*` | Engine | Pointer by value only | During callback/engine call; until the slot is freed | Freed slot; stale pointer |
| `EntityHandle` | Value | Yes | Stable value; target may die | Resolver returns null |
| `EdictIndex` | Value | Yes | Names a slot, not an incarnation | Slot may be free/reused |
| `EntityIndex` | Value | Yes | Full-list slot | May be non-networkable |
| `string_t` | Engine string table | Yes (token) | Token valid while table entry exists; `ToCStr()` transient | Dangling decoded pointer |
| `ModelIndex` | Value | Yes | Index valid for the level/model cache | `-1`; dynamic model may unload |
| `model_t*` | Engine | Pointer by value | Borrowed from `IVModelInfo` | Stale after unload/level change |
| `FileHandle_t` | FS | Handle by value | Until closed by the same FS | Double close; wrong FS |
| `FSAsyncControl_t` | FS, ref-counted | Handle by value | Until finished/released | Leak; use-after-release |
| `CSteamID` | Value | Yes | Stable value | Nil/invalid ID |
| `CGlobalVars*` | Game DLL | Pointer by value | Until level change | Stale after `LevelShutdown` |
| `player_info_t` | Engine | Yes (copy) | Filled per query | Stale embedded pointers |
| `QueryCvarCookie_t` | Value | Yes | Until matching callback or abandonment | Unknown cookie; no callback |
| `itemid_t` | Value | Yes | Stable backend ID | All-ones invalid |
| `HSOUNDSCRIPTHANDLE` | Sound emitter system | Yes | Until the script entry is unloaded | `-1` |
| `VPANEL` | VGUI | By value | UI lifetime | Stale panel |
| `HTOOLHANDLE` | Tool framework | Yes | Until detached/level end | `0` invalid |

Rules that apply across the table:

1. **Never let a borrowed pointer outlive the callback without an explicit
   engine guarantee.** The SDK's public headers describe lifecycle callbacks,
   not general-purpose retention.
2. **Never free an engine-owned object.** This includes edicts, models, panels,
   strings, and file handles.
3. **Resolve stale handles instead of dereferencing cached pointers.** A handle's
   serial is what protects against slot reuse.
4. **Copy text, not pointers.** `string_t::ToCStr()` and `player_info_t::guid`
   are transient views.
5. **Match the owning subsystem when closing.** A file handle from the engine
   FS is not a `std.fs.File`; a panel handle is not a heap allocation.

## 9. Integration findings for Zorcerer

### 9.1 `zostd/types.zig` is currently unused

**[checkout]** `src/zostd/types.zig` contains only:

```zig
const std = @import("std");
```

It exposes no types and has no callers in the current tree. Adding the shapes
above is therefore a new public surface, not a change to an established one.
Keep the first addition small and documented; do not bundle econ, UI, and
filesystem wrappers into the same change.

### 9.2 `HostApi` is at ABI version 1 and exposes only a logger

**[checkout]** `src/PluginContext.zig:26-45` defines `abi_version = 1` and a
`HostApi` with exactly two fields: `abi_version` and `logger`. A plugin compiled
against version 1 must reject a host with a different version before using the
struct (`:23-26`).

Adding an entity resolver would change the struct shape. Even an append-only
change needs a version bump so a new plugin can tell whether the field is
present; a new plugin reading a field past the end of an old host's struct would
be reading out of bounds. Recommended additions, when authorized:

```zig
pub const ResolveEntityFn = *const fn (
    context: *anyopaque,
    handle: types.EntityHandle,
) callconv(.c) ?*types.Edict;

pub const HandleForEdictFn = *const fn (
    context: *anyopaque,
    edict: *const types.Edict,
) callconv(.c) types.EntityHandle;
```

The host should implement these over the engine/game-DLL entity list, not by
casting the pointer to an integer. The plugin should receive handles, not raw
pointers, for anything that outlives a callback.

### 9.3 Callback signatures pass `edict_t*`

**[checkout]** `IServerPluginCallbacks` uses `edict_t*` in `ServerActivate`,
`ClientActive`, `ClientDisconnect`, `ClientPutInServer`, `ClientSettingsChanged`,
`ClientConnect`, `ClientCommand`, and `OnQueryCvarValueFinished`; it uses
`const edict_t*` in `OnEdictFreed`, and `edict_t*` in `OnEdictAllocated`
(`src/public/engine/iserverplugin.h:77-117`).

The adapter should convert at the boundary:

- On entry, derive `EntityHandle` from the edict for any plugin-facing callback.
- Resolve the handle only when the plugin actually needs the entity.
- Do not pass the raw `edict_t*` into a plugin API that can retain it.
- On `OnEdictFreed`, invalidate cached handles; the pointer is a notification
  argument, not a stable key.

### 9.4 `IPlayerInfoManager` has a version discrepancy in the docs

**[checkout]** `src/public/game/server/iplayerinfo.h:153` defines:

```cpp
#define INTERFACEVERSION_PLAYERINFOMANAGER "PlayerInfoManager002"
```

**[checkout]** `src/game/server/playerinfomanager.cpp:74` also exposes an older
`CPlayerInfoManager_V1` as `"PlayerInfoManager001"`, while line 132 exposes the
current `IPlayerInfoManager` under `INTERFACEVERSION_PLAYERINFOMANAGER`
(`"PlayerInfoManager002"`). `BotManager001` is exposed at line 133.

**[doc]** `docs/references/source-sdk-2013.md` §5.2 lists only
`"PlayerInfoManager001"` / `"BotManager001"` (line 176). That table is
incomplete for this checkout: the current interface string is `002`, with `001`
kept as a compatibility alias. Zorcerer should prefer `002` when available and
fall back to `001` only if the target binary lacks it; this is also a
**[binary]** question for the deployed server.

### 9.5 `string_t` affects `CGlobalVars` offsets

Because `CGlobalVars` embeds two `string_t` fields, the deployed server's
`string_t` mode changes the offsets of `mapversion`, `eLoadType`, and every
later field. A plugin that reads `CGlobalVars` through a hand-written Zig mirror
must not guess this layout. Either:

- obtain `CGlobalVars` fields through host accessors, or
- verify the deployed mode and offsets against the binary before defining a
  mirror.

This is the highest-risk type in the inventory because it silently corrupts
reads rather than producing a type error.

### 9.6 Model indices are not model pointers

`IVModelInfo::GetModelIndex` returns an `int` with the dynamic encoding in
§4.2. A plugin that caches a `model_t*` across a level change is caching a
borrowed engine pointer with no lifetime guarantee. Cache the `ModelIndex` and
re-query, or keep the model alive through a documented engine reference.

### 9.7 Filesystem handles belong to the engine FS domain

`FileHandle_t` is `void*`, but it is not a `std.fs.File` and must not be closed
with `std.fs`. The `game://` versus `plugin://` split in
`docs/references/source-sdk/filesystem.md` §12 still applies: engine content is
read through pathIDs, while Zorcerer's own tree uses `std.Io`. A single opaque
`FileHandle` newtype is fine, but the backend must be tagged outside the type.

### 9.8 The analyzer should not model `edict_t` as an integer

The C++ analyzer's generated mirrors should treat `edict_t` as an opaque class
pointer and `CBaseHandle` as a 32-bit value. Any codegen that emits `edict_t` as
`int` or as a packed struct will produce wrong vtable/field assumptions. The
frozen-layout comment is evidence that the fields exist, not evidence that
Zig can reproduce the class safely.

## 10. Verified versus binary-dependent

| Claim | Status | Evidence | What remains |
|---|---|---|---|
| `edict_t` is a class pointer, not an integer | Verified | `src/public/edict.h:429-436` | None. |
| `CBaseHandle` is a 32-bit value: 16-bit index + 16-bit serial | Verified | `src/public/basehandle.h:80,119-125`; `const.h:76-83` | Confirm size/alignment in the deployed ABI. |
| Invalid handle is `0xFFFFFFFF` | Verified | `const.h:79`; `basehandle.h:132-135` | None. |
| `GetEntryIndex()` returns 8191 for invalid | Verified | `src/public/basehandle.h:137-154` | None. |
| Server serials use a 15-bit mask | Verified | `src/game/shared/entitylist_base.cpp:14-16,250-251` | Confirm the deployed game DLL uses this code. |
| Networked handles use 10 serial bits | Verified | `const.h:86-89` | None at source level. |
| `MAX_EDICTS = 2048`, `NUM_ENT_ENTRIES = 8192` | Verified | `const.h:64-78` | Confirm live engine build. |
| Only the first 2048 slots are networkable | Verified | `entitylist_base.h:107-108`; `entitylist_base.cpp:173-176` | None. |
| Non-networkable free list starts at 2049 | Verified | `entitylist_base.cpp:150-156` | None. |
| `string_t` is strong/pointer-sized in the server build | Verified for this checkout's VPC set | `string_t.h:17-111`; server VPCs define neither mode; client VPC defines `NO_STRING_T` | Live TF2 mode and ABI. |
| Model index encoding (`-1`, `< -1`, parity) | Verified | `ivmodelinfo.h:89-99` | None. |
| `FileHandle_t` is `void*`; `FSAsyncControl_t` is ref-counted | Verified | `filesystem.h:38-42,304,730-731` | None. |
| `CSteamID` is a 64-bit value with a nil sentinel | Verified | `steamclientpublic.h:473-813,883` | Calling-convention details in the deployed binary. |
| `CGlobalVars` embeds `string_t` fields | Verified | `edict.h:41-64`; `globalvars_base.h:33-76` | Offsets and live `string_t` mode. |
| `TF_CLASS_COUNT = 11`, normal classes 1..9 | Verified | `tf_shareddefs.h:196-224` | None for this revision. |
| `TF_TEAM_RED = 2`, `BLUE = 3`, `COUNT = 4` | Verified | `shareddefs.h:278-283`; `tf_shareddefs.h:31-50` | None for this revision. |
| `TF_WEAPON_COUNT = 110` | Verified in this checkout | `tf_shareddefs.h:405-524` | Live TF2 may be higher. |
| `TF_COND_LAST = 131` | Verified in this checkout | `tf_shareddefs.h:687-833` | Live TF2 may be higher. |
| `OBJ_LAST = 4` | Verified | `tf_shareddefs.h:1366-1383` | Live TF2 may add objects. |
| Hitgroups 0..7 plus 10 | Verified | `shareddefs.h:376-384` | None. |
| `QueryCvarCookie_t` is `int` with `-1` invalid | Verified | `iserverplugin.h:43-44` | None. |
| `PlayerInfoManager002` exists, with `001` alias | Verified | `iplayerinfo.h:153`; `playerinfomanager.cpp:74,132-133` | Which version the deployed server exposes. |
| Live interface version strings | **Binary-dependent** | `[doc]` §5, §7.1 | Probe the installed server `.so`. |
| Numeric vtable indices | **Binary-dependent** | `[doc]` §6.2-6.3 | Extract `_ZTV`/typeinfo or runtime-probe. |
| RTTI presence | **Binary-dependent** | `[doc]` §6.2, §7.3 | Inspect build flags/binary. |
| `CBaseEdict`/`CGlobalVars` offsets | **Binary-dependent** | `[doc]` §6.2, §7.4 | DWARF/disassembly/runtime probe. |
| `string_t` mode in the live server | **Binary-dependent** | `[doc]` §7; source modes above | Compile probe or binary inspection. |
| Live `MAX_EDICTS`/limits | **Binary-dependent** | `[doc]` §7 | Probe or test at runtime. |
| Live TF2 enum counts | **Binary-dependent** | This report is revision-specific | Probe the deployed game DLL/schema. |
| Econ item IDs/definitions | **Binary/backend-dependent** | C++ typedefs only | Steam/econ schema, not the SDK. |

## 11. Priorities

### P0 — do before exposing entity types to plugins

1. **Verify the deployed `string_t` mode.** It changes `CGlobalVars` and any
   network-var layout. A wrong guess is silent memory corruption.
2. **Verify `CBaseHandle` size/packing and the edict/CGlobalVars offsets** in the
   target binary. The source shapes are strong evidence, not a binary contract.
3. **Decide the entity-resolution API.** `EntityHandle` without a resolver is
   just a number; define `resolve`/`handle_for_edict` before publishing it.

### P1 — define the stable surface

4. Add `EntityHandle`, `EdictIndex`, and `EntityIndex` to `zostd/types.zig`
   with compile-time size checks and documentation.
5. Add the TF2 newtypes (`TfClass`, `TfTeam`, `TfWeaponId`, `TfCondition`,
   `TfObjectType`) and their revision-specific bounds. Do not add exhaustive
   enums.
6. Resolve the `PlayerInfoManager001`/`002` discrepancy in the adapter and
   update the parent reference when authorized.

### P2 — adapter hardening

7. Add model-index helpers and document that `model_t*` is borrowed.
8. Add `FileHandle`/`FSAsyncControl_t` wrappers only where a plugin-facing API
   actually needs them; keep the engine-FS/`std.Io` split outside the type.
9. Encode the plugin callback boundary conversion (`edict_t*` → `EntityHandle`)
   once, in the adapter, rather than in every plugin.

### P3 — secondary domains

10. Econ IDs and item-definition indices.
11. VGUI `VPANEL` and tool `HTOOLHANDLE`, if a plugin-facing feature needs them.
12. Sound-script handles, if sound editing becomes a plugin capability.

## 12. Open decisions

1. **Opaque or transparent `EntityHandle`?** Recommendation: keep `bits` public
   for ABI mirroring but expose accessors; do not encourage plugins to do
   arithmetic on the word.
2. **Should `EntityHandle` enforce the 15-bit server serial?** Recommendation:
   no. The mask is a producer policy; enforcement would reject valid handles
   from other producers.
3. **`EdictIndex` vs `EntityIndex` naming.** Recommendation: keep both. Merging
   them hides the 2048/8192 distinction that the engine relies on.
4. **`StringToken` representation.** Recommendation: opaque pointer-sized token
   until the live mode is verified; then narrow it if necessary.
5. **Unknown enum values.** Recommendation: preserve and pass through; validate
   only at the point where a known-revision operation requires a known value.
6. **When to bump `HostApi`.** Recommendation: bump when the first resolver is
   added, and make new plugins check `abi_version` before touching appended
   fields. Do not append silently.
7. **Econ scope.** Recommendation: defer. The C++ typedefs are easy; the live
   schema and item semantics are not.
8. **Analyzer codegen.** Recommendation: emit `edict_t` as an opaque pointer and
   `CBaseHandle` as `u32`; do not attempt to reconstruct `CBaseEdict` fields
   without binary offsets.

## 13. Summary

- The central correction is that **`edict_t` is a class pointer, not an
  integer**. The integer identity is `CBaseHandle`: a 32-bit `(index, serial)`
  pair with a `0xFFFFFFFF` sentinel.
- The engine has two slot namespaces: 2048 networkable edicts and 8192 total
  entity-list slots. `EdictIndex` and `EntityIndex` must be distinct Zig types.
- `CBaseHandle` survives slot reuse through its serial, but `IsValid()` only
  means "not the sentinel". Liveness requires a resolver.
- `string_t` is the highest-risk primitive: its representation is
  compile-time-selectable, and `CGlobalVars` embeds it. The source selects the
  strong form for the server build, but the live TF2 mode is unverified.
- TF2 gameplay values are append-only C enums. Model them as newtypes with
  revision-specific constants, not as closed Zig enums. `TF_WEAPON_COUNT = 110`
  and `TF_COND_LAST = 131` are this checkout's values, not live guarantees.
- The recommended `zostd` surface is a small set of `extern struct` newtypes:
  `EntityHandle` (`u32` bits), slot indices (`u16`), opaque pointers, and
  integer-valued TF2 newtypes.
- `HostApi` currently exposes only a logger at ABI version 1. Any entity
  resolver is a new ABI surface and needs a version bump.
- The parent reference's `PlayerInfoManager001`-only table is incomplete:
  this checkout defines `PlayerInfoManager002` and exposes `001` as a
  compatibility alias.
- No build or test was run. Every binary-dependent claim in §10 still needs
  verification against the installed TF2 dedicated server before the type
  mirrors are treated as ABI-correct.
