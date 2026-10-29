//! Lua-facing bridge for the `zostd` standard library.
//!
//! The bridge exposes a small, capability-based API instead of raw engine
//! pointers or filesystem handles. Values are copied into Lua; no Zig pointer
//! or borrowed storage crosses the Lua boundary. The first part is the
//! `zostd.types` table, which mirrors the value types declared in
//! `src/zostd/types`. The second part is the host-facing function table
//! (`version`, `log`, `plugin_id`, `read_file`, `write_file`,
//! `server_command`, and `on`).
//!
//! Host operations are supplied through `Host`. When a callback is absent the
//! bridge uses conservative defaults: logging is dropped, the plugin id is the
//! configured id (possibly empty), `plugin://` file access is resolved against
//! the configured plugin root, and `server_command` is unavailable. The
//! functions never raise a Lua error on invalid input; they return
//! `(nil, error_message)` or a boolean instead, so no longjmp crosses a Zig
//! callback frame.

const std = @import("std");
const luajit = @import("luajit");
const Lua = luajit.Lua;
const zostd = @import("zostd");

/// Version reported by `zostd.version()`. Increase it when the Lua-visible
/// contract changes incompatibly.
pub const api_version: Lua.Integer = 1;

/// Largest file the built-in `plugin://` backend reads in one call.
pub const max_file_size: usize = 8 * 1024 * 1024;

/// Host callbacks backing the Lua-visible `zostd` functions.
///
/// All callbacks are optional. `context` is passed back unchanged. The file
/// callbacks must allocate returned buffers with the allocator they receive;
/// the bridge frees them with that same allocator after copying the bytes into
/// Lua.
pub const Host = struct {
    /// Opaque caller-owned context passed to every callback.
    context: ?*anyopaque = null,

    /// Writes one log line. The message does not include a trailing newline.
    log: ?*const fn (?*anyopaque, []const u8) void = null,

    /// Returns the id of the plugin whose script is running. The returned
    /// slice is borrowed and must stay valid for the duration of the call.
    plugin_id: ?*const fn (?*anyopaque) []const u8 = null,

    /// Reads `path` and returns its bytes. The path is the raw string the
    /// script passed, for example `plugin://config.txt`.
    read_file: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8 = null,

    /// Writes `data` to `path`.
    write_file: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror!void = null,

    /// Requests that the host execute one engine server command.
    server_command: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
};

/// Per-runtime state captured by every Lua C closure installed by `install()`.
///
/// The binding is heap-allocated by `Runtime`, so its address stays stable even
/// when the runtime value itself moves. The slices are borrowed from the
/// caller and must outlive the Lua state that references them.
pub const Binding = struct {
    /// Allocator used for temporary file buffers.
    allocator: std.mem.Allocator,

    /// Host callbacks and their context.
    host: Host = .{},

    /// Plugin id returned by `zostd.plugin_id()` when no host callback is set.
    plugin_id: []const u8 = "",

    /// Root directory used by the built-in `plugin://` file backend. A null
    /// root leaves plain relative paths relative to the process working
    /// directory and rejects `plugin://` paths.
    plugin_root: ?[]const u8 = null,
};

/// Key used to store the callback registry in the Lua registry.
var callbacks_key: u8 = 0;

/// Installs the `zostd` global table into `lua` using `binding` for host
/// operations. Calling the function again replaces the table and the callback
/// registry with fresh ones; the binding pointer itself must stay valid until
/// the Lua state is closed.
pub fn install(lua: *Lua, binding: *Binding) void {
    lua.createTable(0, 8);

    setFunction(lua, "version", binding, version);
    setFunction(lua, "log", binding, log);
    setFunction(lua, "plugin_id", binding, pluginId);
    setFunction(lua, "read_file", binding, readFile);
    setFunction(lua, "write_file", binding, writeFile);
    setFunction(lua, "server_command", binding, serverCommand);
    setFunction(lua, "on", binding, on);

    lua.pushLString("types");
    installTypes(lua);
    lua.setTable(-3);

    lua.setGlobal("zostd");
    installCallbackRegistry(lua);
}

