//! Confirms which IVEngineServer build is actually running, using *only*
//! the constants EngineIndexesGenerator.zig produced
//! (codegen_generated/engine_indexes.zig) - no separate, hand-maintained
//! table anymore. The old `known_builds` table is gone: it carried its
//! own guessed indices (76/36, 72/34) that were never independently
//! verified and, as it turned out, matched neither the real calibrated
//! values the codegen later produced (72/36) - exactly the kind of
//! silent mismatch this whole project exists to catch instead of ship.
//!
//! Why this only ever checks *one* version string: `Indexes.IVEngineServer`
//! holds exactly one set of vtable indices, computed against whichever
//! single SDK header snapshot produced
//! `Indexes.interfaceversion_vengineserver` (the "current"/unsuffixed
//! constant - see engine_indexes.zig). Those indices are only verified
//! correct for an engine that answers to *that exact string*. The older
//! `interfaceversion_vengineserver_version_21`/`_22` constants the
//! codegen also emits are real version strings a real engine might
//! answer to, but this file has no separate, verified indices for them -
//! it doesn't pretend otherwise by quietly reusing the "023" indices on
//! an "021" engine. They're exposed here purely so a mismatch can be
//! reported specifically ("found VEngineServer021, indices are for
//! VEngineServer023") instead of a bare "unrecognized build".
//!
//! If/when EngineIndexesGenerator.zig starts producing a *separate*
//! index table per version, this file - and the single `Indexes.IVEngineServer`
//! import everything else in this project uses - would need to grow a
//! real per-version lookup. Until then, "the one version these indices
//! are for" is the only thing worth detecting, and `detect` reflects
//! that honestly rather than offering a lookup that doesn't exist yet.
//!
//! I could not compile-check this file myself (no Zig 0.16 toolchain,
//! and no TF2 server to actually probe, available here).

const std = @import("std");
const Indexes = @import("../codegen_generated/engine_indexes.zig");

pub const CreateInterfaceFn = *const fn (name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque;

pub const DetectError = error{UnrecognizedEngineBuild};

pub const Detection = struct {
    engine: *anyopaque,
    /// Always equal to `Indexes.interfaceversion_vengineserver` - `detect`
    /// only ever succeeds by matching exactly that string. Returned
    /// anyway (rather than the caller just using the constant directly)
    /// so a comparison against it reads as a real check on the call
    /// site, not an assumption baked in silently.
    engine_version: []const u8,
};

/// Older, real version strings the codegen also knows the names of -
/// *not* a fallback index source (see the module doc-comment). Checked
/// in roughly newest-first order so a mismatch report names the closest
/// known build first.
const known_older_versions = [_][]const u8{
    Indexes.interfaceversion_vengineserver_version_22,
    Indexes.interfaceversion_vengineserver_version_21,
};

/// Queries the engine for exactly the version `Indexes.IVEngineServer`'s
/// indices were calibrated against. Always safe to call, even against a
/// totally unknown build: it only ever calls CreateInterface itself,
/// nothing derived from a possibly-wrong index - failure here is just
/// `error.UnrecognizedEngineBuild`, never a crash.
pub fn detect(interface_factory: CreateInterfaceFn) DetectError!Detection {
    if (interface_factory(@ptrCast(Indexes.interfaceversion_vengineserver.ptr), null)) |ptr| {
        return .{ .engine = ptr, .engine_version = Indexes.interfaceversion_vengineserver };
    }
    return error.UnrecognizedEngineBuild;
}

/// Diagnostic only, meant to be called after `detect` has already failed:
/// does the engine answer to one of the *older* known version strings
/// instead? Returns that string if so, so a caller can log specifically
/// which older build it found - null means not even one of those
/// matched either, a genuinely unknown build rather than just an older
/// one this project happens to know the name of.
pub fn detectOlderVersion(interface_factory: CreateInterfaceFn) ?[]const u8 {
    for (known_older_versions) |version| {
        if (interface_factory(@ptrCast(version.ptr), null) != null) return version;
    }
    return null;
}
