//! Opaque `string_t` token.
//!
//! Source selects the representation of `string_t` at compile time
//! (`src/public/string_t.h:17-111`):
//!
//! - `WEAK_STRING_T`: a 32-bit integer/pointer-sized offset.
//! - neither define: a strong struct holding one `const char*` (pointer-sized).
//! - `NO_STRING_T`: a raw `const char*` (pointer-sized).
//!
//! The SDK server VPCs inspected for this project define neither mode, so the
//! header selects the strong form; the client VPC defines `NO_STRING_T`. The
//! deployed TF2 server's mode is a binary question. This type therefore stores
//! pointer-sized raw bits and deliberately has no size assertion.
//!
//! In the strong form, equality is pointer identity, not text equality
//! (`src/public/string_t.h:55-58`). `ToCStr()` returns a transient pointer that
//! must not be stored (`:80-85`). Decode or copy text through the host with an
//! explicit lifetime; never treat `bits` as a Zig slice.

pub const StringToken = extern struct {
    /// Raw token bits, matching the target build's `string_t` representation.
    bits: usize,

    /// Returns whether the token is the null/empty-string token.
    ///
    /// All three `string_t` modes use a zero bit pattern for the empty token.
    pub fn isNull(self: StringToken) bool {
        return self.bits == 0;
    }

    /// Compares token identity, not text.
    ///
    /// Two tokens with identical text may compare unequal in strong mode when
    /// they point at different copies.
    pub fn eql(self: StringToken, other: StringToken) bool {
        return self.bits == other.bits;
    }
};