/// Installs the `zostd.types` table.
///
/// Opaque pointer types (`Edict`, `Model`, `FileHandle`) are intentionally not
/// exposed: no raw engine handle crosses into Lua.
fn installTypes(lua: *Lua) void {
    lua.createTable(0, 12);

    installType(lua, "DamageMask", zostd.types.DamageMask);
    installType(lua, "EdictIndex", zostd.types.EdictIndex);
    installType(lua, "EntityHandle", zostd.types.EntityHandle);
    installType(lua, "EntityIndex", zostd.types.EntityIndex);
    installType(lua, "ModelIndex", zostd.types.ModelIndex);
    installType(lua, "QueryCvarCookie", zostd.types.QueryCvarCookie);
    installType(lua, "StringToken", zostd.types.StringToken);
    installType(lua, "TfClass", zostd.types.TfClass);
    installType(lua, "TfCondition", zostd.types.TfCondition);
    installType(lua, "TfObjectType", zostd.types.TfObjectType);
    installType(lua, "TfTeam", zostd.types.TfTeam);
    installType(lua, "TfWeaponId", zostd.types.TfWeaponId);
}

/// Installs one value type as a Lua table.
///
/// Every public declaration of `T` is exposed:
/// - constants of type `T` become tables with `value` and `name` fields;
/// - integer constants become plain Lua numbers;
/// - functions with at most two readable parameters become Lua functions.
///
/// Functions may take another single-field value type or an integer, so both
/// methods (`TfTeam.isGameTeam`) and constructors such as
/// `EntityIndex.fromEdictIndex` are available. Method names are converted from
/// Zig's camelCase to snake_case.
fn installType(lua: *Lua, comptime name: [:0]const u8, comptime T: type) void {
    lua.createTable(0, 16);

    inline for (comptime std.meta.declarations(T)) |declaration| {
        const value = @field(T, declaration.name);
        const ValueType = @TypeOf(value);

        if (comptime ValueType == T) {
            lua.pushLString(declaration.name);
            pushValueTable(lua, T, value, declaration.name);
            lua.setTable(-3);
        } else if (comptime isIntegerType(ValueType)) {
            lua.pushLString(declaration.name);
            lua.pushInteger(@intCast(value));
            lua.setTable(-3);
        } else if (comptime @typeInfo(ValueType) == .@"fn") {
            if (comptime functionIsExposable(ValueType)) {
                var method_name_buffer: [64]u8 = undefined;
                const method_name = snakeCase(&method_name_buffer, declaration.name);
                lua.pushLString(method_name);
                lua.pushCFunction(makeFunction(value));
                lua.setTable(-3);
            }
        }
    }

    lua.setField(-2, name);
}

/// Returns whether `Function` can be exposed to Lua.
///
/// Only functions with zero to two parameters are supported, matching the
/// current value-type APIs. Every parameter must be an integer or a
/// single-field struct holding an integer; the result must be non-void.
fn functionIsExposable(comptime Function: type) bool {
    const function_info = @typeInfo(Function).@"fn";
    if (function_info.params.len > 2) return false;
    if (function_info.return_type == null) return false;

    inline for (function_info.params) |parameter| {
        const ParameterType = parameter.type orelse return false;
        if (!isReadableParameter(ParameterType)) return false;
    }
    return true;
}

/// Returns whether a function parameter of `T` can be decoded from Lua.
fn isReadableParameter(comptime T: type) bool {
    if (isIntegerType(T)) return true;
    if (@typeInfo(T) != .@"struct") return false;

    const fields = std.meta.fields(T);
    return fields.len == 1 and isIntegerType(fields[0].type);
}

/// Returns whether `T` is an integer type that can be represented by a Lua
/// number without losing its documented range.
fn isIntegerType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => true,
        else => false,
    };
}

/// Converts a Zig camelCase identifier into snake_case in `buffer`.
///
/// Returns a slice of `buffer`. The conversion is deliberately small and only
/// handles ASCII identifiers used by `zostd.types`.
fn snakeCase(buffer: []u8, name: []const u8) []const u8 {
    var length: usize = 0;
    for (name) |character| {
        if (character >= 'A' and character <= 'Z') {
            if (length != 0) {
                buffer[length] = '_';
                length += 1;
            }
            buffer[length] = character + ('a' - 'A');
            length += 1;
        } else {
            buffer[length] = character;
            length += 1;
        }
    }
    return buffer[0..length];
}

