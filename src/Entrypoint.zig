//! Foundation for loading our plugin loader into a TF2 dedicated server as
//! a Valve Server Plugin (VSP) - the same, Valve-documented mechanism
//! Metamod:Source itself uses to get loaded, rather than substituting or
//! LD_PRELOAD-wrapping server.so/engine.so.
//!
//! Engine-side indices and version strings come from exactly one place:
//! codegen_generated/engine_indexes.zig. Its producer,
//! build/EngineIndexesGenerator.zig, runs during the build: the analyzer
//! adapter feeds it the C++ analyzer's stdout, and it writes the generated
//! file directly. Nothing in this file hand-maintains an index or a
//! version string of its own.
//!
//! Engine version handling in `load` no longer needs the removed
//! src/analyzers/EngineVersions.zig: the engine server interface is
//! probed directly against the version strings the codegen module knows
//! (see engine_interface_versions), and the version check in load()
//! refuses every build whose answered string does not equal the one the
//! codegen indices were generated for. That leaves the version probe
//! reduced to "which string answered" - the part the removed module used
//! to own.
//!
//! The plugin manager itself runs in a forked child process. `load` forks it
//! through `forkChild`, the child loads the plugins (`pluginManagerChild`) and
//! reports over a socket pair, and this process consumes that report through
//! `jsonListener`. The child then serves VSP callback events through the
//! manager's own listener (`PluginManager.listenForEvents`).
//!
//! Messages are framed JSON-RPC 2.0 messages (see src/Ipc.zig). The manager's
//! readiness report is a `ready` notification whose `params.message` is the
//! child's readiness text. The callbacks send a request named after the event
//! and receive a JSON-RPC result `"Event is X"` (or an error response).
//! `unload` closes the parent's socket end, which tells the child to unload
//! its plugins and exit, then reaps it.
//!
//! *** VERIFY BEFORE USE ***
//! The IServerPluginCallbacks method list below follows the Valve
//! Developer Wiki (https://developer.valvesoftware.com/wiki/IServerPluginCallbacks)
//! and the historical public/engine/iserverplugin.h header. The first
//! nine methods (Load through LevelShutdown) have been stable across
//! every version of this interface I could find and are implemented for
//! real. Everything after that - the client/command callbacks added in
//! later interface versions (ClientConnect, ClientCommand,
//! NetworkIDValidated, OnQueryCvarValueFinished, OnEdictAllocated/Freed,
//! ...) - is backed by `genericStub`, a placeholder that safely ignores
//! whatever arguments it's called with and returns 0 (== false ==
//! PLUGIN_CONTINUE == null, a safe default for all of them).
//!
//! This padding exists so that if your exact TF2 build's interface has a
//! few more trailing methods than the nine implemented here, the engine
//! calling into one of them lands on a harmless no-op instead of jumping
//! into unmapped memory. It is NOT a substitute for implementing the
//! callbacks you actually want to act on - look up their real position
//! in your hl2sdk-tf2 checkout (public/engine/iserverplugin.h) and
//! replace the matching stub slot. `stub_count` is a guess at "more than
//! enough"; too large is harmless (an unindexed stub is simply never
//! called), but too *small* for your build's real interface means a call
//! past the end of the array - a crash. When in doubt, raise it.
//!
//! `plugin_interface_versions` - the versions of *our own*
//! IServerPluginCallbacks *we* claim to implement - is a separate concern
//! from engine-side detection: a wrong entry there just means
//! CreateInterface returns null for it and the engine tries the next one
//! (or logs an error and moves on) - it can't crash anything the way a
//! wrong engine-side vtable index can, so it doesn't need the same
//! verified-match treatment, even though it now comes from the codegen
//! too (consistency, not safety).
//!
//! Build with `zig build`: the result is zig-out/lib/zorcerer.so, built
//! for the x86_64-linux-gnu target configured in build.zig. Drop the .so
//! at `<mod>/addons/<name>.so` alongside a matching .vdf, e.g.
//! `tf/addons/zorcerer.so` + `tf/addons/zorcerer.vdf`. For fast iteration
//! without restarting the server, the engine also supports
//! loading/unloading a VSP interactively from the server console:
//! `plugin_load addons/zorcerer` / `plugin_unload <index>` (index shown
//! by `plugin_print`) - no .vdf needed while testing. Note `plugin_load`
//! only works before a map is running (see the console-command discussion
//! earlier) - the .vdf route is what actually loads this on a live server.

const std = @import("std");
const zjr = @import("zjr");
const Ipc = @import("Ipc.zig");
const VTableHooks = @import("hooks").VTableHook;
const Indexes = @import("codegen_generated/engine_indexes.zig");
const Manager = @import("PluginManager.zig");
const Log = @import("root.zig").Log;
const abi = @import("root.zig").abi;

// Include Ipc.zig's and PluginManager.zig's in-process tests in this module's
// test build.
test {
    _ = @import("Ipc.zig");
    _ = @import("PluginManager.zig");
}

