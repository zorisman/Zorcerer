const std = @import("std");
const zjr = @import("zjr");
const Frame = @import("Frame.zig");
const Identifiers = @import("IdentifierRegistry.zig").Identifiers;

/// Callbacks whose occurrence the Entrypoint reports to the plugin manager.
pub const Event = enum {
    /// Entrypoint.pause() ran.
    pause,
    /// Entrypoint.unpause() ran.
    unpause,
    /// Entrypoint.levelInit() ran.
    levelInit,
    /// Entrypoint.serverActivate() ran.
    serverActivate,
    /// Entrypoint.levelShutdown() ran.
    levelShutdown,
    /// Entrypoint.clientCommand() ran. The payload is the full client command
    /// line, for example `"zlua ping"`.
    clientCommand,

    /// Returns the event named by a JSON-RPC method, or null.
    pub fn fromMethod(method: []const u8) ?Event {
        inline for (std.meta.fields(Event)) |field| {
            if (std.mem.eql(u8, method, field.name)) {
                return @as(Event, @enumFromInt(field.value));
            }
        }
        return null;
    }

    /// Parses one JSON-RPC event request.
    ///
    /// The JSON-RPC method name selects the event. An optional object `params`
    /// may carry a string member `payload`, which is returned unchanged as JSON
    /// text. The returned value owns the parsed JSON until `deinit()`.
    ///
    /// Errors: `error.NotRpcRequest` when `text` is a response or batch,
    /// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
    /// `error.UnknownMethod` when the method is not one of `Event`'s callbacks,
    /// and `error.InvalidParams` when `payload` is not a string.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !ParsedEvent {
        var rpc = zjr.parseRpcRequest(allocator, text);
        errdefer rpc.deinit();

        if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
        const request = rpc.request_msg.request;
        if (request.hasError()) return error.InvalidRpcRequest;

        const event = Event.fromMethod(request.method) orelse return error.UnknownMethod;

        var payload: ?[]const u8 = null;
        if (request.objectParams()) |params| {
            if (params.get("payload")) |value| {
                payload = switch (value) {
                    .string => |bytes| bytes,
                    else => return error.InvalidParams,
                };
            }
        }

        return .{
            .rpc = rpc,
            .value = .{ .event = event, .payload = payload },
        };
    }

    /// Serializes `event` as a JSON-RPC request into `buffer`.
    ///
    /// Uses `Identifiers.event_request_id` so the listener can answer with a
    /// matching ID. `payload` is optional JSON text that is transmitted as a
    /// string inside an object `params`. The returned slice borrows `buffer`.
    ///
    /// Errors: `error.OutOfMemory` while encoding the parameters,
    /// `error.WriteFailed` when the event does not fit `buffer`, and writer
    /// errors from parameter encoding.
    pub fn encode(self: *const @This(), buffer: []u8, payload: ?[]const u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(buffer);

        if (payload) |text| {
            const allocator = std.heap.page_allocator;
            const params_json = try std.json.Stringify.valueAlloc(
                allocator,
                .{ .payload = text },
                .{},
            );
            defer allocator.free(params_json);

            try zjr.composer.writeRequestJson(
                @tagName(self.*),
                params_json,
                Identifiers.event_request_id.rpcId(),
                &writer,
            );
        } else {
            try zjr.composer.writeRequestJson(
                @tagName(self.*),
                null,
                Identifiers.event_request_id.rpcId(),
                &writer,
            );
        }

        return writer.buffered();
    }

    /// Serializes `event` as a JSON-RPC request and sends it as one frame.
    ///
    /// Uses `Identifiers.event_request_id` so the listener can answer with a
    /// matching ID. `payload` is optional JSON text; see `encode`.
    /// Errors: `error.WriteFailed` when the event does not fit the stack buffer or
    /// the write fails, `error.OutOfMemory` while encoding the parameters, and
    /// `error.PayloadTooLarge` from `Frame.write`.
    pub fn send(self: *const @This(), fd: std.os.linux.fd_t, payload: ?[]const u8) !void {
        var buffer: [Frame.max_payload_len]u8 = undefined;
        const payload_json = try self.encode(&buffer, payload);
        try Frame.write(fd, payload_json);
    }

    /// Formats the result text the manager answers `event` with: `"Event is X"`.
    ///
    /// The returned slice borrows `buffer`.
    ///
    /// Errors: `error.NoSpaceLeft` when `buffer` is too small.
    pub fn responseText(self: *const @This(), buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "Event is {s}", .{@tagName(self.*)});
    }

    /// One event request payload.
    const EventMessage = struct {
        /// Callback that fired.
        event: Event,
        /// Optional JSON text with event-specific parameters. It is transmitted
        /// as a JSON string and borrows the parsed request.
        payload: ?[]const u8 = null,
    };

    /// An event request parsed from a JSON-RPC request.
    ///
    /// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
    const ParsedEvent = struct {
        /// Parsed JSON-RPC request whose method names the event.
        rpc: zjr.RpcRequestResult,
        /// Event extracted from `rpc`.
        value: EventMessage,

        /// Releases the JSON storage owned by `rpc`.
        pub fn deinit(self: *const ParsedEvent) void {
            self.rpc.deinit();
        }

        /// Returns the request ID used for the matching response.
        pub fn id(self: *const ParsedEvent) zjr.RpcId {
            return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNull();
        }
    };
};
