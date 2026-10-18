//! Minimal server-console command registration for Source SDK 2013.
//!
//! This is a Zig-side ABI-compatible ConCommand object, not a ConVar.
//! It reuses the engine's ConCommand vtable and replaces only the DLL-ID,
//! Init, and Dispatch entries. It does not invoke RTTI or use C++ exceptions.
//!
//! IMPORTANT: this mirrors the Linux x86_64 Source SDK 2013 ConCommandBase /
//! ConCommand layout. Re-check it if the target ABI or SDK headers change.

const VTableHooks = @import("hooks").VTableHook;
const Indexes = @import("codegen_generated/engine_indexes.zig");

const Slot = ?*const anyopaque;
const CreateInterfaceFn = *const fn (
    name: [*:0]const u8,
    return_code: ?*c_int,
) callconv(.c) ?*anyopaque;

const CommandCallback = *const fn (command: *const anyopaque) callconv(.c) void;
const ServerCommandFn = *const fn (
    engine: *anyopaque,
    command: [*:0]const u8,
) callconv(.c) void;
const AllocateDLLIdentifierFn = *const fn (cvar: *anyopaque) callconv(.c) c_int;
const RegisterConCommandFn = *const fn (
    cvar: *anyopaque,
    command: *anyopaque,
) callconv(.c) void;
const FindCommandFn = *const fn (
    cvar: *anyopaque,
    name: [*:0]const u8,
) callconv(.c) ?*anyopaque;

pub const InstallError = error{
    MissingCvarInterface,
    MissingCvarMethod,
    MissingEngineMethod,
    MissingNativeCommand,
};

/// Source SDK 2013 ConCommandBase fields followed by ConCommand's callback
/// fields. The explicit padding preserves the C++ layout on Linux x86_64.
const ConCommandObject = extern struct {
    vptr: [*]const Slot,
    next: ?*anyopaque,
    registered: bool,
    _padding_after_registered: [7]u8,
    name: [*:0]const u8,
    help: [*:0]const u8,
    flags: c_int,
    _padding_after_flags: [4]u8,
    callback: ?CommandCallback,
    completion_callback: ?*const anyopaque,
    callback_flags: u8,
    _padding_after_callback_flags: [7]u8,
};

comptime {
    if (@sizeOf(usize) != 8 or
        @sizeOf(ConCommandObject) != 72 or
        @offsetOf(ConCommandObject, "name") != 24 or
        @offsetOf(ConCommandObject, "flags") != 40 or
        @offsetOf(ConCommandObject, "callback") != 48 or
        @offsetOf(ConCommandObject, "callback_flags") != 64)
    {
        @compileError("ConCommandObject layout does not match the Linux x86_64 Source SDK ABI");
    }
}

var active_cvar: ?*anyopaque = null;
var active_engine: ?*anyopaque = null;
var dll_identifier: c_int = 0;
var server_command_fn: ?ServerCommandFn = null;
var command_registered = false;

// ConCommand's Linux x86_64 Source SDK 2013 primary vtable has 14 slots:
// two destructor entries, ConCommandBase virtuals, then AutoCompleteSuggest,
// CanAutoComplete, and Dispatch. Copy the live engine vtable and replace only
// the methods whose behavior must belong to this plugin.
const concommand_vtable_len: usize = 14;
const get_dll_identifier_slot: usize = 8;
const init_slot: usize = 10;
const dispatch_slot: usize = 13;

// Includes the two Itanium ABI header words before the vtable address point.
// Copying them from the engine's real "echo" command preserves its ABI RTTI
// metadata; this module does not construct type_info or call RTTI facilities.
var command_vtable_storage: [VTableHooks.header_words + concommand_vtable_len]Slot =
    [_]Slot{null} ** (VTableHooks.header_words + concommand_vtable_len);

fn onZorcererCommand(command: *const anyopaque) callconv(.c) void {
    _ = command;
    const engine = active_engine orelse return;
    const server_command = server_command_fn orelse return;
    server_command(engine, "echo \"Zorcerer is on!\"\n");
}

fn getDLLIdentifier(this: *const ConCommandObject) callconv(.c) c_int {
    _ = this;
    return dll_identifier;
}

