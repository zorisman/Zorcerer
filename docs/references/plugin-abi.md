# ## Bottom line

**The native plugin ABI is currently `load()` + `unload()` + a logger — enough to open a `.so`, not enough to write a useful plugin.**

- More ABI **surface** is needed: events, plugin identity/config, host-mediated engine access, and file/service access.
- More exported **symbols** are not necessarily needed. Keeping `load`/`unload` as the only plugin exports and growing a versioned `HostApi` function table is the cleaner direction.
- The Source-side VSP vtable is layout-correct for `ISERVERPLUGINCALLBACKS003`, but most callbacks are stubs. That is safe for loading/unloading, but the engine events plugins would care about never reach native plugins at all.

Note: `PluginManager.zig` has no functions literally named `load()`/`unload()`; the manager-side equivalents are `loadPlugins()` / `unloadAll()`, while `load()`/`unload()` are the plugin-exported entry points in `PluginContext.zig`.

---

## 1. Source VSP loading flow

The Source engine loading a Valve Server Plugin works like this:

1. The engine finds the `.vdf`, `dlopen()`s the plugin `.so`, and calls the exported `CreateInterface(...)`.
2. `Entrypoint.CreateInterface()` (`Entrypoint.zig:923-933`) matches `ISERVERPLUGINCALLBACKS003/002/001` (`Entrypoint.zig:100-104`) and returns a `PluginObject` whose vptr points at `Entrypoint.vtable` (`Entrypoint.zig:124-128`, `911-921`).
3. The engine calls vtable slot 0, `Load(CreateInterfaceFn, CreateInterfaceFn)` (`Entrypoint.zig:697-793`).
4. `Entrypoint.load()`:
   - uses `interface_factory` to probe `VEngineServer023/022/021` (`Entrypoint.zig:115-119`, `726-744`),
   - extracts `IVEngineServer::LogPrint` from generated slot 72 (`Entrypoint.zig:154-157`, `engine_indexes.zig:4614`),
   - refuses the plugin unless the engine answered exactly `VEngineServer023` (`Entrypoint.zig:749-755`),
   - wires the logger (`Entrypoint.zig:759`),
   - forks the manager child (`Entrypoint.zig:766-769`),
   - waits for its `ready` notification (`Entrypoint.zig:776-783`).
5. The child loads native plugins and Lua scripts, then reports readiness.
6. The engine calls the remaining VSP callbacks. Currently only `pause`, `unpause`, `levelInit`, `serverActivate`, and `levelShutdown` are forwarded (`Entrypoint.zig:832-893`); `gameFrame` is a no-op (`Entrypoint.zig:884-887`); client callbacks are `genericStub` (`Entrypoint.zig:902-921`).
7. On unload, the engine calls vtable slot 1, `Unload()` (`Entrypoint.zig:795-815`), which closes the IPC socket, causing the child’s `listenForEvents()` to see EOF, unload its plugins, and exit.

### Vtable check

The implemented order matches the SDK header exactly:

| Slot | Header method | Entrypoint |
|---|---|---|
| 0 | `Load` | implemented |
| 1 | `Unload` | implemented |
| 2 | `Pause` | implemented |
| 3 | `UnPause` | implemented |
| 4 | `GetPluginDescription` | implemented |
| 5 | `LevelInit` | implemented |
| 6 | `ServerActivate` | implemented |
| 7 | `GameFrame` | no-op |
| 8 | `LevelShutdown` | implemented |
| 9–19 | client/edict callbacks | `genericStub` |

The header has 20 methods (`extern/source/.../iserverplugin.h:54-118`), and the generated index table agrees (`engine_indexes.zig:4948-4969`). With 9 real entries plus 20 stubs, the vtable is safe for the current interface. A future interface with more than 29 methods would overrun the array, as the module comment warns.

So, for **loading**: no additional VSP slots are required. For **useful event delivery**: yes, several slots are currently dead ends.

---

## 2. Native plugin loading flow

