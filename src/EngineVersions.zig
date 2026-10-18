//! Detects which exact IVEngineServer build the running engine actually
//! is, and looks up the matching, independently-verified vtable indices
//! for it - instead of a single hard-coded index that's silently wrong
//! on any other build. "One branch has log_print_index = 72, another has
//! 76" is exactly the problem this solves: CreateInterface requires an
//! *exact* version-string match, so probing which strings the running
//! engine actually answers to tells us which build we're on, and the
//! indices for each *known* build come from a maintained table, not a
//! single guess that quietly stops matching reality the moment you
//! connect to a different branch.
//!
//! What this can't do: fully automatic, headerless discovery of a
//! correct index *for a build nobody has calibrated yet*. There's no
//! safe way to derive "where is LogPrint in this vtable" from pure
//! runtime probing alone, short of actually calling unknown function
//! pointers with guessed arguments and seeing what happens - which is
//! exactly the risk this table exists to avoid, not something to
//! reintroduce as an automatic "best guess" fallback. A new build's row
//! has to be calibrated once, deliberately, against that build's own
//! matching SDK headers - see "Adding a new entry" below. This file's
//! job is to make sure the plugin only ever *uses* a mapping that was
//! actually verified for the engine it's actually running against, and
//! refuses outright otherwise - loudly and safely, instead of silently
//! hooking the wrong slot and crashing later the way the original
//! hard-coded version did.
//!
//! Adding a new entry (calibration): compile engine_adapter.cpp against
//! the hl2sdk-tf2 checkout matching the new build, and call
//! EngineAdapter_EngineInterfaceVersion() / EngineAdapter_LogPrintIndex()
//! / EngineAdapter_ServerCommandIndex() once to get the three values for
//! *that* build - a tiny one-off plugin that just logs them and exits is
//! enough, you don't need the whole loader for this. Add the result as a
//! new `KnownBuild` row below. From then on, every plugin using this
//! table recognizes that build automatically, without engine_adapter.cpp
//! needing to be recompiled or even present at runtime.
//!
//! I could not compile-check this file myself (no Zig 0.16 toolchain, and
//! no TF2 server to actually probe, available here).

const std = @import("std");

pub const CreateInterfaceFn = *const fn (name: [*:0]const u8, return_code: ?*c_int) callconv(.c) ?*anyopaque;

pub const KnownBuild = struct {
    /// Exact IVEngineServer version string this row was calibrated
    /// against, e.g. "VEngineServer022".
    engine_version: [:0]const u8,
    log_print_index: usize,
    server_command_index: usize,
};

/// Calibrated entries, newest first. Order matters for one reason: if a
/// running engine happens to answer to more than one of these at once -
/// plausible, since engines often keep an old version string mapped to a
/// still-compatible interface for backward compatibility - `detect`
/// returns the *first* match, so putting newer/more-specific rows first
/// means a modern engine gets its own real entry rather than an older,
/// merely-compatible one.
///
/// *** These two rows are placeholders illustrating the shape of the
/// table, carried over from numbers earlier files in this project used -
/// NEITHER has been independently re-verified against a real running
/// server since engine_adapter.cpp was written. Treat them as examples
/// to replace via real calibration, not as trustworthy out of the box.
/// See "Adding a new entry" above. ***
pub const known_builds = [_]KnownBuild{
    .{ .engine_version = "VEngineServer022", .log_print_index = 76, .server_command_index = 36 },
    .{ .engine_version = "VEngineServer021", .log_print_index = 72, .server_command_index = 34 },
};

pub const DetectError = error{UnrecognizedEngineBuild};

pub const Detection = struct {
    build: KnownBuild,
    engine: *anyopaque,
};

/// Probes `known_builds` (in table order) against the engine's own
/// CreateInterface and returns the first one it actually answers to,
/// along with the resolved interface pointer (so the caller doesn't need
/// a second CreateInterface call for the same thing). Calling this is
/// always safe, even against a totally unknown build: it only ever calls
/// CreateInterface itself, nothing derived from a possibly-wrong index -
/// an unrecognized build just gets `error.UnrecognizedEngineBuild`, never
/// a crash.
pub fn detect(interface_factory: CreateInterfaceFn) DetectError!Detection {
    for (known_builds) |build| {
        if (interface_factory(build.engine_version, null)) |ptr| {
            return .{ .build = build, .engine = ptr };
        }
    }
    return error.UnrecognizedEngineBuild;
}
