//! Operations the Entrypoint's JSON-RPC listener understands.
//!
//! The plugin-manager child sends these as JSON-RPC notifications whose
//! method name selects the operation; the module owns the method-name
//! mapping in both directions.

const std = @import("std");

/// Operations the Entrypoint's JSON-RPC listener understands.
pub const Operation = enum {
    /// Write `message` to the parent's log sink.
    stderr,
    /// Report that the plugin-manager child finished its load attempt.
    ///
    /// The message is the child's readiness text. The Entrypoint treats its
    /// expected readiness text as success and any other text as a startup
    /// failure.
    ready,

    /// Returns the operation named by a JSON-RPC method, or null.
    pub fn fromMethod(method: []const u8) ?Operation {
        inline for (std.meta.fields(Operation)) |field| {
            if (std.mem.eql(u8, method, field.name)) {
                return @as(Operation, @enumFromInt(field.value));
            }
        }
        return null;
    }
};