/// Creates the C function implementing one reflected function.
///
/// Each argument may be a value table (`{ value = ... }`) or a plain number
/// for a single-field value type, or a plain number for an integer parameter.
/// Invalid arguments make the function return `false` for boolean results and
/// `nil` for everything else.
fn makeFunction(comptime function: anytype) Lua.CFunction {
    return struct {
        fn call(lua: *Lua) callconv(.c) i32 {
            const function_info = @typeInfo(@TypeOf(function)).@"fn";
            const ReturnType = function_info.return_type.?;

            switch (comptime function_info.params.len) {
                0 => pushResult(lua, function()),
                1 => {
                    const First = function_info.params[0].type.?;
                    const first = readArgument(First, lua, 1) orelse
                        return pushInvalid(lua, ReturnType);
                    pushResult(lua, function(first));
                },
                2 => {
                    const First = function_info.params[0].type.?;
                    const Second = function_info.params[1].type.?;
                    const first = readArgument(First, lua, 1) orelse
                        return pushInvalid(lua, ReturnType);
                    const second = readArgument(Second, lua, 2) orelse
                        return pushInvalid(lua, ReturnType);
                    pushResult(lua, function(first, second));
                },
                else => unreachable,
            }

            return 1;
        }
    }.call;
}

/// Reads one function argument of type `T` from `index`.
///
/// Integer parameters accept a Lua number directly. Value types accept either
/// a `{ value = ... }` table or a plain number.
fn readArgument(comptime T: type, lua: *Lua, index: i32) ?T {
    if (comptime isIntegerType(T)) {
        if (!lua.isNumber(index)) return null;
        return std.math.cast(T, lua.toInteger(index));
    }
    return readValue(T, lua, index);
}

/// Pushes the result used when an argument cannot be decoded.
///
/// Boolean-returning functions report failure as `false`; every other result
/// becomes `nil`.
fn pushInvalid(lua: *Lua, comptime ReturnType: type) i32 {
    if (comptime ReturnType == bool) {
        lua.pushBoolean(false);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// Reads a value of type `T` from a Lua table's `value` field or a Lua number
/// at `index`.
///
/// Every exposed value type stores its single field under the canonical Lua
/// name `value`, regardless of the Zig field name (`value` or `bits`).
///
/// Returns null when the value is missing, not a number, or not representable
/// by the underlying Zig field type.
fn readValue(comptime T: type, lua: *Lua, index: i32) ?T {
    const fields = std.meta.fields(T);
    if (fields.len != 1) return null;
    const FieldType = fields[0].type;

    const raw: Lua.Integer = value: {
        if (lua.isTable(index)) {
            _ = lua.getField(index, "value");
            defer lua.pop(1);
            if (!lua.isNumber(-1)) return null;
            break :value lua.toInteger(-1);
        }
        if (lua.isNumber(index)) {
            break :value lua.toInteger(index);
        }
        return null;
    };

    const field_value = std.math.cast(FieldType, raw) orelse return null;
    var result: T = undefined;
    @field(result, fields[0].name) = field_value;
    return result;
}

/// Pushes a `T` value as a Lua table with a `value` field and an optional
/// `name` field.
fn pushValueTable(lua: *Lua, comptime T: type, value: T, name: ?[]const u8) void {
    const fields = std.meta.fields(T);
    if (comptime fields.len != 1) {
        @compileError("zostd value types must have exactly one field");
    }

    lua.createTable(0, if (name == null) 1 else 2);

    lua.pushLString("value");
    pushResult(lua, @field(value, fields[0].name));
    lua.setTable(-3);

    if (name) |constant_name| {
        lua.pushLString("name");
        lua.pushLString(constant_name);
        lua.setTable(-3);
    }
}

/// Pushes a method result, recursively handling optional values and copying
/// single-field structs into value tables.
fn pushResult(lua: *Lua, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => {
            if (value) |inner| {
                pushResult(lua, inner);
            } else {
                lua.pushNil();
            }
        },
        .bool => lua.pushBoolean(value),
        .int, .comptime_int => lua.pushInteger(@intCast(value)),
        .@"struct" => pushValueTable(lua, T, value, null),
        else => lua.pushNil(),
    }
}

/// Pushes `name = function` onto the table at the top of the stack, capturing
/// `binding` as the C closure's first upvalue.
fn setFunction(
    lua: *Lua,
    name: [:0]const u8,
    binding: *Binding,
    function: Lua.CFunction,
) void {
    lua.pushLString(name);
    lua.pushLightUserdata(@ptrCast(binding));
    lua.pushCClosure(function, 1);
    lua.setTable(-3);
}

/// Returns the binding captured by the currently executing C closure.
fn currentBinding(lua: *Lua) *Binding {
    const pointer = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse
        unreachable;
    return @ptrCast(@alignCast(pointer));
}

/// Pushes `nil, message` and reports two Lua results.
fn fail(lua: *Lua, message: []const u8) i32 {
    lua.pushNil();
    lua.pushLString(message);
    return 2;
}

/// Pushes `nil, action: error_name` for a host callback failure.
fn failError(lua: *Lua, action: []const u8, err: anyerror) i32 {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{s}: {s}",
        .{ action, @errorName(err) },
    ) catch action;
    return fail(lua, message);
}