pub const CreateInterfaceFn = *const fn (name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque;

const iface_ok: c_int = 0;
const iface_failed: c_int = 1;

/// Version strings this plugin answers to, newest first. All of them get
/// the same vtable - the padding described above is what makes that safe.
const plugin_interface_versions = [_][]const u8{
    Indexes.interfaceversion_iserverplugincallbacks,
    Indexes.interfaceversion_iserverplugincallbacks_version_2,
    Indexes.interfaceversion_iserverplugincallbacks_version_1,
};

const Slot = ?*const anyopaque;

/// IVEngineServer interface version strings the engine module might
/// answer with, newest first. Both these strings and the LogPrint slot
/// index that logPrintOf() consumes come from the same codegen module,
/// so engine probing and index use agree on which engine build the slot
/// layout was recorded for. Order: the current build answers with the
/// exact string the codegen generated for, while older recognized builds
/// surface only through the fallback constants.
const engine_interface_versions = [_][]const u8{
    Indexes.interfaceversion_vengineserver,
    Indexes.interfaceversion_vengineserver_version_22,
    Indexes.interfaceversion_vengineserver_version_21,
};

/// An IServerPluginCallbacks instance is just a vptr as far as the engine
/// is concerned - no RTTI header to worry about, since nothing does
/// dynamic_cast/typeid on a plugin interface the engine loaded generically.
const PluginObject = extern struct {
    vptr: [*]const Slot,
};

var plugin_instance = PluginObject{ .vptr = &vtable };
var engine: ?*anyopaque = null;

/// Command line the test ServerCommand scenario listens for.
const test_ping_command = Manager.test_ping_command;

/// Command name the engine actually parses out of `test_ping_command`.
///
/// Source console command names cannot contain whitespace, so `zorcerer ping`
/// is the command `zorcerer` with the argument `ping`. The command object
/// registered with `ICvar` therefore carries this name, and the dispatch
/// callback checks the argument itself.
const test_command_name = Manager.test_command_name;

/// Argument that selects the ping scenario on `test_command_name`.
const test_ping_argument = Manager.test_ping_argument;

/// The `CCommand` object the engine passes to `ConCommand::Dispatch`.
///
/// The layout is copied from `CCommand` in the Source SDK's
/// `public/tier1/convar.h` for the Itanium C++ ABI used by the Linux
/// dedicated server. Dispatch only reads `argc` and the first entries of
/// `argv`; the token buffers are part of the struct because they determine
/// the offsets of those fields.
const CCommand = extern struct {
    /// Number of tokens in the command line, including the command name.
    argc: c_int,
    /// Byte offset of the argument string inside `arg_s_buffer`.
    argv0_size: c_int,
    /// The full command line with the command name at the front.
    arg_s_buffer: [512]u8,
    /// NUL-terminated copies of every argument.
    argv_buffer: [512]u8,
    /// Pointers to `argc` tokens, each pointing into `argv_buffer`.
    argv: [64]?[*:0]const u8,
};

/// Returns token `index` of `command`, or null when it is absent.
///
/// The returned slice borrows the engine-owned command storage and remains
/// valid only for the duration of the `Dispatch` call.
fn commandArgument(command: *const CCommand, index: usize) ?[]const u8 {
    if (command.argc <= 0) return null;
    const argc: usize = @intCast(command.argc);
    if (index >= argc) return null;
    const token = command.argv[index] orelse return null;
    return std.mem.span(token);
}

/// Returns whether the engine dispatched the registered `zorcerer ping`
/// command line.
///
/// The engine looks a console command up by its first token alone, so the
/// `ping` argument has to be checked here to keep other invocations of
/// `zorcerer` from starting the test exchange.
fn isTestPingInvocation(command: *const CCommand) bool {
    if (command.argc != 2) return false;
    const name = commandArgument(command, 0) orelse return false;
    const argument = commandArgument(command, 1) orelse return false;
    return std.mem.eql(u8, name, test_command_name) and
        std.mem.eql(u8, argument, test_ping_argument);
}

/// In-process `ConCommand` registered with the engine at load time.
///
/// The field order and sizes follow `ConCommandBase` followed by `ConCommand`
/// in the Source SDK's `public/tier1/convar.h`, for the Itanium C++ ABI used
/// by the Linux dedicated server. The vtable pointer must stay first, and the
/// members up to `flags` must keep their offsets: the engine links this
/// object into its own command list and reads those members directly.
///
/// The callback words and the bitfield byte are present only to match the
/// C++ object size. This implementation overrides `Dispatch` directly, so
/// `ConCommand`'s own callback dispatch is never used.
const ConCommandObject = extern struct {
    /// Itanium ABI vptr pointing at `concommand_vtable`.
    vptr: [*]const Slot,
    /// Engine-owned link to the next registered command (`m_pNext`).
    next: ?*anyopaque,
    /// Whether the engine has registered this command (`m_bRegistered`).
    registered: u8,
    /// NUL-terminated command name (`m_pszName`).
    name: ?[*:0]const u8,
    /// NUL-terminated help text (`m_pszHelpString`).
    help: ?[*:0]const u8,
    /// `FCVAR_*` flags (`m_nFlags`).
    flags: c_int,
    /// `ConCommand`'s callback union. Null: this object's Dispatch runs.
    command_callback: ?*const anyopaque,
    /// `ConCommand`'s completion callback union. Null: no completion.
    completion_callback: ?*const anyopaque,
    /// `ConCommand`'s three callback-kind bitfields.
    callback_flags: u8,
};

/// Complete/deleting destructor entry of `ConCommandObject`.
///
/// The command has static storage duration and must never be freed by the
/// engine, so both destructor vtable slots are no-ops.
fn conCommandDestroy(_: *ConCommandObject) callconv(.c) void {}

/// Reports that the registered object is a console command, not a ConVar.
fn conCommandIsCommand(_: *const ConCommandObject) callconv(.c) bool {
    return true;
}

/// Tests one `FCVAR_*` flag against the command's flags.
fn conCommandIsFlagSet(self: *const ConCommandObject, flag: c_int) callconv(.c) bool {
    return (self.flags & flag) != 0;
}

/// Adds `flags` to the command's `FCVAR_*` flags.
fn conCommandAddFlags(self: *ConCommandObject, flags: c_int) callconv(.c) void {
    self.flags |= flags;
}

/// Returns the command name the engine looks up.
fn conCommandGetName(self: *const ConCommandObject) callconv(.c) [*:0]const u8 {
    return self.name orelse @as([*:0]const u8, "");
}

/// Returns the command's help text.
fn conCommandGetHelpText(self: *const ConCommandObject) callconv(.c) [*:0]const u8 {
    return self.help orelse @as([*:0]const u8, "");
}

/// Returns whether the engine currently holds this command.
fn conCommandIsRegistered(self: *const ConCommandObject) callconv(.c) bool {
    return self.registered != 0;
}

/// Returns the DLL identifier allocated for this command.
fn conCommandGetDllIdentifier(_: *const ConCommandObject) callconv(.c) c_int {
    return test_ping_dll_id;
}

/// Initializes the `ConCommandBase` fields from explicit values.
///
/// The static object is already initialized before registration, so the
/// engine does not normally call this. It is implemented for ABI completeness.
fn conCommandCreateBase(
    self: *ConCommandObject,
    name: [*:0]const u8,
    help: ?[*:0]const u8,
    flags: c_int,
) callconv(.c) void {
    self.name = name;
    self.help = help orelse @as([*:0]const u8, "");
    self.flags = flags;
}

/// Registration hook of `ConCommandBase`.
///
/// Registration is performed directly through `ICvar::RegisterConCommand`, so
/// calling the accessor again here would recurse into the engine.
fn conCommandInit(_: *ConCommandObject) callconv(.c) void {}

/// Reports no completion suggestions.
fn conCommandAutoCompleteSuggest(
    _: *ConCommandObject,
    _: [*:0]const u8,
    _: *anyopaque,
) callconv(.c) c_int {
    return 0;
}

/// Reports that this command has no completion callback.
fn conCommandCanAutoComplete(_: *ConCommandObject) callconv(.c) bool {
    return false;
}

/// Runs the test ping exchange when the engine dispatches `zorcerer ping`.
///
/// Other arguments print a usage line instead of starting an exchange, so the
/// registered command cannot be used to issue arbitrary manager requests.
fn conCommandDispatch(_: *ConCommandObject, command: *const CCommand) callconv(.c) void {
    if (!isTestPingInvocation(command)) {
        std.debug.print("[zorcerer] usage: {s}\n", .{test_ping_command});
        return;
    }

    const server = engine orelse {
        std.debug.print(
            "[zorcerer] {s}: engine interface is unavailable\n",
            .{test_ping_command},
        );
        return;
    };
    runTestPingExchange(server);
}

/// Virtual method table for `test_ping_concommand`.
///
/// Entries are placed by the indices the code generator recorded for
/// `ConCommand`, so the ordering cannot drift from the analyzed engine ABI.
const concommand_vtable: [Indexes.ConCommand.dispatch + 1]Slot = blk: {
    var slots = [_]Slot{null} ** (Indexes.ConCommand.dispatch + 1);
    slots[Indexes.ConCommand.@"~ConCommand"] = @ptrCast(&conCommandDestroy);
    slots[Indexes.ConCommand.@"~ConCommand@1"] = @ptrCast(&conCommandDestroy);
    slots[Indexes.ConCommand.is_command] = @ptrCast(&conCommandIsCommand);
    slots[Indexes.ConCommand.is_flag_set] = @ptrCast(&conCommandIsFlagSet);
    slots[Indexes.ConCommand.add_flags] = @ptrCast(&conCommandAddFlags);
    slots[Indexes.ConCommand.get_name] = @ptrCast(&conCommandGetName);
    slots[Indexes.ConCommand.get_help_text] = @ptrCast(&conCommandGetHelpText);
    slots[Indexes.ConCommand.is_registered] = @ptrCast(&conCommandIsRegistered);
    slots[Indexes.ConCommand.get_dll_identifier] = @ptrCast(&conCommandGetDllIdentifier);
    slots[Indexes.ConCommand.create_base] = @ptrCast(&conCommandCreateBase);
    slots[Indexes.ConCommand.init] = @ptrCast(&conCommandInit);
    slots[Indexes.ConCommand.auto_complete_suggest] = @ptrCast(&conCommandAutoCompleteSuggest);
    slots[Indexes.ConCommand.can_auto_complete] = @ptrCast(&conCommandCanAutoComplete);
    slots[Indexes.ConCommand.dispatch] = @ptrCast(&conCommandDispatch);
    break :blk slots;
};

/// Static command object the engine holds between registration and unload.
var test_ping_concommand = ConCommandObject{
    .vptr = &concommand_vtable,
    .next = null,
    .registered = 0,
    .name = test_command_name,
    .help = "Test command: zorcerer ping",
    .flags = 0,
    .command_callback = null,
    .completion_callback = null,
    .callback_flags = 0,
};

/// `ICvar` pointer captured at registration time, or null while the test
/// command is not registered. Used to call `UnregisterConCommand` on unload.
var test_ping_cvar: ?*anyopaque = null;

/// DLL identifier allocated from `ICvar` for the test command, or -1 while no
/// identifier has been allocated. The command's `GetDLLIdentifier` reports it.
var test_ping_dll_id: c_int = -1;

/// Whether `registerTestPingCommand` completed and the engine holds the
/// command. Kept separately from the engine-managed `registered` byte so
/// teardown does not depend on the object's state.
var test_ping_registered = false;

/// Installed `IVEngineServer::ServerCommand` hook, or null while no manager
/// child is running. The detour reaches this module-level value because a
/// C-ABI function pointer cannot close over the hook it belongs to.
var server_command_hook: ?VTableHooks.VtableHook = null;

/// Guards the ping exchange against re-entry: `ServerCommand` is an engine
/// entry point and the test exchange must not start a second nested exchange.
var handling_test_ping = false;

/// Plugin manager singleton. The forked child (`pluginManagerChild`) uses it to
/// discover/cache the plugin .so files under tf/addons/zorcerer/plugins/, run
/// each plugin's load() hook, and serve callback events through
/// `Manager.listenForEvents`. The parent only wires the engine logger into its
/// copy before forking and keeps the manifests from `readConfig()`; the child's
/// own copy is released when it exits (see src/PluginManager.zig).
var plugin_manager = Manager.Manager.init();

/// The forked plugin-manager process, or null while none runs.
var manager_child: ?ForkedChild = null;

/// Pulls the engine's Source SDK console logging function out of a live
/// IVEngineServer instance. `engine_interface` is the interface pointer
/// the engine module factory probe in load() resolved; zig-hooks reads
/// the virtual method table behind it, the slot that
/// codegen_generated/engine_indexes.zig records under
/// `IVEngineServer.log_print` is selected, and its contents are
/// reinterpreted as `abi.Logger.PrintFn` - the signature that matches
/// the LogPrint ABI that index was produced for (this pointer first, then
/// one zero-terminated line).
/// Returns the print function, or null when the recorded slot holds no
/// entry: the running engine then does not match the index layout that
/// every hook installation further down load() relies on.
fn logPrintOf(engine_interface: *anyopaque) ?abi.Logger.PrintFn {
    const slot = VTableHooks.vtableOf(engine_interface)[Indexes.IVEngineServer.log_print];
    return @ptrCast(slot orelse return null);
}

test "logPrintOf resolves the slot the codegen recorded for LogPrint" {
    const fake_log_print: abi.Logger.PrintFn = struct {
        fn print(context: *anyopaque, message: [*:0]const u8) callconv(.c) void {
            _ = context;
            _ = message;
        }
    }.print;

    // A fake IVEngineServer-shaped object: the first member is the vtable
    // pointer, and enough trailing slots exist to reach the recorded
    // LogPrint index.
    var slots = [_]Slot{null} ** (Indexes.IVEngineServer.log_print + 1);
    slots[Indexes.IVEngineServer.log_print] = @ptrCast(fake_log_print);
    var fake = extern struct { vptr: [*]const Slot }{ .vptr = &slots };

    const resolved = logPrintOf(@ptrCast(&fake)).?;
    try std.testing.expectEqual(@intFromPtr(fake_log_print), @intFromPtr(resolved));
}

test "logPrintOf reports a recorded-but-empty LogPrint slot as null" {
    var slots = [_]Slot{null} ** (Indexes.IVEngineServer.log_print + 1);
    var fake = extern struct { vptr: [*]const Slot }{ .vptr = &slots };

    try std.testing.expect(logPrintOf(@ptrCast(&fake)) == null);
}

/// Returns whether `command` is the test scenario's `zorcerer ping`.
///
/// The engine may deliver the console line with a trailing newline or
/// surrounding whitespace, so the comparison trims it first.
fn isTestPingCommand(command: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, command, " \t\r\n"), test_ping_command);
}

