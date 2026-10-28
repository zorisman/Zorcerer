//! Source model index with the encoded precached/dynamic split.
//!
//! The encoding is documented in `src/public/engine/ivmodelinfo.h:89-99`:
//!
//! - `>= 0`: precached model string-table index.
//! - `-1`: invalid model.
//! - `< -1`: dynamic model, with dynamic index `-2 - value`.
//! - dynamic index odd: client-only model; lookup index is `dynamic >> 1`.
//! - dynamic index even: networked model; string-table index is `dynamic >> 1`.
//!
//! A model index is a value, not a `model_t*`. The index can become stale across
//! a level/model-cache change; re-query or hold a documented engine reference to
//! the model itself.

pub const ModelIndex = extern struct {
    /// Raw `int` model index.
    value: i32,

    /// Returns whether the index is not the `-1` invalid sentinel.
    ///
    /// Dynamic indices below `-1` are valid models.
    pub fn isValid(self: ModelIndex) bool {
        return self.value != -1;
    }

    /// Returns whether the index names a precached model (`>= 0`).
    pub fn isPrecached(self: ModelIndex) bool {
        return self.value >= 0;
    }

    /// Returns whether the index names a dynamic model (`< -1`).
    pub fn isDynamic(self: ModelIndex) bool {
        return self.value < -1;
    }

    /// Returns the dynamic index `(-2 - value)`, or null for a non-dynamic
    /// value, including the invalid `-1` sentinel.
    pub fn dynamicIndex(self: ModelIndex) ?u32 {
        if (!self.isDynamic()) return null;
        return @as(u32, @intCast(-2 - self.value));
    }

    /// Returns whether this is a dynamic client-only model.
    ///
    /// Client-only dynamic models have an odd dynamic index. Precached models
    /// and the invalid sentinel return false.
    pub fn isClientOnly(self: ModelIndex) bool {
        const index = self.dynamicIndex() orelse return false;
        return (index & 1) != 0;
    }
};

comptime {
    if (@sizeOf(ModelIndex) != 4) @compileError("ModelIndex must stay 4 bytes");
}
