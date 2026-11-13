//! Parsed JSON-RPC responses received over the IPC channel.
//!
//! Both endpoints use this module to decode the response side of a
//! synchronous exchange.

const std = @import("std");
const zjr = @import("zjr");

/// A JSON-RPC response parsed from one IPC payload.
///
/// `rpc` owns the parsed JSON until `deinit()`.
pub const ParsedResponse = struct {
    /// Parsed JSON-RPC response.
    rpc: zjr.RpcResponseResult,

    /// Releases the JSON storage owned by `rpc`.
    pub fn deinit(self: *ParsedResponse) void {
        self.rpc.deinit();
    }

    /// Returns the single response inside `rpc`.
    ///
    /// Errors: `error.NotSingleRpcResponse` for a batch or empty response.
    pub fn value(self: *ParsedResponse) !zjr.RpcResponse {
        return self.rpc.response();
    }
};

/// Parses one JSON-RPC response payload.
///
/// The returned value owns the parsed JSON until `deinit()`.
pub fn parseResponse(allocator: std.mem.Allocator, text: []const u8) ParsedResponse {
    return .{ .rpc = zjr.parseRpcResponse(allocator, text) };
}
