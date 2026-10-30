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
Awaiting for dependencies, if the plugin has any. Event "Awaiting dependencies"

On error: Stop loading. Send to the Plugin Manager error of corresponding scenario.
Scenarios:
1. Dependencies not found

3. Dynlib loading
On error: Stop loading. Send to the Plugin Manager error of corresponding scenario. 
Scenarios:
    1. Invalid configuration or symbols
    2. Dynalic library not found
    
4. Instance creation
Sending to the Plugin Manager successful instance creation event
On error: Stop loading. Send to the Plugin Manager error of corresponding scenario.
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