/// Creates or replaces the registry table that stores event callbacks.
fn installCallbackRegistry(lua: *Lua) void {
    lua.pushLightUserdata(@ptrCast(&callbacks_key));
    lua.createTable(0, 0);
    lua.setTableRaw(Lua.PseudoIndex.Registry);
}

/// Pushes the callback registry onto the stack.
///
/// Returns false (and pushes nothing) when `install()` has not created the
/// registry yet.
fn pushCallbackRegistry(lua: *Lua) bool {
    lua.pushLightUserdata(@ptrCast(&callbacks_key));
    _ = lua.getTableRaw(Lua.PseudoIndex.Registry);
    if (lua.isTable(-1)) return true;
    lua.pop(1);
    return false;
}

/// Lua C function implementing `zostd.version()`.
fn version(lua: *Lua) callconv(.c) i32 {
    _ = currentBinding(lua);
    lua.pushInteger(api_version);
    return 1;
}

/// Lua C function implementing `zostd.log(message)`.
fn log(lua: *Lua) callconv(.c) i32 {
    const message = lua.toLString(1) catch
        return fail(lua, "zostd.log expects a string message");

    const binding = currentBinding(lua);
    if (binding.host.log) |host_log| {
        host_log(binding.host.context, message[0..message.len]);
    }
    lua.pushBoolean(true);
    return 1;
}

/// Lua C function implementing `zostd.plugin_id()`.
fn pluginId(lua: *Lua) callconv(.c) i32 {
    const binding = currentBinding(lua);
    const id = if (binding.host.plugin_id) |host_plugin_id|
        host_plugin_id(binding.host.context)
    else
        binding.plugin_id;
    lua.pushLString(id);
    return 1;
}

/// Lua C function implementing `zostd.read_file(path)`.
fn readFile(lua: *Lua) callconv(.c) i32 {
    const path = lua.toLString(1) catch
        return fail(lua, "zostd.read_file expects a path string");
    const binding = currentBinding(lua);

    const bytes = if (binding.host.read_file) |host_read_file|
        host_read_file(binding.host.context, binding.allocator, path) catch |err|
            return failError(lua, "zostd.read_file", err)
    else
        readFileFromPluginRoot(binding, path) catch |err|
            return failError(lua, "zostd.read_file", err);

    defer binding.allocator.free(bytes);
    lua.pushLString(bytes);
    return 1;
}

/// Lua C function implementing `zostd.write_file(path, data)`.
fn writeFile(lua: *Lua) callconv(.c) i32 {
    const path = lua.toLString(1) catch
        return fail(lua, "zostd.write_file expects a path string");
    const data = lua.toLString(2) catch
        return fail(lua, "zostd.write_file expects string data");
    const binding = currentBinding(lua);

    if (binding.host.write_file) |host_write_file| {
        host_write_file(binding.host.context, path, data) catch |err|
            return failError(lua, "zostd.write_file", err);
    } else {
        writeFileToPluginRoot(binding, path, data) catch |err|
            return failError(lua, "zostd.write_file", err);
    }

    lua.pushBoolean(true);
    return 1;
}

/// Lua C function implementing `zostd.server_command(command)`.
fn serverCommand(lua: *Lua) callconv(.c) i32 {
    const command = lua.toLString(1) catch
        return fail(lua, "zostd.server_command expects a command string");
    const binding = currentBinding(lua);

    const host_server_command = binding.host.server_command orelse
        return fail(lua, "zostd.server_command is not configured");
    host_server_command(binding.host.context, command) catch |err|
        return failError(lua, "zostd.server_command", err);

    lua.pushBoolean(true);
    return 1;
}