/// Calls the engine's original `ServerCommand` implementation.
///
/// `command` must be zero-terminated. Does nothing when no hook is installed,
/// which also makes the helper safe to call from early-failure paths.
fn callOriginalServerCommand(this: *anyopaque, command: [*:0]const u8) void {
    const hook = server_command_hook orelse return;
    const original: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void =
        @ptrCast(hook.original_fn);
    original(this, command);
}

/// Sends one `serverCommand` JSON-RPC request to `fd` and waits for the
/// matching response.
///
/// While waiting, log notifications from the manager are executed and
/// answered exactly like `jsonListener` does, so manager logging cannot be
/// mistaken for the test response.
///
/// The returned slice borrows `result_buffer` and is valid until the caller
/// overwrites it.
///
/// Errors: framing errors from `Ipc.readFrame`/`Ipc.writeFrame`, JSON errors
/// from `Ipc.parseRequest`/`Ipc.parseResponse`, `error.UnexpectedResponseId`
/// when the reply does not answer `Ipc.server_command_request_id`, and the
/// response-shape errors of `Ipc.serverCommandFromResponse`.
fn exchangeServerCommand(
    fd: std.os.linux.fd_t,
    command: []const u8,
    result_buffer: []u8,
) ![]const u8 {
    const allocator = std.heap.page_allocator;
    const request_json = try Ipc.makeServerCommandRequest(allocator, command);
    defer allocator.free(request_json);

    std.debug.print("[zorcerer] JSON-RPC request: {s}\n", .{request_json});
    try Ipc.writeFrame(fd, request_json);

    while (true) {
        const frame = try Ipc.readFrame(fd);
        if (!frame.framed) return error.InvalidFrame;
        if (!frame.received) return error.EmptyMessage;

        if (Ipc.parseRequest(allocator, frame.text())) |request| {
            defer request.deinit();
            const request_id = request.id();
            _ = try handleRequest(request.value);
            if (!request_id.isNotification()) {
                try Ipc.sendResultResponse(fd, request_id, "\"OK\"");
            }
            continue;
        } else |err| switch (err) {
            error.NotRpcRequest => {},
            else => return err,
        }

        var response = Ipc.parseResponse(allocator, frame.text());
        defer response.deinit();
        const rpc_response = try response.value();
        if (!rpc_response.id.eql(Ipc.server_command_request_id)) {
            return error.UnexpectedResponseId;
        }

        std.debug.print("[zorcerer] JSON-RPC response: {s}\n", .{frame.text()});
        const reply = try Ipc.serverCommandFromResponse(rpc_response);
        if (reply.len > result_buffer.len) return error.NoSpaceLeft;
        @memcpy(result_buffer[0..reply.len], reply);
        return result_buffer[0..reply.len];
    }
}