// Skip ConCommandBase's static per-module auto-registration path. We register
// this object explicitly through ICvar::RegisterConCommand.
fn initCommand(this: *ConCommandObject) callconv(.c) void {
    _ = this;
}

fn dispatch(this: *ConCommandObject, command: *const anyopaque) callconv(.c) void {
    _ = this;
    onZorcererCommand(command);
}

var zorcerer_command = ConCommandObject{
    .vptr = @ptrCast(&command_vtable_storage[VTableHooks.header_words]),
    .next = null,
    .registered = false,
    ._padding_after_registered = [_]u8{0} ** 7,
    .name = "zorcerer",
    .help = "Check generated IVEngineServer indexes",
    .flags = 0,
    ._padding_after_flags = [_]u8{0} ** 4,
    .callback = &onZorcererCommand,
    .completion_callback = null,
    .callback_flags = 0,
    ._padding_after_callback_flags = [_]u8{0} ** 7,
};

/// Register `zorcerer` with the engine. The ICvar indices and the
/// IVEngineServer::ServerCommand index all come from generated constants.
pub fn install(factory: CreateInterfaceFn, engine: *anyopaque) InstallError!void {
    if (command_registered) return;

    const cvar_version: [*:0]const u8 = @ptrCast(Indexes.cvar_interface_version.ptr);
    const cvar = factory(cvar_version, null) orelse return error.MissingCvarInterface;

    const cvar_vtable = VTableHooks.vtableOf(cvar);
    const allocate_raw = cvar_vtable[Indexes.ICvar.allocate_dll_identifier] orelse
        return error.MissingCvarMethod;
    const register_raw = cvar_vtable[Indexes.ICvar.register_con_command] orelse
        return error.MissingCvarMethod;
    const find_raw = cvar_vtable[Indexes.ICvar.find_command] orelse
        return error.MissingCvarMethod;

    const allocate: AllocateDLLIdentifierFn = @ptrCast(allocate_raw);
    const register: RegisterConCommandFn = @ptrCast(register_raw);
    const find_command: FindCommandFn = @ptrCast(find_raw);

    // Reuse a genuine ConCommand RTTI header instead of fabricating a
    // std::type_info object in Zig. "echo" is a built-in server command.
    const native_echo = find_command(cvar, "echo") orelse return error.MissingNativeCommand;
    const native_vtable = VTableHooks.vtableOf(native_echo);
    const native_header = native_vtable - VTableHooks.header_words;
    command_vtable_storage[0] = native_header[0];
    command_vtable_storage[1] = native_header[1];
    @memcpy(
        command_vtable_storage[VTableHooks.header_words..],
        native_vtable[0..concommand_vtable_len],
    );
    command_vtable_storage[VTableHooks.header_words + get_dll_identifier_slot] =
        @ptrCast(&getDLLIdentifier);
    command_vtable_storage[VTableHooks.header_words + init_slot] = @ptrCast(&initCommand);
    command_vtable_storage[VTableHooks.header_words + dispatch_slot] = @ptrCast(&dispatch);
    zorcerer_command.vptr = @ptrCast(&command_vtable_storage[VTableHooks.header_words]);

    const engine_vtable = VTableHooks.vtableOf(engine);
    const server_command_raw = engine_vtable[Indexes.IVEngineServer.server_command] orelse
        return error.MissingEngineMethod;
    server_command_fn = @ptrCast(server_command_raw);

    active_cvar = cvar;
    active_engine = engine;
    dll_identifier = allocate(cvar);

    zorcerer_command.next = null;
    zorcerer_command.registered = false;
    register(cvar, @ptrCast(&zorcerer_command));
    command_registered = true;
}

/// Unregister the command before the plugin unloads.
pub fn uninstall() void {
    if (command_registered) {
        if (active_cvar) |cvar| {
            const cvar_vtable = VTableHooks.vtableOf(cvar);
            if (cvar_vtable[Indexes.ICvar.unregister_con_command]) |raw| {
                const unregister: RegisterConCommandFn = @ptrCast(raw);
                unregister(cvar, @ptrCast(&zorcerer_command));
            }
        }
    }

    command_registered = false;
    zorcerer_command.registered = false;
    zorcerer_command.next = null;
    active_cvar = null;
    active_engine = null;
    server_command_fn = null;
}
