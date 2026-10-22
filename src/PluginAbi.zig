//! ABI contract between the Zorcerer plugin manager (src/PluginManager.zig)
//! and every plugin it loads.
//!
//! The file is shared by both sides of the dlopen() boundary: the manager
//! imports it through the `plugin-abi` build module and plugin modules use
//! the same import, so these declarations stay identical everywhere.
//!
//! Every plugin exports the two symbols shown below with C linkage
//! (Zig: `export fn`, with `callconv(.c)`):
//!
//!     load(host: *const HostApi) callconv(.c) c_int
//!     unload(host: *const HostApi) callconv(.c) c_int
//!
//! - The plugin manager looks both symbols up with dlsym() and calls them
//!   through the matching function pointers; a plugin missing one of them
//!   is skipped.
//! - Both functions return 0 on success. Any nonzero return value marks
//!   load() as failed; the manager then never calls that plugin's unload().
//! - `HostApi.logger` is how a plugin prints into the server console; it
//!   is null when the host could not provide a way in.

/// Version of this contract, embedded in every HostApi handed out. A
/// plugin compiled against a different version should refuse to bind by
/// returning nonzero from load() before using `host`.
pub const abi_version: c_int = 1;

/// A function that prints one message into the game server console.
/// `message` is zero-terminated (engine LogPrint ABI); the context lives
/// until at least after unload() of the plugins it was handed to.
pub const Logger = extern struct {
    /// Opaque context `print` requires; implementation-defined by the
    /// host (the engine's IVEngineServer pointer for Zorcerer).
    context: *anyopaque,
    print: PrintFn,

    pub const PrintFn = *const fn (context: *anyopaque, message: [*:0]const u8) callconv(.c) void;
};

/// Host API passed to a plugin's load()/unload().
pub const HostApi = extern struct {
    abi_version: c_int = abi_version,
    /// Null when the host could not provide a server console logger.
    logger: ?*const Logger = null,
};

/// Plugin's `load` export.
pub const LoadFn = *const fn (host: *const HostApi) callconv(.c) c_int;

/// Plugin's `unload` export; called only when load() returned 0.
pub const UnloadFn = *const fn (host: *const HostApi) callconv(.c) c_int;