/// Performs one JSON-RPC ping exchange and executes the manager's reply
/// through the original engine `ServerCommand`.
///
/// `server` is the IVEngineServer instance used to execute the reply. The
/// helper does nothing while no plugin-manager child is running or while an
/// exchange is already in progress; re-entry is ignored because both engine
/// entry points used here can run nested command lines.
///
/// The exchange is synchronous and must run on the engine thread that
/// invoked the command; the engine invokes console commands from one thread
/// at a time.
fn runTestPingExchange(server: *anyopaque) void {
    if (handling_test_ping) return;

    const child = if (manager_child) |*running| running else return;

    handling_test_ping = true;
    defer handling_test_ping = false;

    var reply_buffer: [256]u8 = undefined;
    const reply = exchangeServerCommand(
        child.socket,
        test_ping_command,
        reply_buffer[0 .. reply_buffer.len - 1],
    ) catch |err| {
        std.debug.print("[zorcerer] {s} exchange failed: {s}\n", .{
            test_ping_command,
            @errorName(err),
        });
        return;
    };

    // `ServerCommand` takes a zero-terminated line; keep one byte free for
    // the terminator.
    reply_buffer[reply.len] = 0;
    std.debug.print("[zorcerer] executing ServerCommand: {s}\n", .{reply});
    callOriginalServerCommand(server, reply_buffer[0..reply.len :0].ptr);
}

/// Detour installed in `IVEngineServer::ServerCommand`.
///
/// The registered `zorcerer` ConCommand is the normal trigger for the test
/// exchange. This detour keeps the previous whole-line fallback for engine
/// paths that hand `ServerCommand` the complete `zorcerer ping` line, and it
/// owns the original function pointer used to execute the manager's reply.
///
/// Non-test commands go straight to the original implementation. A nested
/// ping re-enters the original implementation instead of starting a second
/// exchange.
fn serverCommandDetour(this: *anyopaque, command: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(command);
    if (!isTestPingCommand(text) or handling_test_ping) {
        callOriginalServerCommand(this, command);
        return;
    }

    runTestPingExchange(this);
}

/// Installs the `ServerCommand` detour on the shared IVEngineServer vtable.
///
/// Errors: `VTableHooks.HookError` when the slot is empty or cannot be made
/// writable.
fn installServerCommandHook(engine_interface: *anyopaque) !void {
    server_command_hook = try VTableHooks.VtableHook.install(
        VTableHooks.vtableOf(engine_interface),
        Indexes.IVEngineServer.server_command,
        @ptrCast(&serverCommandDetour),
    );
}

/// Removes the `ServerCommand` detour, if one is installed.
///
/// A failed restore is logged instead of propagated: unloading must still
/// proceed and release the manager child.
fn uninstallServerCommandHook() void {
    if (server_command_hook) |*hook| {
        hook.uninstall() catch |err| {
            Log.logLine(
                "[zorcerer] removing the ServerCommand hook failed: {s}\n",
                .{@errorName(err)},
            );
        };
        server_command_hook = null;
    }
}

/// Registers the test `zorcerer` console command with the engine's ICvar.
///
/// The ICvar interface is resolved through the engine's interface factory,
/// the same route the Source SDK's `ConnectTier1Libraries` uses. A DLL
/// identifier is allocated for the command so `GetDLLIdentifier` returns a
/// value the engine's own `UnregisterConCommands` can match, then
/// `ICvar::RegisterConCommand` links the static command object into the
/// engine's command table. Once this succeeds, `zorcerer ping` reaches
/// `conCommandDispatch` instead of being reported as an unknown command.
///
/// On success the command remains registered until
/// `unregisterTestPingCommand` is called. On error nothing is registered and
/// the previous registration state is unchanged.
///
/// Errors: `error.AlreadyRegistered` when a registration is already active,
/// `error.CvarVersionTooLong` when the version string does not fit the local
/// buffer, `error.CvarUnavailable` when the factory does not expose the
/// recorded ICvar interface version,
/// `error.MissingAllocateDllIdentifier`,
/// `error.MissingRegisterConCommand`, or `error.MissingUnregisterConCommand`
/// when the live ICvar vtable lacks a required method, and
/// `error.InvalidDllIdentifier` when allocation returns a negative id.
fn registerTestPingCommand(interface_factory: CreateInterfaceFn) !void {
    if (test_ping_registered) return error.AlreadyRegistered;

    var version_buffer: [32]u8 = undefined;
    const version = std.fmt.bufPrintZ(
        &version_buffer,
        "{s}",
        .{Indexes.cvar_interface_version},
    ) catch return error.CvarVersionTooLong;

    const cvar_ptr = interface_factory(version.ptr, null) orelse
        return error.CvarUnavailable;

    const cvar_vtable = VTableHooks.vtableOf(cvar_ptr);
    const allocate_slot = cvar_vtable[Indexes.ICvar.allocate_dll_identifier] orelse
        return error.MissingAllocateDllIdentifier;
    const register_slot = cvar_vtable[Indexes.ICvar.register_con_command] orelse
        return error.MissingRegisterConCommand;
    if (cvar_vtable[Indexes.ICvar.unregister_con_command] == null)
        return error.MissingUnregisterConCommand;

    const allocate: *const fn (*anyopaque) callconv(.c) c_int =
        @ptrCast(allocate_slot);
    const dll_id = allocate(cvar_ptr);
    if (dll_id < 0) return error.InvalidDllIdentifier;

    // The id and interface must be visible through the command's virtual
    // methods while the engine is linking it, so publish them first.
    test_ping_dll_id = dll_id;
    test_ping_cvar = cvar_ptr;

    const register: *const fn (*anyopaque, *anyopaque) callconv(.c) void =
        @ptrCast(register_slot);
    register(cvar_ptr, @ptrCast(&test_ping_concommand));

    test_ping_registered = true;
    Log.logLine("[MyLoader] registered the {s} console command\n", .{test_command_name});
}

/// Removes the test command from the engine and clears the registration
/// state.
///
/// Safe to call while no command is registered. A missing unregister slot is
/// logged instead of propagated because unloading must still proceed, which
/// mirrors how the ServerCommand hook teardown treats a failed restore.
fn unregisterTestPingCommand() void {
    if (!test_ping_registered) return;
    test_ping_registered = false;

    const cvar_ptr = test_ping_cvar orelse {
        test_ping_dll_id = -1;
        return;
    };

    const slot = VTableHooks.vtableOf(cvar_ptr)[Indexes.ICvar.unregister_con_command];
    if (slot) |unregister_slot| {
        const unregister: *const fn (*anyopaque, *anyopaque) callconv(.c) void =
            @ptrCast(unregister_slot);
        unregister(cvar_ptr, @ptrCast(&test_ping_concommand));
        test_ping_concommand.registered = 0;
    } else {
        Log.logLine(
            "[zorcerer] unregistering the {s} command failed: missing UnregisterConCommand\n",
            .{test_command_name},
        );
    }

    test_ping_cvar = null;
    test_ping_dll_id = -1;
}