/// Lua C function implementing `zostd.on(event, callback)`.
fn on(lua: *Lua) callconv(.c) i32 {
    const event = lua.toLString(1) catch
        return fail(lua, "zostd.on expects an event name");
    if (!lua.isFunction(2)) {
        return fail(lua, "zostd.on expects a callback function");
    }

    if (!pushCallbackRegistry(lua)) {
        return fail(lua, "zostd is not installed correctly");
    }

    lua.pushLString(event);
    _ = lua.getTableRaw(-2);
    if (!lua.isTable(-1)) {
        lua.pop(1);
        lua.createTable(0, 4);
        lua.pushLString(event);
        lua.pushValue(-2);
        lua.setTable(-4);
    }

    const length = lua.getLength(-1);
    lua.pushInteger(@intCast(length + 1));
    lua.pushValue(2);
    lua.setTable(-3);

    lua.pop(2);
    lua.pushBoolean(true);
    return 1;
}

/// Calls every callback registered for `event`.
///
/// The callback receives `(event, payload)`, where `payload` is nil when no
/// payload was supplied. Errors are logged through the host and do not stop
/// the remaining callbacks. The Lua stack is restored to its entry height.
pub fn dispatch(
    lua: *Lua,
    binding: *const Binding,
    event: []const u8,
    payload: ?[]const u8,
) void {
    const stack_top = lua.getTop();
    defer lua.setTop(stack_top);

    if (!pushCallbackRegistry(lua)) {
        return;
    }

    lua.pushLString(event);
    _ = lua.getTableRaw(-2);
    if (!lua.isTable(-1)) return;

    const callback_count = lua.getLength(-1);
    var index: usize = 1;
    while (index <= callback_count) : (index += 1) {
        _ = lua.getTableIndexRaw(-1, @intCast(index));
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            continue;
        }

        lua.pushLString(event);
        if (payload) |event_payload| {
            lua.pushLString(event_payload);
        } else {
            lua.pushNil();
        }

        lua.callProtected(2, 0, 0) catch |err| {
            logDispatchFailure(lua, binding, event, err);
            lua.pop(1);
        };
    }
}

/// Logs one event-callback failure without disturbing the Lua stack.
fn logDispatchFailure(
    lua: *Lua,
    binding: *const Binding,
    event: []const u8,
    err: anyerror,
) void {
    const message = lua.toString(-1) catch "<non-string error>";
    if (binding.host.log) |host_log| {
        var buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "zostd.on({s}) failed: {s} ({s})",
            .{ event, std.mem.span(message), @errorName(err) },
        ) catch "zostd event callback failed";
        host_log(binding.host.context, line);
    } else {
        std.log.err("zostd.on({s}) failed: {s} ({s})", .{
            event,
            std.mem.span(message),
            @errorName(err),
        });
    }
}

/// Resolves `path` inside the configured plugin root and reads it.
fn readFileFromPluginRoot(binding: *const Binding, path: []const u8) ![]u8 {
    const resolved = try resolvePath(binding.allocator, binding.plugin_root, path);
    defer binding.allocator.free(resolved);

    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        resolved,
        binding.allocator,
        .limited(max_file_size),
    );
}

/// Resolves `path` inside the configured plugin root and writes it.
fn writeFileToPluginRoot(binding: *const Binding, path: []const u8, data: []const u8) !void {
    const resolved = try resolvePath(binding.allocator, binding.plugin_root, path);
    defer binding.allocator.free(resolved);

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = resolved,
        .data = data,
    });
}

/// Resolves a `plugin://` or plain relative path against `root`.
///
/// Parent traversal is rejected. A `plugin://` path without a configured root
/// is an error; a plain path without a root stays relative to the process
/// working directory.
fn resolvePath(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    path: []const u8,
) ![]u8 {
    const uses_scheme = std.mem.startsWith(u8, path, "plugin://");
    const tail = if (uses_scheme) path["plugin://".len..] else path;

    var components = std.mem.splitScalar(u8, tail, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
    }

    const relative = std.mem.trimStart(u8, tail, "/");
    if (relative.len == 0) return error.InvalidPath;

    if (root) |plugin_root| {
        return std.Io.Dir.path.join(allocator, &.{ plugin_root, relative });
    }
    if (uses_scheme) return error.RootNotConfigured;
    return allocator.dupe(u8, path);
}
