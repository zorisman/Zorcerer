const std = @import("std");
const zjr = @import("zjr");
const Frame = @import("Frame.zig");
const Response = @import("Response.zig");
const Identifiers = @import("IdentifierRegistry.zig").Identifiers;

/// Read-only game-state queries a plugin may send to the engine process.
pub const Query = enum {
    /// Server state snapshot: dedicated flag, pause, entity count, version,
    /// uptime, game directory, and current map name.
    server_info,
    /// Engine player identity for one entity index.
    player_info,
    /// Whether an entity index is currently in use.
    entity_exists,
    /// Server cvar lookup by name.
    server_cvar,
    /// One client's cvar value.
    client_cvar,

    /// One game-query request.
    ///
    /// `index` is meaningful for player, entity, and client-cvar queries; `name`
    /// is meaningful for cvar queries. The other field is ignored.
    pub const QueryRequest = struct {
        /// Query to execute.
        query: Query,
        /// Entity or client index, depending on `query`.
        index: c_int = 0,
        /// Cvar name for cvar queries.
        name: []const u8 = "",
    };

    /// A game-query request parsed from a JSON-RPC request.
    ///
    /// `value` borrows the JSON owned by `rpc`; both stay valid until `deinit()`.
    pub const ParsedQuery = struct {
        /// Parsed JSON-RPC request whose method names the query.
        rpc: zjr.RpcRequestResult,
        /// Query extracted from `rpc`.
        value: QueryRequest,

        /// Releases the JSON storage owned by `rpc`.
        pub fn deinit(self: *const ParsedQuery) void {
            self.rpc.deinit();
        }

        /// Returns the request ID used for the matching response.
        pub fn id(self: *const ParsedQuery) zjr.RpcId {
            return if (self.rpc.isRequest()) self.rpc.request_msg.request.id else .ofNone();
        }
    };

    /// Returns the JSON-RPC method name for `query`.
    fn queryMethod(query: Query) [:0]const u8 {
        return switch (query) {
            .server_info => "query.serverInfo",
            .player_info => "query.playerInfo",
            .entity_exists => "query.entityExists",
            .server_cvar => "query.serverCvar",
            .client_cvar => "query.clientCvar",
        };
    }

    /// Returns the query named by a JSON-RPC method, or null.
    fn queryFromMethod(method: []const u8) ?Query {
        if (std.mem.eql(u8, method, queryMethod(.server_info))) return .server_info;
        if (std.mem.eql(u8, method, queryMethod(.player_info))) return .player_info;
        if (std.mem.eql(u8, method, queryMethod(.entity_exists))) return .entity_exists;
        if (std.mem.eql(u8, method, queryMethod(.server_cvar))) return .server_cvar;
        if (std.mem.eql(u8, method, queryMethod(.client_cvar))) return .client_cvar;
        return null;
    }

    /// Parses one JSON-RPC game-query request.
    ///
    /// The method names are `query.serverInfo`, `query.playerInfo`,
    /// `query.entityExists`, `query.serverCvar`, and `query.clientCvar`. Optional
    /// object parameters may carry integer `index` and string `name`.
    ///
    /// Errors: `error.NotRpcRequest` when `text` is a response or batch,
    /// `error.InvalidRpcRequest` for an invalid JSON-RPC envelope,
    /// `error.UnknownMethod` when the method is not a query, and
    /// `error.InvalidParams` when a parameter has the wrong type.
    pub fn parseQuery(allocator: std.mem.Allocator, text: []const u8) !ParsedQuery {
        var rpc = zjr.parseRpcRequest(allocator, text);
        errdefer rpc.deinit();

        if (rpc.isMissingMethod() or !rpc.isRequest()) return error.NotRpcRequest;
        const request = rpc.request_msg.request;
        if (request.hasError()) return error.InvalidRpcRequest;

        const query = queryFromMethod(request.method) orelse return error.UnknownMethod;

        var value = QueryRequest{ .query = query };
        if (request.objectParams()) |params| {
            if (params.get("index")) |index_value| {
                const raw_index = switch (index_value) {
                    .integer => |number| number,
                    else => return error.InvalidParams,
                };
                value.index = std.math.cast(c_int, raw_index) orelse return error.InvalidParams;
            }
            if (params.get("name")) |name_value| {
                value.name = switch (name_value) {
                    .string => |bytes| bytes,
                    else => return error.InvalidParams,
                };
            }
        }

        return .{ .rpc = rpc, .value = value };
    }

    /// Serializes `request` as a JSON-RPC request into `buffer`.
    ///
    /// Uses `Identifiers.query_request_id` so the waiter can match the
    /// response. The returned slice borrows `buffer`.
    ///
    /// Errors: `error.OutOfMemory` while encoding the parameters,
    /// `error.WriteFailed` when the request does not fit `buffer`, and writer
    /// errors from parameter encoding.
    pub fn encodeQuery(buffer: []u8, request: QueryRequest) ![]const u8 {
        var writer: std.Io.Writer = .fixed(buffer);

        const allocator = std.heap.page_allocator;
        const params_json = try std.json.Stringify.valueAlloc(
            allocator,
            .{ .index = request.index, .name = request.name },
            .{},
        );
        defer allocator.free(params_json);

        try zjr.composer.writeRequestJson(
            queryMethod(request.query),
            params_json,
            Identifiers.query_request_id.rpcId(),
            &writer,
        );
        return writer.buffered();
    }

    /// Serializes `request` as a JSON-RPC request and sends it as one frame.
    ///
    /// Precondition: the parent must be listening for child requests, which holds
    /// while it waits for readiness or for an event response.
    ///
    /// Errors: `error.WriteFailed` when the request does not fit the stack buffer
    /// or the write fails, `error.OutOfMemory` while encoding the parameters, and
    /// `error.PayloadTooLarge` from `Frame.write`.
    pub fn sendQuery(fd: std.os.linux.fd_t, request: QueryRequest) !void {
        var buffer: [Frame.max_payload_len]u8 = undefined;
        const payload_json = try encodeQuery(&buffer, request);
        try Frame.write(fd, payload_json);
    }

    /// Reads the parent's response to the in-flight query.
    ///
    /// Returns the result text, which is a JSON document describing the queried
    /// value. The caller owns the returned slice and frees it with `allocator`.
    ///
    /// Errors: framing errors from `Frame.read`; `error.InvalidFrame` when the
    /// marker is missing; `error.EmptyMessage` for an empty payload;
    /// `error.UnexpectedQueryResponse` when the payload is not a single JSON-RPC
    /// response; `error.UnexpectedResponseId` when the response does not answer
    /// `Identifiers.query_request_id`; `error.QueryFailed` when the parent
    /// returned a JSON-RPC error; `error.UnexpectedResultType` when the result is
    /// not a JSON string; and `error.OutOfMemory` when copying the text fails.
    pub fn receiveQueryResult(fd: std.os.linux.fd_t, allocator: std.mem.Allocator) ![]u8 {
        const frame = try Frame.read(fd);
        if (!frame.framed) return error.InvalidFrame;
        if (!frame.received) return error.EmptyMessage;

        var response = Response.parseResponse(allocator, frame.text());
        defer response.deinit();
        const rpc_response = response.value() catch return error.UnexpectedQueryResponse;

        if (!rpc_response.id.eql(@intFromEnum(Identifiers.query_request_id))) return error.UnexpectedResponseId;
        if (rpc_response.hasErr()) return error.QueryFailed;

        return switch (rpc_response.result) {
            .string => |text| allocator.dupe(u8, text),
            else => error.UnexpectedResultType,
        };
    }
};
