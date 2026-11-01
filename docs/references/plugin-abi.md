# ## Bottom line

**The native plugin ABI is currently `load()` + `unload()` + an optional `onEvent()` hook + a logger + plugin identity + an optional read-only game-query table (ABI version 2) — enough to open a `.so`, identify it, deliver the six implemented runtime events, and read server/player/entity/cvar state through the parent process.**

- More ABI **surface** is needed: host-mediated engine access, file/service access, and additional event sites.
- More exported **symbols** are not necessarily needed. Keeping `load`/`unload` as the only required exports, adding optional `onEvent`, and growing the versioned `PluginContext` contract is the cleaner direction.
- The Source-side VSP vtable is layout-correct for `ISERVERPLUGINCALLBACKS003`, but most callbacks are stubs. Six engine callbacks (`pause`, `unpause`, `levelInit`, `serverActivate`, `levelShutdown`, `clientCommand`) now reach plugins over IPC.

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
5. The child loads Lua scripts and native plugins, reports readiness, and then
   serves engine events until the parent closes the channel.
6. The engine calls the remaining VSP callbacks. Currently only `pause`, `unpause`, `levelInit`, `serverActivate`, and `levelShutdown` are forwarded (`Entrypoint.zig`); `gameFrame` is a no-op; client callbacks are `genericStub`. `levelInit` and `serverActivate` include JSON payloads.
7. On unload, the engine calls vtable slot 1, `Unload()`, which closes the IPC socket, causing the child’s `listenForEvents()` to see EOF, unload its plugins, and exit.

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

`Manager.loadPlugins()` does:

1. Refuses if a native plugin or Lua script is already loaded.
2. Reads and validates every `manifest.toml` through `readConfig()`.
3. Iterates directories under `tf/addons/zorcerer/plugins` and loads each
   `main.lua` with its directory's `[network]` policy; a directory without a
   manifest uses a deny-all policy.
4. Resolves the native dependency graph over the configurations that name a
   `path` and reports static rejections; script-only manifests are skipped.
5. Creates each accepted plugin in dependency-first order: opens only the
   library named by `manifest.path`, looks up `load`/`unload` and the optional
   `onEvent`, and builds a per-plugin `PluginContext`.
6. Initializes the created plugins in the same order by calling `load(ctx)`.
7. Rejects a failed library or initialization and every transitive dependent;
   unrelated plugins continue loading.
8. Emits `runtime_entered` after the initialization pass.

`PluginLibrary.open()` (`src/core/PluginLibrary.zig`) owns the dlopen handle
and reports structured rejections: `library_not_found`,
`invalid_configuration`, or `missing_symbol`. A missing `onEvent` is not a
rejection. The manager turns rejections into a `library_rejected` event.

`unloadAll()` walks native plugins in reverse order, calls `unload(ctx)` only
for initialized plugins, always closes the library, frees the context, and frees
the path, then notifies and tears down Lua scripts.

The ABI itself is in `src/core/PluginContext.zig` (version 2):

```zig
PluginContext {
    abi_version, struct_size, logger, plugin: PluginInfo,
    game: ?*const GameApi, files: ?*const FileApi, network: ?*const NetworkApi,
}
PluginInfo { id, name, version, author, library_path }  // Text = ptr + len
Event { struct_size, name: Text, payload: Text }        // borrowed for one call
GameApi {
    struct_size, context,
    server_info(ctx, *ServerInfo) -> status,
    player_info(ctx, index, *PlayerInfo) -> status,
    entity_info(ctx, index, *EntityInfo) -> status,
    server_cvar(ctx, name: Text, *CvarValue) -> status,
    client_cvar(ctx, index, name: Text, *CvarValue) -> status,
}
NetworkApi {
    struct_size, context,
    connect(ctx, host: Text, port: u16, protocol, *u64) -> status,
    close(ctx, handle: u64) -> status,
    read(ctx, handle: u64, ptr, len) -> isize,
    write(ctx, handle: u64, ptr, len) -> isize,
    poll(ctx, handle: u64, events: u8, timeout_ms: u32, *u8) -> status,
}
load(ctx: *PluginContext) -> int
unload(ctx: *PluginContext) -> int
onEvent(ctx: *PluginContext, event: *const Event) -> int   // optional
```

