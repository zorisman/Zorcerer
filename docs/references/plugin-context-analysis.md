# `PluginContext.zig` review

Current file: `src/core/PluginContext.zig` (51 lines). It is a very small ABI contract:

- `abi_version`
- `Logger`
- `HostApi`
- `LoadFn`
- `UnloadFn`

### Does it contain anything useless for runtime?

**No. There is no dead runtime field or declaration in the file.** Every declaration has a current use:

| Declaration   | Runtime use                                                                   | Verdict                             |
|---------------|-------------------------------------------------------------------------------|-------------------------------------|
| `abi_version` | Embedded in `HostApi`; checked by the example plugin (`hello_plugin.zig:163`) | Needed                              |
| `Logger`      | Gives plugins a host-provided console sink                                    | Needed                              |
| `HostApi`     | Passed to every plugin `load()` / `unload()`                                  | Needed                              |
| `LoadFn`      | Used by the manager’s `dynlib.lookup` (`PluginManager.zig:325`)               | Host-side, but part of the contract |
| `UnloadFn`    | Used by the manager’s `dynlib.lookup` (`PluginManager.zig:331`)               | Host-side, but part of the contract |

The only thing worth calling out is that **`LoadFn` and `UnloadFn` are not used by plugin code itself** — they describe the exports from the host loader’s perspective. If you want the plugin-facing header to be as small as possible, they could live in a separate host-only file. But keeping them here is defensible because this file is explicitly the shared dlopen contract.

The default field values (`HostApi.abi_version = abi_version`, `HostApi.logger = null`) also have no runtime cost; they are compile-time conveniences.

The actual problem is not that the file contains useless things. It is that the file is **too small for a useful plugin runtime**.

---

## What the current contract can do

Today a native plugin can:

1. Be loaded.
2. Check the ABI version.
3. Log through the host.
4. Run arbitrary local code.
5. Be unloaded.

That matches the current summary in `docs/references/plugin-abi.md:3`: “enough to open a `.so`, not enough to write a useful plugin.”

`PluginManager.hostApi()` confirms this — it only fills the logger:

```zig
fn hostApi(self: *@This()) abi.HostApi {
    return .{ .logger = if (self.logger) |*logger| logger else null };
}
```

---

## What plugins likely need next

### P0 — required for a useful native plugin

#### 1. Plugin identity and configuration

`HostApi` currently has no plugin id, name, version, author, root directory, or manifest data.

This forces plugins to hardcode what the host already knows. `example-plugins/hello/hello_plugin.zig:20-24` explicitly says it derives its own roots because “the v1 HostApi carries no path information,” and `:63-72` hardcodes the plugin id and library path.

Meanwhile, the manager already parses `PluginConfiguration` with `id`, `name`, `version`, `author`, and `path` (`PluginConfiguration.zig:29-47`). It is currently stored in a local `managed_plugins` list (`PluginManager.zig:295-298`) but not passed to plugins.

Add something like a host-owned `PluginInfo`:

- `id`
- `name`
- `version`
- `author`
- plugin root / directory
- library path
- manifest path/data

This is also called out in `docs/references/plugin-abi.md:134-135`.

#### 2. Event delivery

Native plugins currently receive no events after `load()`. `PluginManager.dispatchEvent()` only iterates `lua_scripts` (`PluginManager.zig:532-536`), while the source VSP callbacks send `pause`, `levelInit`, `serverActivate`, etc. only to Lua.

Native plugins need either:

- one exported `on_event(event, payload)` function, or
- a host-side registration API such as `HostApi.events.subscribe(callback, context)`.

The callback-table approach is preferable because it avoids dlsym symbol proliferation and lets the ABI version the callback signature. This is the main P0 recommendation in `docs/references/plugin-abi.md:127-132`.

#### 3. Host-mediated engine operations

The child process must never dereference inherited engine pointers after `fork()`; `docs/references/plugin-abi.md:112` and `io/Log.zig:13-16` both state this. Engine operations must be mediated by the parent over IPC.

