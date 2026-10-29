const std = @import("std");
const zjr = @import("zjr");
const ipc = @import("root").Ipc;

/// In-process JSON-RPC listener used by tests.
///
/// The listener owns an `RpcDispatcher`, registers handlers by method name,
/// and runs requests through ZigJR's `RequestPipeline`. It never opens a
/// socket or starts a subprocess.
pub const MockListener = struct {
    /// Allocator used for the dispatcher, pipeline, and response copy.
    allocator: std.mem.Allocator,
    /// Registered method table. Heap-allocated so its address is stable.
    rpc: *zjr.RpcDispatcher,
    /// ZigJR request pipeline. Heap-allocated so its internal pointers stay
    /// valid for the lifetime of the listener.
    pipeline: *zjr.RequestPipeline,
    /// Stable copy of the most recent response.
    response_buffer: [ipc.max_payload_len]u8 = undefined,
    /// Number of valid bytes in `response_buffer`.
    response_len: usize = 0,

    /// Creates a listener with no handlers.
    ///
    /// Errors: `error.OutOfMemory` when the dispatcher, pipeline, or their
    /// internal allocations cannot be created.
    pub fn init(allocator: std.mem.Allocator) !MockListener {
        const rpc = try allocator.create(zjr.RpcDispatcher);
        errdefer allocator.destroy(rpc);
        rpc.* = try zjr.RpcDispatcher.init(allocator);
        errdefer rpc.deinit();

        const pipeline = try allocator.create(zjr.RequestPipeline);
        errdefer allocator.destroy(pipeline);
        pipeline.* = try zjr.RequestPipeline.init(
            allocator,
            zjr.RequestDispatcher.implBy(rpc),
            null,
        );

        return .{
            .allocator = allocator,
            .rpc = rpc,
            .pipeline = pipeline,
        };
    }

    /// Releases the dispatcher, pipeline, and their allocations.
    pub fn deinit(self: *MockListener) void {
        self.pipeline.deinit();
        self.allocator.destroy(self.pipeline);
        self.rpc.deinit();
        self.allocator.destroy(self.rpc);
    }

    /// Registers `handler_fn` under the JSON-RPC method name `method`.
    ///
    /// Errors are ZigJR's `RegistrationErrors`.
    pub fn register(self: *MockListener, method: []const u8, comptime handler_fn: anytype) !void {
        try self.rpc.add(method, handler_fn);
    }

    /// Processes one JSON-RPC request and returns its response.
    ///
    /// The returned slice borrows `response_buffer` and stays valid until the
    /// next call to `handle` on this listener.
    ///
    /// Errors: ZigJR's pipeline writer errors, `error.EmptyResponse` when the
    /// request was a notification, and `error.PayloadTooLarge` when the
    /// response does not fit the frame buffer.
    pub fn handle(self: *MockListener, request_json: []const u8) ![]const u8 {
        const status = try self.pipeline.runRequest(request_json);
        if (!status.hasReply()) return error.EmptyResponse;

        const response = self.pipeline.responseJson();
        if (response.len > self.response_buffer.len) return error.PayloadTooLarge;
        @memcpy(self.response_buffer[0..response.len], response);
        self.response_len = response.len;
        return self.response_buffer[0..self.response_len];
    }
};

/// In-process JSON-RPC client used by tests.
///
/// The sender composes a request with ZigJR, passes it directly to a
/// `MockListener`, prints both wire messages, and returns the parsed response
/// for assertions.
pub const MockSender = struct {
    /// Allocator for request composition and response parsing.
    allocator: std.mem.Allocator,
    /// Destination for the request. Must outlive the sender.
    listener: *MockListener,

    /// Sends one JSON-RPC request and returns its parsed response.
    ///
    /// `params` must be null, an array-like tuple, or a struct; ZigJR rejects
    /// other parameter types. The returned result owns its parsed JSON until
    /// `deinit()` is called.
    ///
    /// Errors are ZigJR's composition errors, the listener's pipeline errors,
    /// and `error.OutOfMemory` while parsing the response.
    pub fn call(
        self: *MockSender,
        method: []const u8,
        params: anytype,
        id: zjr.RpcId,
    ) !zjr.RpcResponseResult {
        const request_json = try zjr.composer.makeRequestJson(self.allocator, method, params, id);
        defer self.allocator.free(request_json);

        const response_json = try self.listener.handle(request_json);
        return zjr.parseRpcResponseOwned(self.allocator, response_json, .{});
    }
};

/// Adds the two test numbers.
fn mockAddTwoNumbers(a: f64, b: f64) f64 {
    return a + b;
}

/// Message parameter for `mockReadStruct`.
const Message = struct {
    text: []const u8,
};

/// Returns the text carried by `msg`.
fn mockReadStruct(msg: Message) []const u8 {
    return msg.text;
}

test "mock JSON-RPC request/response flow" {
    var listener = try MockListener.init(std.testing.allocator);
    defer listener.deinit();
    try listener.register("mockAddTwoNumbers", mockAddTwoNumbers);
    try listener.register("mockReadStruct", mockReadStruct);

    var sender = MockSender{
        .allocator = std.testing.allocator,
        .listener = &listener,
    };

    var add_response = try sender.call("mockAddTwoNumbers", .{ 2.5, 3.5 }, zjr.RpcId.of(7));
    defer add_response.deinit();
    const add = try add_response.response();
    try std.testing.expect(!add.hasErr());
    try std.testing.expect(add.id.eql(7));
    try std.testing.expect(add.resultEql(@as(f64, 6.0)));
    const add_result = switch (add.result) {
        .float => |value| value,
        .integer => |value| @as(f64, @floatFromInt(value)),
        else => return error.UnexpectedResultType,
    };
    std.debug.print("mockAddTwoNumbers result: {}\n", .{add_result});
    try std.testing.expectEqual(@as(f64, 6.0), add_result);

    var read_response = try sender.call("mockReadStruct", .{ .text = "Hello" }, zjr.RpcId.of(8));
    defer read_response.deinit();
    const read = try read_response.response();
    try std.testing.expect(!read.hasErr());
    try std.testing.expect(read.id.eql(8));
    const read_result = read.result.string;
    std.debug.print("mockReadStruct result: {s}\n", .{read_result});
    try std.testing.expectEqualStrings("Hello", read_result);
}