Context strings borrow the manager's validated manifest and stay valid until
after `unload()`. Plugins must check `abi_version` and `struct_size` before
reading the remaining fields. `payload` is JSON text or empty; `onEvent`
returns `0` (`PLUGIN_CONTINUE`) to keep event delivery going.

`game` is appended after `PluginInfo`: the ABI version stays `2`, and an old
plugin that only reads the fields it knows about is unaffected because
`struct_size` is the outer bound. The manager exposes `game` only when an IPC
channel to the engine process exists.

### Game-query status and truncation

Every `GameApi` function returns one of these `c_int` statuses:

| Status | Value | Meaning |
|---|---|---|
| `query_ok` | 0 | Query succeeded; output is complete. |
| `query_unavailable` | 1 | No IPC channel, engine interface, or cvar interface, or `out.struct_size` is too small. |
| `query_transport_error` | 2 | The query could not be answered (framing, JSON, or protocol failure). Output is unspecified. |
| `query_truncated` | 3 | Query succeeded but a text value exceeded its fixed buffer. |

The caller sets `out.struct_size = @sizeOf(T)` before each call. Text fields
are not zero-terminated. Each `*_len` field reports the full value length, even
when `query_truncated` means only the first `query_text_capacity` (260) bytes
were stored; a plugin can compare `len` with the array capacity to detect the
loss. `present`/`exists`/`found` distinguish an empty result from an error.

Queries are synchronous and read-only: the forked child sends a JSON-RPC
request over the existing IPC socket, the engine-process listener answers it,
and the caller blocks until the answer arrives. There is no timeout, matching
the existing synchronous event exchange; a stalled engine process stalls the
caller. Queries work during `load()` (the parent is waiting for readiness) and
during event delivery (the parent is waiting for the event response).

### Network policy, status, and handles

`network` is appended after `files` without changing `abi_version`. It exposes
outbound TCP only: TLS, HTTP, WebSocket, and inbound listeners are not part of
this ABI. The manager exposes it whenever the plugin-manager child runs; no
engine interface is involved.

The manifest `[network]` table is deny-by-default. `allow` lists `host`,
`host:port`, `[ipv6]`, or `[ipv6]:port` entries; a `*.` prefix matches the
suffix and its subdomains but not the bare suffix. `allow_private` (default
false) permits loopback, RFC 1918, link-local, ULA, multicast, and unspecified
destinations, and is checked against the resolved address. `max_connections`
(default 4), `max_frame_bytes` (default 64 KiB), `connect_timeout_ms` (default
3000), `io_timeout_ms` (default 3000), and `poll_timeout_ms` (default 10) bound
resource use; manifest values above the `max_network_*` caps are rejected.

Every `NetworkApi` function except `read`/`write` returns a `c_int` status:

| Status | Value | Meaning |
|---|---|---|
| `network_ok` | 0 | Operation succeeded. |
| `network_unavailable` | 1 | No network service for this context. |
| `network_permission_denied` | 2 | Destination not allowed, or it resolved into private space without `allow_private`. |
| `network_invalid_argument` | 3 | Malformed host, unsupported protocol, or empty event mask. |
| `network_resolution_failed` | 4 | Host name did not resolve. |
| `network_connect_failed` | 5 | The resolved address could not be connected. |
| `network_timeout` | 6 | The resolve, connect, read, write, or poll deadline elapsed. |
| `network_would_block` | 7 | Reserved for non-blocking callers; the synchronous helpers wait instead. |
| `network_closed` | 8 | The peer closed the connection. |
| `network_resource_limit` | 9 | `max_connections` reached or a descriptor could not be allocated. |
| `network_io_error` | 10 | I/O failed on an open connection. |
| `network_invalid_handle` | 11 | The handle is not open in this plugin's context. |