Useful host operations would include:

- `server_command`
- cvar get/set
- interface queries
- game event operations
- engine filesystem access
- entity/player queries later

Currently `game_server_factory` is ignored (`Entrypoint.zig:137`), and the plugin-facing filesystem module still has no engine binding; `FileSystem` returns `error.EngineNotBound` for `game://` operations.

#### 4. ABI size/version negotiation

`abi_version` is a single integer. It detects incompatible versions, but it does not tell either side how large the `HostApi` struct is or which trailing fields are valid.

Add either:

- a `struct_size` field, or
- a versioned function-pointer table with an explicit size/version.

This is recommended in `docs/references/plugin-abi.md:140-141`. It matters because `HostApi` is an `extern struct`; adding fields later without negotiation is dangerous across separately compiled plugins.

---

### P1 — needed for realistic plugins

#### 5. File read/write with clear ownership

Lua already has `read_file` and `write_file` callbacks (`src/zlua/zostd.zig:48-53`), but native plugins do not.

If you add them to `HostApi`, define ownership explicitly:

- who allocates the returned buffer,
- who frees it,
- whether allocators may cross the DSO boundary,
- maximum sizes,
- whether paths are `plugin://`, `game://`, or plain relative paths.

A host-owned buffer or an allocator callback is safer than expecting `free()` from a different shared library.

#### 6. Structured error reporting

`load()` / `unload()` return only `c_int`. A plugin cannot tell the manager why it failed.

At minimum, the host can log through `Logger`. Better would be a callback or result structure with:

- status code,
- error class,
- message,
- optional plugin id / source location.

#### 7. Permissions and capability limits

Host-mediated engine operations are powerful. Once `server_command`, cvars, or filesystem writes are exposed, the manager needs a policy:

- per-plugin allowlists,
- which operations are allowed,
- which paths are writable,
- whether a plugin can issue arbitrary server commands.

`docs/references/plugin-abi.md:161` lists per-plugin permissions as P1.

#### 8. Threading and reentrancy contract

The synchronous event exchange blocks the engine callback until the child responds (`Entrypoint.zig:261-278`). If plugins receive events, the ABI should document:

- which thread callbacks run on,
- whether callbacks may block,
- whether the host API is reentrant,
- what happens if a plugin calls back into the host during event dispatch.

This is a documentation/contract issue, not necessarily a new field.

---

### P2 — vision-level needs

`docs/Architecture.md:19-24` plans manifests, dependency graphs, loading order, and runtime. For that vision, plugins may eventually need:

- dependency resolution / service lookup between plugins,
- plugin-to-plugin interfaces,
- hot reload,
- async event dispatch,
- richer host service discovery.

These are not required to make the current loader work, but they affect the long-term shape of `HostApi`.

---

## Recommended ABI shape

Keep `HostApi` append-only and capability-based:

```zig
pub const HostApi = extern struct {
    abi_version: c_int,
    struct_size: usize,
    logger: ?*const Logger,
    plugin: ?*const PluginInfo,
    events: ?*const EventApi,
    engine: ?*const EngineApi,
    files: ?*const FileApi,
};
```

Key rules:

- Every optional pointer must be null-checked by the plugin.
- Never put raw engine pointers in `HostApi`; engine access goes through parent-mediated IPC.
- New fields are appended only, with `struct_size`/version checks.
- Document ownership, lifetimes, threading, and error behavior for every callback.
- Align the native API with the existing Lua `Host` capabilities where it makes sense (`log`, `plugin_id`, `read_file`, `write_file`, `server_command`).

## Bottom line

`PluginContext.zig` contains **no useless runtime code**. It is a clean but minimal v1 contract: loading, unloading, and logging.

To let plugins actually operate, the next priorities are plugin identity/config, native event delivery, host-mediated engine/filesystem access, and ABI size negotiation. `LoadFn`/`UnloadFn` are host-side declarations but should stay in the shared contract unless you deliberately split host-only and plugin-only headers.

