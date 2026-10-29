//! Minimal LuaJIT runtime used by ZLua.
//!
//! A `Runtime` owns exactly one Lua state and one host binding. The state is
//! independent of every other runtime, is not thread-safe, and must be closed
//! with `deinit()` on the same thread that created it. The runtime provides the
//! safe library subset needed by scripts, installs the `zostd` bindings, and
//! dispatches registered lifecycle callbacks.
//!
//! This is not a complete plugin loader: manifests, per-plugin state tables,
//! and engine IPC are owned by the plugin manager. The manager creates one
//! `Runtime` per Lua script and calls `dispatchEvent()` for the events it
//! receives.

const std = @import("std");
const luajit = @import("luajit");
const Lua = luajit.Lua;
const zostd = @import("zostd.zig");

/// One owned LuaJIT interpreter state and its `zostd` host binding.
pub const Runtime = struct {
    /// The Lua state owned by this runtime. Valid until `deinit()` returns.
    lua: *Lua,

    /// Allocator used for the runtime's stable host binding. Kept separately
    /// from `lua` because the binding must outlive every Lua operation.
    allocator: std.mem.Allocator,

    /// Stable heap-allocated binding captured by the `zostd` C closures.
    binding: *zostd.Binding,

    /// Creates a new Lua state using `allocator`.
    ///
    /// The allocator value is copied by `zig-luajit` and by the binding; the
    /// allocator's backing context must remain valid for the lifetime of the
    /// returned runtime.
    ///
    /// Errors: `error.OutOfMemory` when Lua or the binding cannot allocate
    /// their initial state.
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Runtime {
        const binding = try allocator.create(zostd.Binding);
        errdefer allocator.destroy(binding);
        binding.* = .{ .allocator = allocator };

        const lua = try Lua.init(allocator);
        errdefer lua.deinit();

        return .{
            .lua = lua,
            .allocator = allocator,
            .binding = binding,
        };
    }

    /// Closes the Lua state and releases every value and allocation owned by
    /// it, including the host binding. No Lua operation may use this runtime
    /// after `deinit()` returns.
    pub fn deinit(self: *Runtime) void {
        self.lua.deinit();
        self.allocator.destroy(self.binding);
    }

    /// Replaces the host callbacks used by the `zostd` functions.
    ///
    /// Call this before `installZostd()` for the first time, or any time later
    /// to swap the host. The `Host.context` remains caller-owned.
    pub fn setHost(self: *Runtime, host: zostd.Host) void {
        self.binding.host = host;
    }

    /// Sets the plugin id returned by `zostd.plugin_id()` when the host does
    /// not provide a `plugin_id` callback. The slice is borrowed and must stay
    /// valid for the lifetime of the runtime.
    pub fn setPluginId(self: *Runtime, plugin_id: []const u8) void {
        self.binding.plugin_id = plugin_id;
    }

    /// Sets the root directory used by the built-in `plugin://` file backend.
    /// The slice is borrowed and must stay valid for the lifetime of the
    /// runtime.
    pub fn setPluginRoot(self: *Runtime, plugin_root: []const u8) void {
        self.binding.plugin_root = plugin_root;
    }

    /// Opens the library subset allowed for scripts:
    /// base, string, table, math, and LuaJIT's bit library.
    ///
    /// The base library also installs file and loader helpers, so this
    /// function removes `dofile`, `loadfile`, `loadstring`, and `load` from
    /// the globals afterwards. `io`, `os`, `package`, `debug`, `jit`, and
    /// `ffi` are never opened.
    pub fn openSafeLibs(self: *Runtime) void {
        self.lua.openBaseLib();
        self.lua.openStringLib();
        self.lua.openTableLib();
        self.lua.openMathLib();
        self.lua.openBitLib();

        removeGlobal(self.lua, "dofile");
        removeGlobal(self.lua, "loadfile");
        removeGlobal(self.lua, "loadstring");
        removeGlobal(self.lua, "load");
    }

    /// Installs the Lua-facing `zostd` table (see `zostd.zig`).
    pub fn installZostd(self: *Runtime) void {
        zostd.install(self.lua, self.binding);
    }

    /// Loads and executes one Lua chunk from `source`.
    ///
    /// `chunk_name` identifies the chunk in Lua error messages, for example
    /// `"@plugin.lua"` or `"@zlua/test.lua"`. The source is consumed during
    /// the call and does not need to remain valid afterwards.
    ///
    /// Errors: `error.InvalidSyntax`, `error.Runtime`, or `error.OutOfMemory`.
    /// On failure Lua leaves its error message on top of the stack; callers
    /// that continue using the state should inspect and pop it.
    pub fn run(
        self: *Runtime,
        source: []const u8,
        chunk_name: [:0]const u8,
    ) (Lua.LoadError || Lua.ProtectedCallError)!void {
        try self.lua.loadBuffer(source, chunk_name);
        try self.lua.callProtected(0, 0, 0);
    }

    /// Calls the callbacks registered for `event` through `zostd.on`.
    ///
    /// `payload` is optional and is passed to the callback as its second
    /// argument (nil when absent). Callback failures are logged through the
    /// host and isolated from later callbacks. The Lua stack is restored to
    /// its entry height even when a callback fails.
    pub fn dispatchEvent(
        self: *Runtime,
        event: []const u8,
        payload: ?[]const u8,
    ) void {
        zostd.dispatch(self.lua, self.binding, event, payload);
    }
};

/// Removes one global binding from the Lua state.
fn removeGlobal(lua: *Lua, name: [:0]const u8) void {
    lua.pushNil();
    lua.setGlobal(name);
}
