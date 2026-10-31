//! ABI contract between the Zorcerer plugin manager (src/core/PluginManager.zig)
//! and every native plugin it loads.
//!
//! The file is shared by both sides of the dlopen() boundary: the manager
//! imports it as the `plugin-context` build module and plugin modules import
//! the same module, so these declarations stay identical everywhere.
//!
//! Every plugin exports the two symbols shown below with C linkage
//! (Zig: `export fn`, with `callconv(.c)`):
//!
//!     load(ctx: *PluginContext) callconv(.c) c_int
//!     unload(ctx: *PluginContext) callconv(.c) c_int
//!
//! - The plugin manager looks both symbols up with dlsym() and calls them
//!   through the matching function pointers; a plugin missing one of them
//!   is skipped.
//! - A plugin must check `ctx.abi_version` and `ctx.struct_size` before
//!   reading any other field. The host sets both to the contract it was
//!   compiled with; a plugin compiled against a newer contract must refuse
//!   the context instead of reading fields the host did not provide.
//! - Both functions return 0 on success. Any nonzero return value marks
//!   load() as failed; the manager then never calls that plugin's unload().
//! - `PluginContext.logger` is how a plugin prints into the server console;
//!   it is null when the host could not provide a way in.
//!
//! Ownership and lifetimes:
//! - Every `Text` in the context borrows memory owned by the plugin manager.
//!   The slices stay valid from load() until after unload() and must not be
//!   freed or modified by the plugin.
//! - The context itself, its logger pointer and all identity fields remain
//!   valid until after the plugin's unload() returns.
//! - The manager hands the same context to load() and unload().

/// Version of this contract. The host writes it into every PluginContext;
/// a plugin compiled against a different version must return nonzero from
/// load() before using the remaining fields.
pub const abi_version: c_int = 2;

/// A borrowed, non-zero-terminated string in the plugin ABI.
///
/// Invariants: `ptr` points to at least `len` readable bytes. A zero-length
/// text may carry any pointer value but must not be dereferenced.
///
/// Ownership: plugin contexts only carry texts owned by the host. Plugins
/// must not free them and must not retain them after unload() returns.
pub const Text = extern struct {
    /// First byte of the borrowed string.
    ptr: [*]const u8,
    /// Number of borrowed bytes at `ptr`.
    len: usize,

    /// Builds a borrowed text that aliases `slice`.
    ///
    /// The caller must keep `slice` alive and unchanged for as long as the
    /// returned text may be observed. No allocation or copy is performed.
    pub fn fromSlice(bytes: []const u8) Text {
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }

    /// Returns the bytes referenced by this text.
    ///
    /// The returned slice aliases host-owned memory and is only valid while
    /// the containing PluginContext is valid. No allocation is performed.
    pub fn slice(self: Text) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// A function that prints one message into the game server console.
/// `message` is zero-terminated (engine LogPrint ABI); the logger lives until
/// at least after unload() of the plugins it was handed to.
pub const Logger = extern struct {
    /// Opaque context `print` requires; implementation-defined by the
    /// host (the engine's IVEngineServer pointer for Zorcerer).
    context: *anyopaque,
    print: PrintFn,

    pub const PrintFn = *const fn (context: *anyopaque, message: [*:0]const u8) callconv(.c) void;
};

/// Identity and manifest data of the plugin receiving a PluginContext.
///
/// Every field is a borrowed view of the validated manifest the manager
/// loaded for this plugin. See Text's lifetime rules.
pub const PluginInfo = extern struct {
    /// Plugin id, which is also the plugin's directory name.
    id: Text,
    /// Human-readable display name from the manifest.
    name: Text,
    /// Semantic version string from the manifest.
    version: Text,
    /// Author string from the manifest.
    author: Text,
    /// Library path from the manifest, relative to the plugin directory.
    library_path: Text,
};

/// Context passed to a plugin's load()/unload().
///
/// Layout: `abi_version` and `struct_size` are the first two fields so a
/// plugin can validate the context before touching anything else. New
/// fields may only be appended; plugins must use `struct_size` to decide
/// which trailing fields are safe to read.
pub const PluginContext = extern struct {
    /// ABI version of this context; see `abi_version`.
    abi_version: c_int,
    /// Size of this context in bytes as provided by the host. A plugin
    /// compiled against a newer contract must treat a smaller value as an
    /// incompatible host.
    struct_size: usize,
    /// Server console sink, or null when the host has none.
    logger: ?*const Logger,
    /// Identity and manifest data of the plugin receiving this context.
    plugin: PluginInfo,
};

/// Plugin's `load` export.
pub const LoadFn = *const fn (ctx: *PluginContext) callconv(.c) c_int;

/// Plugin's `unload` export; called only when load() returned 0.
pub const UnloadFn = *const fn (ctx: *PluginContext) callconv(.c) c_int;

/// Optional plugin `onEvent` export. The manager currently does not look it
/// up; a plugin that omits it still loads normally.
pub const OnEventFn = *const fn (ctx: *PluginContext) callconv(.c) c_int;
