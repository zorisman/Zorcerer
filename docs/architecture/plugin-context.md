# Plugin lifecycle

## Initialization

1. Manifest validation
The plugin manager, after reading a valid manifest.toml, creates an instance of a plugin, passing *PluginContext as a parameter.

On error: Do not load the plugin. Print the error of corresponding scneario.
Scenarios:
1. .toml has invalid values
2. .toml has not necessary keys
3. .toml not found

2. Dependency resolution
Native plugins may declare an optional `[dependencies]` table in
`manifest.toml`. Keys are plugin ids and values are semantic-version
requirements (`*`, exact `1.2.3`, `^1.2.3`, `~1.2.3`, and `>`, `>=`, `<`,
`<=` comparators). The manager validates the graph, emits an "Awaiting
dependencies" event to its in-process listener, and loads plugins in
dependency-first order. Plugins whose dependencies are missing, version-
mismatched, cyclic, or failed to load are skipped together with their
transitive dependents; unrelated plugins continue loading.

On error: Stop loading the affected plugin subtree. Send to the Plugin Manager error of corresponding scenario.
Scenarios:
1. Dependencies not found
2. Dependency version mismatch
3. Dependency cycle
4. Dependency failed to load

3. Dynlib loading
The manager opens only the library named by the manifest's `path`; other
`.so` files in the plugin directory are ignored. It resolves the exported
`load` and `unload` symbols and builds one `PluginContext` per plugin.

`PluginContext` is ABI version 2. Its first fields are `abi_version` and
`struct_size`; a plugin must validate both before reading the rest. The
context carries an optional `logger` and an embedded `PluginInfo` (`id`,
`name`, `version`, `author`, `library_path`). Every string is a `Text`
(pointer + length) borrowed from the manager's validated manifest, so it
stays valid until after `unload()` and must not be freed by the plugin.

On error: Stop loading the plugin and its transitive dependents, emit a
`library_rejected` manager event with the structured reason, and continue
with unrelated plugins.
Scenarios:
    1. Dynamic library not found (`library_not_found`)
    2. Invalid configuration: the file is not a usable dynamic library
       (`invalid_configuration`)
    3. Invalid or missing `load`/`unload` symbols (`missing_symbol`)
    
4. Instance creation
The manager opens the library named by the manifest, resolves its
`load`/`unload` exports, builds the plugin's `PluginContext`, and caches the
instance. It then emits an `instance_created` manager event carrying the
plugin id, the library path, and the context that initialization will hand to
`load()`. The plugin starts in the `created` state; `load()` is not called
yet, and the context stays valid until the plugin is unloaded.

On error: Stop creating the plugin and its transitive dependents, emit a
`library_rejected` manager event with the structured reason, and leave no
library or context allocated.
Scenarios:

5. Initialization - Preparing for runtime
The manager calls each created plugin's `load(ctx)` in dependency-first order.
It emits `initialization_started` before the call and
`initialization_finished` after a zero return, then marks the plugin
`initialized`. A nonzero return emits `library_rejected` with
`invalid_configuration`, marks the plugin `failed`, and skips its transitive
dependents with `dependency_rejected`. Failed instances stay cached so
`unloadAll()` can close the library and release the context, but their
`unload()` hook is not called.

After the initialization pass completes, the manager emits `runtime_entered`
and dispatches `on_runtime_entered` to loaded Lua scripts.
Scenarios:
1. `load()` returns nonzero (`invalid_configuration`)
2. A dependency failed to initialize (`dependency_rejected`)

