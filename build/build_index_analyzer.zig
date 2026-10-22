//! Optional shell-driven build step for VTableIndexAnalyzer.cpp.
//!
//! Import this file from the project's build.zig and call:
//!
//!     @import("build_index_analyzer.zig").addIndexAnalyzer(b);
//!
//! build.zig calls this unconditionally; running the build with
//! `-DSkip-analyzer` skips both this analyzer compilation and the
//! index-extraction invocation driven by DataAdapter.
//!
//! The analyzer is compiled by the system C++ compiler, not Zig's C++
//! frontend. This avoids mixing Zig's default libc++ with system Clang/LLVM
//! packages built against libstdc++.
//!
//! Overrides, if the tools are versioned on your system:
//!
//!     zig build -Dindex-cxx=clang++-21 -Dllvm-config=llvm-config-21
//!     zig build -DSkip-analyzer   # to skip analyzer compilation and index generation
//!
//! A nonzero command status fails the Zig build step. The final compiler is
//! invoked with `exec`, so its status becomes the shell status directly.

//! The reason we use shell script instead of Zig C++ compilation toolchain
//! is because Zig builder always adds linkage to libc++.so instead of libstdc++.so.
//! Even if flags are specified explicitly, and link_cpp = false, Zig builder just ignores it.
//! What causes this behaviour is unknown to me.

const std = @import("std");

pub fn addIndexAnalyzer(b: *std.Build) void {
    const llvm_config = b.option(
        []const u8,
        "llvm-config",
        "Name/path of llvm-config (for example llvm-config-21)",
    ) orelse "llvm-config";

    const cxx = b.option(
        []const u8,
        "index-cxx",
        "Name/path of the system C++ compiler (for example clang++-21)",
    ) orelse "clang++";

    // Positional arguments passed to `sh -c SCRIPT`:
    //   $0 = build-vtable-index-analyzer (shell's command_name)
    //   $1 = input source (tracked by addFileArg)
    //   $2 = llvm-config executable
    //   $3 = system C++ compiler
    //   $4 = output path (tracked by addOutputFileArg)
    const script =
        \\set -eu
        \\set -f
        \\src=$1
        \\llvm_config=$2
        \\cxx=$3
        \\out=$4
        \\
        \\includedir=$("$llvm_config" --includedir)
        \\libdir=$("$llvm_config" --libdir)
        \\llvm_version=$("$llvm_config" --version)
        \\cxxflags=$("$llvm_config" --cxxflags)
        \\ldflags=$("$llvm_config" --ldflags)
        \\llvm_libs=$("$llvm_config" --libs --system-libs)
        \\
        \\printf 'vtable-index-analyzer: compiler: %s\n' "$cxx" >&2
        \\"$cxx" --version >&2
        \\printf 'vtable-index-analyzer: LLVM: %s\n' "$llvm_version" >&2
        \\printf 'vtable-index-analyzer: headers: %s\n' "$includedir" >&2
        \\printf 'vtable-index-analyzer: libraries: %s\n' "$libdir" >&2
        \\printf 'vtable-index-analyzer: output: %s\n' "$out" >&2
        \\
        \\# llvm-config returns space-separated compiler/linker flags. Split these
        \\# strings into arguments intentionally; set -f above disables globbing.
        \\# shellcheck disable=SC2086
        \\exec "$cxx" \
        \\  $cxxflags \
        \\  -stdlib=libstdc++ \
        \\  "$src" \
        \\  $ldflags \
        \\  -Wl,-rpath,"$libdir" \
        \\  -o "$out" \
        \\  -lclang-cpp \
        \\  $llvm_libs
    ;

    const command = b.addSystemCommand(&.{
        "sh",
        "-eu",
        "-c",
        script,
        "build-vtable-index-analyzer",
    });

    command.addFileArg(b.path("build/analyzers/VTableIndexAnalyzer.cpp"));
    command.addArg(llvm_config);
    command.addArg(cxx);
    const analyzer = command.addOutputFileArg("vtable-index-analyzer");
    command.expectExitCode(0);

    const install_file = b.addInstallFileWithDir(
        analyzer,
        .prefix,
        "bin/vtable-index-analyzer",
    );

    b.getInstallStep().dependOn(&install_file.step);
}