`Manager.loadPlugins()` (`PluginManager.zig:240-309`) does:

1. Refuses if anything is already loaded.
2. Iterates directories under `tf/addons/zorcerer/plugins`.
3. Calls `loadLuaScript(dir.name)` unconditionally (`PluginManager.zig:276`).
4. Reads `manifest.toml`; **if it is missing or unreadable, it `continue`s and skips the directory’s `.so` files entirely** (`PluginManager.zig:284-287`). This contradicts the comment at `PluginManager.zig:278-281`, which says such directories are “only picked up through [their] `.so` file(s).”
5. Parses the manifest through `PluginConfiguration.parseConfig()` (`PluginManager.zig:290-293`).
6. Stores the parsed configuration in a local `managed_plugins` list (`PluginManager.zig:295-298`). That list is never freed or retained — the TODO at `PluginManager.zig:253-254` acknowledges the leak.
7. Scans `.so` files and calls `cachePlugin()` (`PluginManager.zig:300-307`).

`cachePlugin()` (`PluginManager.zig:314-345`):

1. Joins the path.
2. `std.DynLib.open()`.
3. Looks up both `load` and `unload` exports; a plugin missing either is skipped.
4. Appends a `Plugin` record.
5. Calls `activatePlugin()`.

`activatePlugin()` (`PluginManager.zig:349-358`) builds `HostApi` containing only the logger, calls `plugin.load(&host)`, and marks the plugin active only when the return value is `0`.

`unloadAll()` (`PluginManager.zig:365-400`) walks native plugins in reverse order, calls `unload()` only for active plugins, always `dlclose()`s and frees the path, then notifies and tears down Lua scripts.

The ABI itself is in `PluginContext.zig:26-51`:

```zig
HostApi { abi_version, logger }
load(host) -> int
unload(host) -> int
```

---

## 3. What reaches plugins today

| Capability | Native `.so` | Lua |
|---|---|---|
| Load/unload lifecycle | yes | `on_load` / `on_unload` |
| Logging | yes | `zostd.log` |
| Pause/UnPause | **no** | yes |
| LevelInit/ServerActivate/LevelShutdown | **no** | yes |
| GameFrame | **no** | **no** |
| Client callbacks | **no** | **no** |
| Plugin id / root / manifest data | **no** | id and root only |
| Engine commands / cvars / game FS | **no** | `server_command` exists but is not wired by the manager |
| IPC/event payloads | **no** | only event name, payload always `nil` |

This is the key finding: `Manager.dispatchEvent()` only loops over `lua_scripts` (`PluginManager.zig:532-536`). Native plugins are loaded and unloaded, but **never receive any event after `load()`**. The Source `pause`, `levelInit`, etc. go through IPC only to Lua.

---

## 4. Flow problems worth fixing regardless of ABI

1. **Manifest schema mismatch.** `PluginManager.Manifest` expects `id`, `file` (`PluginManager.zig:22-28`), while `PluginConfiguration` expects `plugin_id`, `lib_path` (`PluginConfiguration.zig:29-47`). The parent calls `readConfig()` after readiness and swallows errors (`Entrypoint.zig:785`), so real manifests in the current schema silently produce no output.
2. **Manifest data is parsed but not used.** `lib_path` is never consulted; every `.so` in the directory is loaded (`PluginManager.zig:300-307`). `managed_plugins` is leaked.
3. **No manifest means no native plugin.** A `.so` without `manifest.toml` is skipped, despite `build.zig:24-26` saying a missing manifest is allowed.
4. **`game_server_factory` is ignored** (`Entrypoint.zig:702-703`). It is the normal route to server-side interfaces such as `ServerGameDLL`, `ServerGameClients`, and `ServerGameEnts`.
5. **Fork boundary blocks direct engine access.** The child inherits engine pointers, but calling them after `fork()` is unsafe (`Log.zig:13-16`). Any engine operation for plugins must be mediated by the parent over IPC, not by passing raw engine pointers into `HostApi`.
6. **Synchronous event exchange is a scalability limit.** `sendManagerEvent()` blocks the engine callback until the child replies (`Entrypoint.zig:832-849`). A slow plugin blocks the server. This is tolerable for level events, not for `GameFrame` or client commands.
7. **IPC payloads are absent/limited.** `Ipc.Event` carries no parameters (`Ipc.zig:276-300`), and frames are capped at 4096 bytes (`Ipc.zig:22`). Client command arguments or larger results will need payload support and a higher/chunked limit.
8. **`cachePlugin()` leaks on append failure.** If `plugins.append()` fails after `DynLib.open()`, the library is not closed (`PluginManager.zig:337-342`).