`read` returns the byte count, `0` at end of stream, or a negated status;
`write` returns the accepted byte count or a negated status. Both may transfer
fewer bytes than requested, so whole-message callers must loop. `poll` combines
`network_poll_in` (1) and `network_poll_out` (2) and reports
`network_poll_error` (4) and `network_poll_hup` (8); a zero result means the
timeout elapsed.

Connections are non-blocking and wait through bounded `poll` slices (10 ms)
until the policy deadline. Host-name resolution happens on the service's
dedicated resolver thread, not on the manager's event thread. Handles are
opaque, non-zero integers valid only in the owning plugin's context and only
until `close` or until the plugin's `unload()` returns. The host closes every
remaining handle after `unload()`.

---

## 3. What reaches plugins today

| Capability | Native `.so` | Lua |
|---|---|---|
| Load/unload lifecycle | yes | `on_load` / `on_unload` |
| Logging | yes | `zostd.log` |
| Pause/UnPause | yes (`onEvent`) | yes |
| LevelInit/ServerActivate/LevelShutdown | yes (`onEvent`) | yes |
| GameFrame | **no** | **no** |
| Client callbacks | **partial**: `ClientCommand` reaches Lua as `clientCommand`, with `zostd.client_print`; native plugins receive the event but have no print API | **partial** |
| Plugin id / manifest data | id, name, version, author, library path | id and root only |
| Read-only game queries | `ctx.game`: server info, player info, entity existence, server/client cvar reads | `zostd.game.*` |
| File access | `ctx.files`: `plugin://` read/write, parent-mediated read-only `game://` | `zostd.read_file` / `zostd.write_file` |
| Outbound networking | `ctx.network`: policy-checked TCP connect/close/read/write/poll | `zostd.net.*` |
| Engine commands / write access / game FS | **no native command call**; Lua uses `zostd.server_command` over `engine.serverCommand` IPC and `zostd.client_print` over `engine.clientPrint` | `server_command` and `client_print` are wired for Lua; native `GameApi` still has no command or client-print entry |
| IPC/event payloads | JSON text for `levelInit`/`serverActivate`; raw command text for `clientCommand` | same payload string |

`Manager.dispatchEvent()` delivers each engine event to Lua scripts first and
then to every initialized native plugin that exported `onEvent`, in
dependency-first load order. Native plugins without the export are skipped.
`onEvent` may stop delivery to later plugins but cannot cancel the engine
action, because these events are post-action notifications.

---

## 4. Flow problems worth fixing regardless of ABI

1. **Manifest schema mismatch.** `PluginManager.Manifest` expects `id`, `file` (`PluginManager.zig:22-28`), while `PluginConfiguration` expects `plugin_id`, `lib_path` (`PluginConfiguration.zig:29-47`). The parent calls `readConfig()` after readiness and swallows errors (`Entrypoint.zig:785`), so real manifests in the current schema silently produce no output.
2. **Manifest data is parsed but not used.** `lib_path` is never consulted; every `.so` in the directory is loaded (`PluginManager.zig:300-307`). `managed_plugins` is leaked.
3. **No manifest means no native plugin.** A `.so` without `manifest.toml` is skipped, despite `build.zig:24-26` saying a missing manifest is allowed.
4. **`game_server_factory` is ignored** (`Entrypoint.zig:702-703`). It is the normal route to server-side interfaces such as `ServerGameDLL`, `ServerGameClients`, and `ServerGameEnts`.
5. **Fork boundary blocks direct engine access.** The child inherits engine pointers, but calling them after `fork()` is unsafe (`Log.zig:13-16`). Any engine operation for plugins must be mediated by the parent over IPC, not by passing raw engine pointers into `PluginContext`.
6. **Synchronous event exchange is a scalability limit.** `sendManagerEvent()` blocks the engine callback until the child replies (`Entrypoint.zig:832-849`). A slow plugin blocks the server. This is tolerable for level events, not for `GameFrame` or client commands.
7. **IPC payloads are limited.** `Ipc.Event` now carries optional JSON text for `levelInit` and `serverActivate`, and frames are capped at 4096 bytes (`Ipc.zig:22`). Client command arguments or larger results will need a higher/chunked limit.
8. **`cachePlugin()` leaks on append failure.** If `plugins.append()` fails after `DynLib.open()`, the library is not closed (`PluginManager.zig:337-342`).