test "ServerCommand ping matching ignores console whitespace" {
    try std.testing.expect(isTestPingCommand("zorcerer ping"));
    try std.testing.expect(isTestPingCommand("  zorcerer ping\r\n"));
    try std.testing.expect(!isTestPingCommand("zorcerer ping extra"));
    try std.testing.expect(!isTestPingCommand("echo \"Pong!\""));
}

test "test ping command recognizes the engine's command tokens" {
    // Only argc and the first two argv entries are read; the token buffers
    // and the remaining entries stay undefined.
    var command: CCommand = undefined;
    command.argc = 2;
    command.argv[0] = test_command_name;
    command.argv[1] = test_ping_argument;
    try std.testing.expect(isTestPingInvocation(&command));

    command.argc = 1;
    try std.testing.expect(!isTestPingInvocation(&command));

    command.argc = 3;
    command.argv[2] = "extra";
    try std.testing.expect(!isTestPingInvocation(&command));

    command.argc = 2;
    command.argv[1] = "pong";
    try std.testing.expect(!isTestPingInvocation(&command));
}

test "CCommand layout follows the Source SDK C++ layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CCommand, "argc"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CCommand, "argv0_size"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CCommand, "arg_s_buffer"));
    try std.testing.expectEqual(@as(usize, 520), @offsetOf(CCommand, "argv_buffer"));
    try std.testing.expectEqual(@as(usize, 1032), @offsetOf(CCommand, "argv"));
    try std.testing.expectEqual(@as(usize, 1544), @sizeOf(CCommand));
}

test "test ping ConCommand layout follows the Source SDK C++ layout" {
    // Offsets from the Itanium C++ ABI layout of ConCommandBase followed by
    // ConCommand (public/tier1/convar.h). The engine reads these fields
    // directly when it links the command into its own list.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ConCommandObject, "vptr"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ConCommandObject, "next"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ConCommandObject, "registered"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(ConCommandObject, "name"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(ConCommandObject, "help"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(ConCommandObject, "flags"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ConCommandObject, "command_callback"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(ConCommandObject, "completion_callback"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(ConCommandObject, "callback_flags"));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(ConCommandObject));
}

test "test ping ConCommand vtable follows the generated indices" {
    try std.testing.expectEqual(
        @intFromPtr(&conCommandIsCommand),
        @intFromPtr(concommand_vtable[Indexes.ConCommand.is_command].?),
    );
    try std.testing.expectEqual(
        @intFromPtr(&conCommandGetName),
        @intFromPtr(concommand_vtable[Indexes.ConCommand.get_name].?),
    );
    try std.testing.expectEqual(
        @intFromPtr(&conCommandDispatch),
        @intFromPtr(concommand_vtable[Indexes.ConCommand.dispatch].?),
    );
}

test "manager answers the ServerCommand ping round trip over JSON-RPC" {
    var child = try forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    var buffer: [256]u8 = undefined;
    const reply = try exchangeServerCommand(
        child.socket,
        Manager.test_ping_command,
        buffer[0 .. buffer.len - 1],
    );
    try std.testing.expectEqualStrings(Manager.test_ping_reply, reply);
}

