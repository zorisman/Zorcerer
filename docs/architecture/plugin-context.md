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
    2. Invalid configuration: the file is not a usable dynamic library, or
       the plugin rejects the context / returns nonzero from `load()`
       (`invalid_configuration`)
    3. Invalid or missing `load`/`unload` symbols (`missing_symbol`)
    
4. Instance creation
The manager opens the library named by the manifest, builds the plugin's
`PluginContext`, and calls its `load(ctx)`. A zero return value marks the
plugin active and emits an `instance_created` manager event carrying the
plugin id, the library path, and the context that was handed to `load()`.
The same context stays valid until the plugin is unloaded.

On error: Stop loading the plugin and its transitive dependents, emit a
`library_rejected` manager event with `invalid_configuration`, close the
library, and release the context.
Scenarios:

5. Initialization - Preparing for runtime

6. Runtime
    1. Event hooking
    2. Game queries
    3. File system
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