---

## 5. Do plugins need more ABI functions?

### Short answer

**Yes, but preferably not as more exported plugin functions.** Keep `load`/`unload` as the stable entry contract and grow the host-provided side of the ABI.

### Recommended ABI shape

1. **Event delivery to native plugins — required.**
   Either:
   - add one optional export such as `on_event(event, payload) -> int`, or
   - let plugins register callbacks through `HostApi` (e.g. `host.events.subscribe(callback, context)`).

   The callback-table approach is cleaner: it avoids dlsym name proliferation and lets the ABI version the callback signature.

2. **Plugin identity and configuration — required.**
   `HostApi` should expose at least `plugin_id`, plugin root directory, name/version/author, and access to the parsed manifest. The example plugin currently hardcodes `plugin_id = "hello"` and derives `tf/addons/zorcerer` itself (`example-plugins/hello/hello_plugin.zig:44-73`), which will break as soon as the directory or install layout changes.

3. **Host-mediated engine operations — required for real plugins.**
   Add function pointers for operations such as `server_command`, cvar get/set, `game://` file access, and controlled interface queries. These must go through the parent Entrypoint over IPC and be allowlisted there; the child must never dereference inherited engine vtables.

4. **ABI version/size negotiation — recommended.**
   `abi_version` lets the plugin reject the host (`PluginContext.zig:23-26`), but there is no `struct_size` or function-table version. Once `HostApi` grows, a plugin compiled against a newer header could read past an older host’s struct. Add an explicit `size` field or a versioned pointer to a function table, and document append-only layout rules.

5. **Lifecycle/event coverage.**
   If plugins need Source callbacks, add them in this order:
   - `levelInit`, `serverActivate`, `levelShutdown`, `pause`, `unpause` to native plugins (currently Lua-only),
   - `gameFrame` only if genuinely needed, because synchronous per-tick IPC is expensive,
   - client callbacks (`ClientActive`, `ClientDisconnect`, `ClientPutInServer`, `ClientSettingsChanged`, `ClientConnect`, `ClientCommand`, `NetworkIDValidated`, `OnQueryCvarValueFinished`, `OnEdictAllocated/Freed`) by replacing the relevant `genericStub` slots.

6. **Inter-plugin dependencies/services.**
   `docs/Architecture.md:19-24` plans a dependency graph, but `loadPlugins()` uses filesystem order and `unloadAll()` simply reverses discovery order. If plugin dependencies are planned, the host ABI also needs a way to resolve/request another plugin’s services and the loader needs topological ordering.

### What does *not* need to change

- The Source VSP vtable does **not** need more real slots merely to load and unload. The existing padding is safe for `ISERVERPLUGINCALLBACKS003`.
- Plugins do **not** need to export a large API surface. A single `load`/`unload` pair plus a versioned `HostApi` function table is sufficient and preserves the current contract.

### Suggested priority

**P0:** native event delivery, plugin identity/config, host-mediated engine calls, `HostApi` size/version negotiation.

**P1:** real `GameFrame`/client VSP callbacks, IPC payloads, per-plugin permissions/allowlists, dependency ordering.

**P2:** hot reload, async event dispatch, structured error reporting, richer service discovery.

In its current state, Zorcerer has a working **loader** and **isolation boundary**, but the native plugin ABI is still a prototype: plugins can log and run local code, but cannot meaningfully participate in the server.