/// Waits for `pid` to exit and verifies a successful exit status.
///
/// Retries interrupted waits. Returns `error.WaitFailed` when the wait itself
/// fails and `error.ChildFailed` when the child exited abnormally or with a
/// non-zero status.
fn waitForChild(pid: std.os.linux.pid_t) !void {
    var status: u32 = undefined;
    while (true) {
        const rc = std.os.linux.waitpid(pid, &status, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (!std.os.linux.W.IFEXITED(status) or
                    std.os.linux.W.EXITSTATUS(status) != 0)
                {
                    return error.ChildFailed;
                }
                return;
            },
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

/// Entry point of a forked child. `fd` is the child's end of the IPC socket
/// pair; the parent holds the other end.
///
/// Returning from a child entry point is allowed: `forkChild` exits the child
/// process afterwards, so the child never returns into the parent's stack.
pub const ChildMain = *const fn (fd: std.os.linux.fd_t) void;

/// A forked child plus the parent's end of the IPC socket pair.
pub const ForkedChild = struct {
    /// Process id of the child.
    pid: std.os.linux.pid_t,
    /// Parent's end of the socket pair; see `close`.
    socket: std.os.linux.fd_t,
    /// Whether `socket` is still open; keeps `close` idempotent.
    socket_open: bool = true,

    /// Closes the parent's end of the socket pair, if still open.
    ///
    /// Closing is also how the parent asks a long-lived child to shut down:
    /// the child's read returns EOF and it exits.
    pub fn close(self: *ForkedChild) void {
        if (!self.socket_open) return;
        _ = std.os.linux.close(self.socket);
        self.socket_open = false;
    }

    /// Waits for the child to exit and verifies a zero exit status.
    ///
    /// Does not close `socket`. Use `finish` for the usual shutdown order.
    pub fn wait(self: ForkedChild) !void {
        try waitForChild(self.pid);
    }

    /// Closes the socket (signalling shutdown) and waits for the child.
    ///
    /// The socket is closed even when waiting fails.
    ///
    /// Errors: see `wait`.
    pub fn finish(self: *ForkedChild) !void {
        self.close();
        try waitForChild(self.pid);
    }
};

/// Forks a child that runs `child_main` and returns the parent's handle to it.
///
/// The parent creates a connected `AF_UNIX`/`SOCK_STREAM` pair before forking;
/// the child gets one end, the parent keeps the other in the returned handle.
/// The child exits once `child_main` returns, so a child that should stay alive
/// must block in `child_main`.
///
/// Errors: `error.SocketPairFailed`, `error.ForkUnsupported`, and
/// `error.ForkFailed`. No child exists when one of these is returned.
pub fn forkChild(child_main: ChildMain) !ForkedChild {
    var fds: [2]std.os.linux.fd_t = undefined;
    switch (std.os.linux.errno(std.os.linux.socketpair(
        std.os.linux.AF.UNIX,
        std.os.linux.SOCK.STREAM,
        0,
        &fds,
    ))) {
        .SUCCESS => {},
        else => return error.SocketPairFailed,
    }

    const fork_result = std.os.linux.fork();
    switch (std.os.linux.errno(fork_result)) {
        .SUCCESS => {},
        .NOSYS => {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ForkUnsupported;
        },
        else => {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ForkFailed;
        },
    }

    const pid: std.os.linux.pid_t = @intCast(fork_result);
    if (pid == 0) {
        _ = std.os.linux.close(fds[0]);
        child_main(fds[1]);
        _ = std.os.linux.close(fds[1]);
        std.os.linux.exit_group(0);
    }

    _ = std.os.linux.close(fds[1]);
    return .{ .pid = pid, .socket = fds[0] };
}

/// Message the plugin-manager child reports once it has loaded its plugins.
const manager_ready_message = "Hello from fork";

/// What the listener should do after executing one operation notification.
const RequestOutcome = enum {
    /// Keep serving the channel.
    continue_listening,
    /// The child reported successful readiness.
    ready,
};

/// Executes one operation notification received from the plugin manager.
///
/// `.stderr` messages are forwarded to the parent's log sink. `.ready` with
/// `manager_ready_message` reports success. Any other readiness text means the
/// child could not load its plugins: it is logged as a startup failure and
/// returned as `error.PluginLoadFailed`, so `load()` refuses the plugin set.
fn handleRequest(request: Ipc.Request) !RequestOutcome {
    switch (request.operation) {
        .stderr => {
            Log.logLine("{s}", .{request.message});
            return .continue_listening;
        },
        .ready => {
            if (std.mem.eql(u8, request.message, manager_ready_message)) {
                return .ready;
            }
            Log.logLine("[MyLoader] plugin manager startup failed: {s}\n", .{request.message});
            return error.PluginLoadFailed;
        },
    }
}

/// Executes one JSON-RPC response received from the plugin manager.
///
/// Error responses are printed as diagnostics instead of being treated as
/// results; the engine callbacks have no way to report the failure.
///
/// Errors: `error.UnexpectedResultType` when a successful response does not
/// carry the event text as a JSON string.
fn handleResponse(response: zjr.RpcResponse) !void {
    if (response.hasErr()) {
        std.debug.print(
            "JSON-RPC error {d}: {s}\n",
            .{ response.err().code, response.err().message },
        );
        return;
    }

    switch (response.result) {
        .string => |text| std.debug.print("{s}", .{text}),
        else => return error.UnexpectedResultType,
    }
}

/// Verifies that a response answers the request the listener is waiting for.
///
/// Errors: `error.UnexpectedResponseId` when no response is expected yet or
/// when the response carries a different ID.
fn validateResponseId(actual: zjr.RpcId, expected_response_id: ?i64) !void {
    const expected = expected_response_id orelse return error.UnexpectedResponseId;
    if (!actual.eql(expected)) return error.UnexpectedResponseId;
}

/// Listener for the manager's messages: reads framed JSON-RPC messages from
/// `socket` until the expected response or readiness arrives.
///
/// Notifications (`.stderr` log lines and `.ready`) are executed without a
/// reply, so child logging cannot terminate the listener or satisfy a pending
/// event exchange. Requests carrying an ID are answered with a JSON-RPC
/// result, and responses are matched against `expected_response_id`.
///
/// `expected_response_id` is null while waiting for readiness: the listener
/// returns after a successful `.ready` and fails with `error.PluginLoadFailed`
/// on a failed readiness text. For event exchanges it is
/// `Ipc.event_request_id`: the listener returns after handling that response.
///
/// Errors: `error.InvalidFrame` when the frame marker is missing,
/// `error.EmptyMessage` for a zero-length payload, `error.UnexpectedResponseId`
/// for a response that does not match a pending event, the framing errors of
/// `Ipc.readFrame`, the JSON errors of `Ipc.parseRequest`/`Ipc.parseResponse`,
/// and the response-shape errors of `handleResponse`.
fn jsonListener(socket: std.os.linux.fd_t, expected_response_id: ?i64) !void {
    const allocator = std.heap.page_allocator;

    while (true) {
        const frame = try Ipc.readFrame(socket);
        if (!frame.framed) return error.InvalidFrame;
        if (!frame.received) return error.EmptyMessage;

        const request = Ipc.parseRequest(allocator, frame.text()) catch |err| switch (err) {
            error.NotRpcRequest => {
                var response = Ipc.parseResponse(allocator, frame.text());
                defer response.deinit();
                const rpc_response = try response.value();
                try validateResponseId(rpc_response.id, expected_response_id);
                try handleResponse(rpc_response);
                return;
            },
            else => return err,
        };
        defer request.deinit();

        const request_id = request.id();
        const outcome = try handleRequest(request.value);

        if (!request_id.isNotification()) {
            try Ipc.sendResultResponse(socket, request_id, "\"OK\"");
        }

        if (outcome == .ready and expected_response_id == null) return;
    }
}

/// Child body: loads the plugin manager, reports readiness to the parent, and
/// then serves callback events until the parent closes the channel.
///
/// Readiness is sent after the load attempt finishes, whether or not any
/// plugins were found. A successful attempt sends `manager_ready_message`; a
/// failed one sends the failure text, which the parent treats as a failed
/// startup instead of ignoring it.
///
/// The listener runs even when loading failed, so the Entrypoint's synchronous
/// event exchange never blocks on a process that has already stopped reading.
///
/// Unlike a minimal reporting child, this one allocates and performs file and
/// dynamic-library I/O while loading plugins. That is safe only as long as the
/// parent is effectively single-threaded when `forkChild` is called, which
/// holds for the engine's VSP `Load` call.
fn pluginManagerChild(fd: std.os.linux.fd_t) void {
    // The engine sink captured before the fork must not be called from here.
    plugin_manager.setIpcLogger(fd);

    // `message` borrows `failure`, so the buffer lives until the send below.
    var failure: [256]u8 = undefined;
    const message: []const u8 = load: {
        plugin_manager.loadPlugins() catch |err| {
            break :load std.fmt.bufPrint(
                &failure,
                "plugin loading failed: {s}",
                .{@errorName(err)},
            ) catch "plugin loading failed";
        };
        break :load manager_ready_message;
    };

    Ipc.sendReady(fd, message) catch {};
    Manager.listenForEvents(fd);
    plugin_manager.deinit();
}

/// Child used by the IPC tests: sends the same readiness message the
/// plugin-manager child sends once it is ready.
fn testReportChild(fd: std.os.linux.fd_t) void {
    Ipc.sendReady(fd, manager_ready_message) catch {};
}

/// Child used by the logging test: forwards a plugin print over IPC.
fn testLogChild(fd: std.os.linux.fd_t) void {
    Log.setupIpc(fd);
    Log.pluginPrint(undefined, "plugin log line\n");
}

test "child logging is sent over IPC" {
    var child = try forkChild(testLogChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    const request = try Ipc.parseRequest(std.testing.allocator, frame.text());
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings("plugin log line\n", request.value.message);
    try std.testing.expect(request.id().isNone());
}

test "forked child reports that it initialized" {
    var child = try forkChild(testReportChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.framed);
}

test "parent receives a JSON message from the child" {
    var child = try forkChild(testReportChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.received);

    const request = try Ipc.parseRequest(std.testing.allocator, frame.text());
    defer request.deinit();
    try std.testing.expectEqual(Ipc.Operation.ready, request.value.operation);
    try std.testing.expectEqualStrings(manager_ready_message, request.value.message);
    try std.testing.expect(request.id().isNone());
}

test "child payload matches the serialized request" {
    var child = try forkChild(testReportChild);
    defer child.finish() catch {};

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.matches(
        "{\"jsonrpc\": \"2.0\", \"method\": \"ready\", \"params\": {\"message\":\"Hello from fork\"}}",
    ));
}

test "listener schema decodes the ready operation" {
    const request = try Ipc.parseRequest(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"ready\",\"params\":{\"message\":\"Hello from fork\"}}",
    );
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.ready, request.value.operation);
    try std.testing.expectEqualStrings("Hello from fork", request.value.message);
}

test "listener schema decodes the stderr operation" {
    const request = try Ipc.parseRequest(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"stderr\",\"params\":{\"message\":\"a log line\"}}",
    );
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings("a log line", request.value.message);
}

test "successful readiness is accepted" {
    try std.testing.expectEqual(
        RequestOutcome.ready,
        try handleRequest(.{ .operation = .ready, .message = manager_ready_message }),
    );
}

test "failed readiness is rejected" {
    try std.testing.expectError(
        error.PluginLoadFailed,
        handleRequest(.{
            .operation = .ready,
            .message = "plugin loading failed: OutOfMemory",
        }),
    );
}

test "unexpected response IDs are rejected" {
    try std.testing.expectError(
        error.UnexpectedResponseId,
        validateResponseId(zjr.RpcId.of(2), Ipc.event_request_id),
    );
    try std.testing.expectError(
        error.UnexpectedResponseId,
        validateResponseId(zjr.RpcId.of(Ipc.event_request_id), null),
    );
    try validateResponseId(zjr.RpcId.of(Ipc.event_request_id), Ipc.event_request_id);
}

test "listener schema rejects an unknown operation" {
    try std.testing.expectError(
        error.UnknownMethod,
        Ipc.parseRequest(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"stdout\",\"params\":{\"message\":\"x\"}}",
        ),
    );
}

test "listener schema ignores unknown JSON-RPC fields" {
    const request = try Ipc.parseRequest(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"stderr\",\"params\":{\"message\":\"x\"},\"unexpected\":1}",
    );
    defer request.deinit();

    try std.testing.expectEqual(Ipc.Operation.stderr, request.value.operation);
    try std.testing.expectEqualStrings("x", request.value.message);
}

test "event JSON matches the schema" {
    const cases = [_]struct { event: Ipc.Event, name: []const u8 }{
        .{ .event = .pause, .name = "pause" },
        .{ .event = .unpause, .name = "unpause" },
        .{ .event = .levelInit, .name = "levelInit" },
        .{ .event = .serverActivate, .name = "serverActivate" },
        .{ .event = .levelShutdown, .name = "levelShutdown" },
    };

    var buffer: [128]u8 = undefined;
    for (cases) |case| {
        const text = try Ipc.encodeEvent(&buffer, case.event);

        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "{{\"jsonrpc\": \"2.0\", \"method\": \"{s}\", \"id\": {d}}}",
            .{ case.name, Ipc.event_request_id },
        );
        try std.testing.expectEqualStrings(expected, text);

        const parsed = try Ipc.parseEvent(std.testing.allocator, text);
        defer parsed.deinit();
        try std.testing.expectEqual(case.event, parsed.value.event);
        try std.testing.expect(parsed.id().eql(Ipc.event_request_id));
    }
}