6. Runtime
    1. Event hooking
    Native plugins that export `onEvent(ctx, event)` receive every runtime
    event after initialization. The manager looks the export up while opening
    the library; a plugin without it loads normally and receives no events.
    Only "On" hooks exist for now: the five VSP callbacks `pause`, `unpause`,
    `levelInit`, `serverActivate`, and `levelShutdown` are forwarded over IPC
    after the engine action, so a return value cannot cancel it.

    `event.name` is the same spelling Lua scripts receive. `event.payload` is
    JSON text or empty: `{"map":"<name>"}` for `levelInit` and
    `{"edict_count":N,"client_max":N}` for `serverActivate`; the remaining
    events carry no payload. The `Event` struct, its name, and its payload are
    borrowed and only valid during the call.

    Delivery runs after the Lua fan-out, in dependency-first load order, and
    only reaches plugins in the `initialized` state. `plugin_continue` (0)
    delivers the event to the next plugin; any other value stops delivery to
    later plugins, matching Source's `PLUGIN_STOP` convention within the
    plugin fan-out.
    2. Game queries
    The context carries an optional `game` capability (`abi.GameApi`). It is
    read-only and synchronous: a query travels from the forked plugin manager
    to the engine process over the same IPC socket the manager already uses for
    events, and the caller blocks until the typed answer arrives. The child
    never dereferences an engine pointer, and queries have no timeout; a
    stalled engine process stalls the caller, matching the existing synchronous
    event exchange.

    `server_info` returns the dedicated flag, pause state, entity count, server
    version, uptime, game directory, and the map name cached from `levelInit`
    (empty outside a level). `player_info` returns engine identity for one
    entity index, `entity_info` reports whether an index is in use, and
    `server_cvar` / `client_cvar` read one cvar value. The cvar interfaces are
    resolved once in `load()` (`VEngineCvar004`); player and server queries use
    the already-verified `IVEngineServer` build.

    Every function writes into caller-owned fixed-size structs. The caller sets
    `struct_size` first; lengths in the results report the full value length so
    a plugin can detect truncation. Status values are `query_ok`,
    `query_unavailable` (no channel or interface), `query_transport_error`
    (the engine answer failed), and `query_truncated` (data was stored but did
    not fit). Lua scripts use the same implementation through
    `zostd.game.server_info()`, `player_info()`, `entity_exists()`,
    `server_cvar()`, and `client_cvar()`.

    Queries are available while a plugin's `load()` runs, because the parent is
    already waiting for the child's readiness, and during event delivery,
    because the parent is waiting for the event response. The map name is
    cleared on `levelShutdown`; the other values reflect live engine state.
    3. File system
    The context carries an optional `files` capability (`abi.FileApi`). Like
    `game`, the field was appended to `PluginContext` without changing
    `abi_version`; old plugins ignore it through `struct_size`.

    Two URI schemes are accepted:

    - `plugin://<tail>` addresses the calling plugin's own directory under the
      configured plugin root and is read/write. The plugin-manager child opens
      these paths directly through the host OS filesystem.
    - `game://<tail>` addresses the running game's mod directory and is
      read-only. The child forwards these requests to the engine process over
      the existing IPC socket; the parent translates `<tail>` into an engine
      name under pathID `GAME` and calls `IFileSystem`/`IBaseFileSystem`. The
      forked child never receives or dereferences an engine filesystem pointer.
      Writes and removals against `game://` return `file_permission_denied`
      before any engine call.

    `tail` is validated before use: `..` components, backslashes, and embedded
    NULs are refused with `file_permission_denied`, and a plugin id that could
    escape the plugin root is rejected when its filesystem context is created.

    Every operation is synchronous. `open`, `close`, `seek`, `tell`, `size`,
    `flush`, `remove`, `find_open`, `find_next`, and `find_close` return a
    `file_*` status. `read` and `write` return the number of bytes transferred,
    or a negated `file_*` status; `read` may return fewer bytes than requested,
    including 0 at end of file, so whole-file callers must loop.

    Handles are opaque, non-zero integers valid only in the plugin context that
    opened them and only until `close`/`find_close`, or until the plugin's
    `unload()` returns. File handles and directory enumerations share one
    table per plugin, so a handle from another plugin is rejected as
    `file_invalid_handle`. The host closes any handle a plugin leaves open
    after `unload()`, while the IPC channel is still open.

    Directory enumeration uses `find_open` to start a session, `find_next` to
    copy one entry name (and receive its directory flag), and `find_close` to
    end it. `find_next` returns `file_end` when the enumeration is exhausted
    and `file_name_too_long` when the caller's buffer is too small, reporting
    the required length when the backend can determine it.

    File access is available during a plugin's `load()`, because the parent is
    already waiting for the child's readiness, and during `unload()`, because
    `Entrypoint.unload()` now sends an explicit `shutdown` request and the
    parent keeps answering filesystem requests until the child acknowledges it
    and exits. Lua scripts use the same service through
    `zostd.read_file(path)` and `zostd.write_file(path, data)`; a path without
    a URI prefix is relative to the script's plugin directory.
    4. Networking
    5. Resource management
    6. Plugin-to-plugin communication
    7. Hot reload

7. Deinitialization
   NOTE: Deinitialization is restricted (configurable: deny, cascade, notify), if the plugin has dependent plugins.
    1. Block the event querying
    2. Cleanup
    3. Deinitializing
    4. Unload dynlib
    5. Unloaded event

## Event types for plugin lifecycle
All the types have "Pre" (before), "On" (during) and "After" (after) hooks
1. Initialization
2. Load
3. Deinitialization

Other events:
1. OnRuntimeEntered
2. OnRuntimeExited

## RPC failures
1. Timeout
2. Cancelled
3. Invalid method
4. Permission denied
5. Resource limit exceeded
6. Incompatible RPC version
7. Invalid parameters
8. Internal error
9. Service unavailable
10. Request queue full

## Notes
1. Plugins do not change their lifecycle state. They return the result of changing its state.