---

## 5. Do plugins need more ABI functions?

### Short answer

**Yes, but preferably not as more exported plugin functions.** Keep `load`/`unload` as the stable entry contract and grow the host-provided side of the ABI.

### Recommended ABI shape

1. **Event delivery to native plugins — implemented.**
   Plugins may export an optional
   `onEvent(ctx, event: *const Event) -> int`. The manager resolves it with
   dlsym and delivers the five implemented engine events after
   initialization. A richer callback-table registration API can replace the
   export later without changing `PluginContext`.

2. **Plugin identity and configuration — implemented.**
   ABI version 2 passes `PluginInfo` (id, name, version, author, library path)
   inside `PluginContext`. Root directories are not part of the context yet;
   the example plugin still derives them locally.

3. **Host-mediated engine operations — partially implemented.**
   Read-only game queries are available through `PluginContext.game`: server
   info, player info, entity existence, and server/client cvar reads. They run
   in the engine process and are answered over IPC; the child never
   dereferences inherited engine vtables. Operations such as `server_command`,
   cvar *writes*, and `game://` file access are still absent and would follow
   the same allowlisted parent-side path.

   Outbound TCP networking is available separately through
   `PluginContext.network`. It is deny-by-default per manifest and runs
   entirely inside the forked plugin-manager child; no engine socket is
   involved.

4. **ABI version/size negotiation — implemented.**
   `PluginContext` now starts with `abi_version` and `struct_size`. New fields
   are append-only; a plugin must reject a context whose `struct_size` is
   smaller than the version it was compiled against.

5. **Lifecycle/event coverage.**
   If plugins need Source callbacks, add them in this order:
   - `levelInit`, `serverActivate`, `levelShutdown`, `pause`, `unpause` to native plugins — implemented as post-action "On" events,
   - `gameFrame` only if genuinely needed, because synchronous per-tick IPC is expensive,
   - client callbacks (`ClientActive`, `ClientDisconnect`, `ClientPutInServer`, `ClientSettingsChanged`, `ClientConnect`, `ClientCommand`, `NetworkIDValidated`, `OnQueryCvarValueFinished`, `OnEdictAllocated/Freed`) by replacing the relevant `genericStub` slots. `ClientCommand` is now implemented for Lua (`clientCommand` event plus `zostd.client_print`); the remaining client callbacks are still stubs.

6. **Inter-plugin dependencies/services.**
   `docs/Architecture.md:19-24` plans a dependency graph, but `loadPlugins()` uses filesystem order and `unloadAll()` simply reverses discovery order. If plugin dependencies are planned, the host ABI also needs a way to resolve/request another plugin’s services and the loader needs topological ordering.

### What does *not* need to change

- The Source VSP vtable does **not** need more real slots merely to load and unload. The existing padding is safe for `ISERVERPLUGINCALLBACKS003`.
- Plugins do **not** need to export a large API surface. A single `load`/`unload` pair plus the versioned `PluginContext` contract is sufficient and preserves the current contract.

### Suggested priority

**P0:** host-mediated engine calls. Native event delivery, plugin identity/config, read-only game queries, per-plugin filesystem access, outbound networking, and ABI size/version negotiation are implemented in ABI version 2.

**P1:** real `GameFrame`/client VSP callbacks, richer IPC payloads, per-plugin permissions/allowlists, dependency ordering.

**P2:** hot reload, async event dispatch, structured error reporting, richer service discovery.

In its current state, Zorcerer has a working **loader** and **isolation boundary**, but the native plugin ABI is still a prototype: plugins can log and run local code, but cannot meaningfully participate in the server.