test "event schema rejects an unknown callback" {
    try std.testing.expectError(
        error.UnknownMethod,
        Ipc.parseEvent(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\",\"id\":1}",
        ),
    );
}

test "manager answers every Entrypoint event with a JSON-RPC result" {
    var child = try forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    const cases = [_]struct { event: Ipc.Event, name: []const u8 }{
        .{ .event = .pause, .name = "pause" },
        .{ .event = .unpause, .name = "unpause" },
        .{ .event = .levelInit, .name = "levelInit" },
        .{ .event = .serverActivate, .name = "serverActivate" },
        .{ .event = .levelShutdown, .name = "levelShutdown" },
    };

    for (cases) |case| {
        try Ipc.sendEvent(child.socket, case.event);

        const frame = try Ipc.readFrame(child.socket);
        try std.testing.expect(frame.received);

        var response = Ipc.parseResponse(std.testing.allocator, frame.text());
        defer response.deinit();
        const rpc_response = try response.value();
        try std.testing.expect(!rpc_response.hasErr());
        try std.testing.expect(rpc_response.id.eql(Ipc.event_request_id));

        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "Event is {s}",
            .{case.name},
        );
        try std.testing.expectEqualStrings(expected, rpc_response.result.string);
    }
}

test "manager ignores event notifications" {
    var child = try forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    // Neither a valid event notification nor an invalid one may produce a
    // reply; only the following request is answered.
    try Ipc.writeFrame(child.socket, "{\"jsonrpc\":\"2.0\",\"method\":\"pause\"}");
    try Ipc.writeFrame(child.socket, "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\"}");
    try Ipc.sendEvent(child.socket, .unpause);

    const frame = try Ipc.readFrame(child.socket);
    try std.testing.expect(frame.received);

    var response = Ipc.parseResponse(std.testing.allocator, frame.text());
    defer response.deinit();
    const rpc_response = try response.value();
    try std.testing.expect(!rpc_response.hasErr());
    try std.testing.expect(rpc_response.id.eql(Ipc.event_request_id));
    try std.testing.expectEqualStrings("Event is unpause", rpc_response.result.string);
}

test "manager answers an unknown event instead of stalling" {
    var child = try forkChild(Manager.listenForEvents);
    defer child.finish() catch {};

    try Ipc.writeFrame(
        child.socket,
        "{\"jsonrpc\":\"2.0\",\"method\":\"bogus\",\"id\":3}",
    );

    const frame = try Ipc.readFrame(child.socket);
    var response = Ipc.parseResponse(std.testing.allocator, frame.text());
    defer response.deinit();
    const rpc_response = try response.value();

    try std.testing.expect(rpc_response.hasErr());
    try std.testing.expect(rpc_response.id.eql(3));
    try std.testing.expectEqual(
        @as(i32, @intFromEnum(zjr.ErrorCode.MethodNotFound)),
        rpc_response.err().code,
    );
    try std.testing.expectEqualStrings("Event is invalid", rpc_response.err().message);
}

