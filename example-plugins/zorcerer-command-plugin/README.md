# Zorcerer command plugin prototype

This plugin registers a server-console command named `zorcerer`. When run, it
uses the existing `ZorcererCommand.zig` implementation to submit
`echo "Zorcerer is on!"` to the Source server command buffer.

## Files

- `PluginAPI.zig` — small ABI contract shared by the core and plugins.
- `ZorcererCommandPlugin.zig` — plugin entry points, exported as `load` and `unload`.
- `ZorcererCommand.zig` — the provided command-registration implementation, with its
  `ConCommandObject` padding expressed in pointer-width terms so it can compile for
  either 32-bit or 64-bit builds. The target's generated vtable indices must still
  match the exact engine build.
- `zorcerer-command.toml` — manifest for the manager.

## Required manager ABI adjustment

The current manager passes only `IVEngineServer*` to `load(void*)`. That is not
sufficient for registering a Source command because the plugin also needs the
engine's `CreateInterface` factory to obtain `ICvar`. Update the manager to pass
`const PluginAPI.Context*` instead.

1. Import `PluginAPI.zig` in `PluginManager.zig`.
2. Change the callback type to:

   ```zig
   const LoadFn = *const fn (context: *const PluginAPI.Context) callconv(.c) bool;
   ```

3. Store the `interface_factory` in `Manager`, and add it to `Manager.init`.
4. In `loadOne`, create a local context and pass its pointer:

   ```zig
   const context = PluginAPI.Context{
       .abi_version = PluginAPI.abi_version,
       .struct_size = @sizeOf(PluginAPI.Context),
       .engine = self.engine,
       .interface_factory = self.interface_factory,
   };
   if (!load_fn(&context)) return error.PluginLoadRejected;
   ```

   Keep the existing error logging and cleanup around this call.
5. When constructing the manager from the VSP entry point, pass the same
   `interface_factory` supplied to the VSP's `Load()` callback.

The `ZorcererCommandPlugin.zig` and `PluginManager.zig` callback signatures must
match; do not keep the old `load(engine)` function-pointer type.

## Avoid duplicate command registration

The supplied `Entrypoint.zig` currently calls `ZorcererCommand.install()` and
`ZorcererCommand.uninstall()` directly. Remove those calls when testing this
plugin through `PluginManager`, otherwise the core and plugin may both try to
register the command named `zorcerer`.

## Build integration

Build `ZorcererCommandPlugin.zig` as a shared library named `zorcerer_command.so`.
Configure the same project imports used by the existing command code (`hooks`
and `codegen_generated/engine_indexes.zig`). Put `zorcerer_command.so` and
`zorcerer-command.toml` in the same plugin directory, then call
`loadDirectoryWithManifests()` on that directory.

The helper's object padding is pointer-width-aware here because the supplied
`Entrypoint.zig` mentions 32-bit Linux while the original command helper asserted
64-bit only. This removes that compile-time contradiction, but it does not prove
that the generated method indices or vtable slots are correct for a particular
TF2 binary. Test on a local server first.
