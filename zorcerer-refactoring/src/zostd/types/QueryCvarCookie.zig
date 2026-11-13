//! Asynchronous client-cvar query cookie (`QueryCvarCookie_t`).
//!
//! `QueryCvarCookie_t` is `int` and `InvalidQueryCvarCookie` is -1
//! (`src/public/engine/iserverplugin.h:43-44`). `StartQueryCvarValue` returns a
//! cookie that is later matched against `OnQueryCvarValueFinished`
//! (`:110-113,153-160`).
//!
//! The interface declares no cancel method. Keep a cookie valid until the
//! matching callback arrives or the query is explicitly abandoned; do not reuse
//! a cookie while the old query may still complete. A cookie is a value, not a
//! pointer or an entity identity.

pub const QueryCvarCookie = extern struct {
    /// Raw cookie value returned by `StartQueryCvarValue`.
    value: i32,

    /// `InvalidQueryCvarCookie`.
    pub const invalid: QueryCvarCookie = .{ .value = -1 };

    /// Returns whether the cookie is not the invalid sentinel.
    pub fn isValid(self: QueryCvarCookie) bool {
        return self.value != invalid.value;
    }
};

comptime {
    if (@sizeOf(QueryCvarCookie) != 4) @compileError("QueryCvarCookie must stay 4 bytes");
}