fn load(
    this: *anyopaque,
    interface_factory: CreateInterfaceFn,
    game_server_factory: CreateInterfaceFn,
) callconv(.c) bool {
    _ = this;
    _ = game_server_factory;

    // Extracting the Source engine's console logging function, in three
    // steps:
    //   1. Get the engine interface itself out of the engine: probe the
    //      engine module's CreateInterface factory with the IVEngineServer
    //      version strings the codegen knows (newest first) and remember
    //      the string that actually answered.
    //   2. Receive the LogPrint pointer out of that interface via
    //      logPrintOf(), which picks the virtual method table slot the
    //      codegen recorded under IVEngineServer.log_print.
    //   3. Capture both in the Log module as its Source SDK logging sink,
    //      before any load decision is made, so even the refusal messages
    //      below reach the server console. The same print function is
    //      handed to the plugin manager further down.
    //
    // Only a matching engine build is fully trustworthy: for any refused
    // build the single log call in the refusal path may go through a slot
    // whose meaning shifted with the engine version - the accepted
    // trade-off for being able to report the refusal at all. Without any
    // answered engine build there is nothing to extract the logger from
    // and no working channel to report that fact through; the load is
    // refused immediately.
    var probe_version_buf: [32]u8 = undefined;
    const engine_version: []const u8 = version: {
        for (engine_interface_versions) |requested_version| {
            const engine_module_name = std.fmt.bufPrintZ(
                &probe_version_buf,
                "{s}",
                .{requested_version},
            ) catch break :version "";
            engine = interface_factory(engine_module_name.ptr, null);

            if (engine != null) {
                break :version requested_version;
            }
        }
        break :version "";
    };
    if (engine_version.len == 0) {
        return false;
    }

    const print_fn = logPrintOf(engine.?) orelse return false;
    Log.setup(.{ .context = engine.?, .print = print_fn });

    if (!std.mem.eql(u8, engine_version, Indexes.interfaceversion_vengineserver)) {
        Log.logLine(
            "[MyLoader] engine version mismatch: indices are for {s}, engine answered as {s} - refusing to install hooks\n",
            .{ Indexes.interfaceversion_vengineserver, engine_version },
        );
        return false;
    }

    Log.logLine("[MyLoader] Load() reached, engine version confirmed: {s}\n", .{engine_version});

    plugin_manager.setLogger(engine.?, print_fn);

    if (manager_child != null) {
        Log.logLine("[MyLoader] plugin manager is already running; refusing a second one\n", .{});
        return false;
    }

    manager_child = forkChild(pluginManagerChild) catch |err| {
        Log.logLine("[MyLoader] forking the plugin manager failed: {s}\n", .{@errorName(err)});
        return false;
    };

    // Waits for the child's readiness report, forwarding any log lines it sends
    // on the way. A failed plugin load is reported as a failed readiness text,
    // so it refuses the startup instead of returning a successful load. The
    // child keeps running (and the socket open) afterwards; unload() is what
    // closes the socket and reaps it.
    jsonListener(manager_child.?.socket, null) catch |err| {
        if (err != error.PluginLoadFailed) {
            Log.logLine("[MyLoader] plugin manager startup failed: {s}\n", .{@errorName(err)});
        }
        if (manager_child) |*child| child.finish() catch {};
        manager_child = null;
        return false;
    };

    // The test scenario's trigger is a real console command. Without the
    // registration below the engine tokenizes `zorcerer ping` as the unknown
    // command `zorcerer`; with it, the engine dispatches to this module and
    // the dispatch callback starts the JSON-RPC round trip.
    //
    // The ServerCommand hook remains installed because its original function
    // pointer is how the manager's reply (`echo "Pong!"`) is executed through
    // the engine. It also keeps the previous whole-line fallback for engine
    // paths that hand ServerCommand the complete `zorcerer ping` line.
    installServerCommandHook(engine.?) catch |err| {
        Log.logLine(
            "[MyLoader] installing the ServerCommand hook failed: {s}\n",
            .{@errorName(err)},
        );
        if (manager_child) |*child| child.finish() catch {};
        manager_child = null;
        return false;
    };

    registerTestPingCommand(interface_factory) catch |err| {
        Log.logLine(
            "[MyLoader] registering the {s} command failed: {s}\n",
            .{ test_command_name, @errorName(err) },
        );
        uninstallServerCommandHook();
        if (manager_child) |*child| child.finish() catch {};
        manager_child = null;
        return false;
    };

    const manifests: ?[]const Manager.Manifest = plugin_manager.readConfig() catch null;
    if (manifests) |m| {
        for (m) |manifest| {
            std.debug.print("\n{s}: {s}\n", .{ manifest.id, manifest.version });
        }
    }

    return true;
}

fn unload(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] unloading, removing demo hooks and command.\n", .{});

    // Remove the engine-visible command before dropping the hook and the
    // manager it depends on, so no later console invocation can dispatch
    // into the unloading module.
    unregisterTestPingCommand();
    uninstallServerCommandHook();

    if (manager_child) |*child| {
        // Closing our end is the shutdown signal: the child's event listener
        // sees EOF, unloads its plugins and exits, so finish() can reap it.
        child.finish() catch |err| {
            Log.logLine("[MyLoader] plugin manager shutdown failed: {s}\n", .{@errorName(err)});
        };
        manager_child = null;
    }

    // Releases the manifests the parent parsed in load(). The child's plugin
    // state lived in its own copy of the manager and is already gone.
    plugin_manager.deinit();
    engine = null;
    // The Log module keeps the captured sink: the engine interface stays
    // resident for the whole process lifetime, so it remains valid, and
    // plugin_load/reload re-captures it in load() anyway.
}

/// Reports one VSP callback to the forked plugin manager and executes its
/// reply.
///
/// Does nothing while no manager process is running (before `load` succeeds or
/// after `unload`). The exchange is synchronous: the manager answers every
/// event with exactly one response frame, which `jsonListener` prints, so
/// "Event is X" reaches stderr before the callback returns. Log notifications
/// sent by the child meanwhile are forwarded instead of being mistaken for the
/// response.
///
/// The engine invokes VSP callbacks from one thread at a time; this function
/// is not reentrant and must not be called concurrently.
///
/// Errors are logged rather than propagated: the engine callbacks have no way
/// to report failure, and `unload` owns the manager's lifetime.
fn sendManagerEvent(event: Ipc.Event) void {
    const child = if (manager_child) |*running| running else return;

    Ipc.sendEvent(child.socket, event) catch |err| {
        Log.logLine(
            "[MyLoader] sending the {s} event to the plugin manager failed: {s}\n",
            .{ @tagName(event), @errorName(err) },
        );
        return;
    };

    jsonListener(child.socket, Ipc.event_request_id) catch |err| {
        Log.logLine(
            "[MyLoader] handling the plugin manager's reply to {s} failed: {s}\n",
            .{ @tagName(event), @errorName(err) },
        );
    };
}

fn pause(this: *anyopaque) callconv(.c) void {
    _ = this;
    sendManagerEvent(.pause);
}

fn unpause(this: *anyopaque) callconv(.c) void {
    _ = this;
    sendManagerEvent(.unpause);
}

fn getPluginDescription(this: *anyopaque) callconv(.c) [*:0]const u8 {
    _ = this;
    return "MyLoader foundation (Zig)";
}

fn levelInit(this: *anyopaque, map_name: [*:0]const u8) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] LevelInit: {s}\n", .{std.mem.span(map_name)});
    sendManagerEvent(.levelInit);
}

fn serverActivate(
    this: *anyopaque,
    edict_list: *anyopaque,
    edict_count: c_int,
    client_max: c_int,
) callconv(.c) void {
    _ = this;
    _ = edict_list;
    Log.logLine("[MyLoader] ServerActivate: {d} edicts, {d} max clients\n", .{ edict_count, client_max });
    sendManagerEvent(.serverActivate);
}

fn gameFrame(this: *anyopaque, simulating: bool) callconv(.c) void {
    _ = this;
    _ = simulating;
}

fn levelShutdown(this: *anyopaque) callconv(.c) void {
    _ = this;
    Log.logLine("[MyLoader] LevelShutdown\n", .{});
    sendManagerEvent(.levelShutdown);
}

/// Placeholder for every method this foundation doesn't implement yet.
/// Declared with zero parameters on purpose: the calling convention
/// doesn't validate argument count on entry, so this safely ignores
/// whatever registers/stack the real call set up and returns 0 in the
/// return register - false / PLUGIN_CONTINUE / null, whichever the real
/// signature expected. Replace the corresponding slot below once you
/// actually need that callback to do something.
fn genericStub() callconv(.c) usize {
    return 0;
}

/// "More than enough" trailing slots for interface versions newer than
/// what's implemented above. Raise this if your SDK header has more
/// methods than this accounts for; see the module doc-comment.
const stub_count = 20;

const vtable = [_]Slot{
    @ptrCast(&load),
    @ptrCast(&unload),
    @ptrCast(&pause),
    @ptrCast(&unpause),
    @ptrCast(&getPluginDescription),
    @ptrCast(&levelInit),
    @ptrCast(&serverActivate),
    @ptrCast(&gameFrame),
    @ptrCast(&levelShutdown),
} ++ ([_]Slot{@ptrCast(&genericStub)} ** stub_count);

export fn CreateInterface(name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque {
    const requested = std.mem.span(name);
    for (plugin_interface_versions) |version| {
        if (std.mem.eql(u8, requested, version)) {
            if (return_code) |rc| rc.* = iface_ok;
            return @ptrCast(&plugin_instance);
        }
    }
    if (return_code) |rc| rc.* = iface_failed;
    return null;
}
