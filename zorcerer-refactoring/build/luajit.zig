//! Build integration for the vendored LuaJIT sources in `extern/LuaJIT`.
//!
//! LuaJIT is not a single C file: its build normally runs two host tools,
//! `minilua` and `buildvm`, to generate `luajit.h`, the architecture backend
//! for `buildvm`, the VM assembly, and the library definition headers. This
//! module reproduces that pipeline with Zig build steps so the project does
//! not depend on a system `make`, a prebuilt LuaJIT, or writes into the
//! read-only `extern` checkout.
//!
//! The current prototype supports the project's default x86_64 Linux target
//! only. Other targets need their own DynASM flags and generated assembly
//! mode.

const std = @import("std");

/// The artifacts needed to use LuaJIT from Zig.
pub const LuaJit = struct {
    /// Static LuaJIT archive that must be linked into any final artifact that
    /// calls the Lua C API.
    library: *std.Build.Step.Compile,

    /// C import module exposed to `zig-luajit` as its `c` import. It contains
    /// the public Lua, auxiliary, and standard-library declarations.
    c_module: *std.Build.Module,
};

/// Adds the LuaJIT build graph and returns its static library and C module.
///
/// `target` and `optimize` describe the final artifact. Host tools are always
/// built for the build host because they run during the build.
///
/// Errors: propagates allocator failures from the build graph construction.
pub fn addLuaJit(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !LuaJit {
    if (target.result.cpu.arch != .x86_64 or target.result.os.tag != .linux) {
        @panic("the vendored LuaJIT prototype currently supports x86_64-linux only");
    }

    const source_root = b.path("extern/LuaJIT/src");
    const host_target = b.graph.host;

    // Flags shared by the target C sources. PIC is required because Zorcerer
    // is a shared library; the same objects are also used by the test runner.
    // LuaJIT's C code intentionally performs some out-of-range float-to-int
    // conversions while probing numeric table keys, then checks the round
    // trip. Zig's Debug C compilation enables undefined-behaviour sanitizing
    // for such casts, so disable it for the vendored C sources just like a
    // normal LuaJIT build does.
    const target_c_flags = &.{
        "-std=gnu99",
        "-DLUAJIT_TARGET=LUAJIT_ARCH_X64",
        "-DLUAJIT_OS=LUAJIT_OS_LINUX",
        "-DLUAJIT_UNWIND_EXTERNAL",
        "-fPIC",
        "-funwind-tables",
        "-O2",
        "-fomit-frame-pointer",
        "-fno-sanitize=all",
    };

    const host_c_flags = &.{
        "-std=gnu99",
        "-DLUAJIT_TARGET=LUAJIT_ARCH_X64",
        "-DLUAJIT_OS=LUAJIT_OS_LINUX",
        "-fno-sanitize=all",
    };

    const minilua = b.addExecutable(.{
        .name = "zlua-minilua",
        .root_module = b.createModule(.{
            .target = host_target,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    minilua.root_module.addCSourceFile(.{
        .file = b.path("extern/LuaJIT/src/host/minilua.c"),
        .flags = host_c_flags,
    });
    minilua.root_module.addIncludePath(source_root);
    minilua.root_module.linkSystemLibrary("m", .{});

    // `luajit.h` is normally generated from the rolling header and the
    // repository revision. A fixed numeric revision keeps the build
    // reproducible and avoids invoking git from the build graph.
    const relver = b.addWriteFiles().add("luajit_relver.txt", "0\n");
    const version = b.addRunArtifact(minilua);
    version.addFileArg(b.path("extern/LuaJIT/src/host/genversion.lua"));
    version.addFileArg(b.path("extern/LuaJIT/src/luajit_rolling.h"));
    version.addFileArg(relver);
    const luajit_h = version.addOutputFileArg("luajit.h");

    // DynASM turns the x64 VM description into the C header embedded by
    // `buildvm`.
    const dynasm = b.addRunArtifact(minilua);
    dynasm.addFileArg(b.path("extern/LuaJIT/dynasm/dynasm.lua"));
    dynasm.addArgs(&.{
        "-D", "ENDIAN_LE",
        "-D", "P64",
        "-D", "JIT",
        "-D", "FFI",
        "-D", "FPU",
        "-D", "HFABI",
        "-D", "VER=0",
        "-o",
    });
    const buildvm_arch_h = dynasm.addOutputFileArg("buildvm_arch.h");
    dynasm.addFileArg(b.path("extern/LuaJIT/src/vm_x64.dasc"));

    const buildvm = b.addExecutable(.{
        .name = "zlua-buildvm",
        .root_module = b.createModule(.{
            .target = host_target,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    const buildvm_sources = [_][]const u8{
        "extern/LuaJIT/src/host/buildvm.c",
        "extern/LuaJIT/src/host/buildvm_asm.c",
        "extern/LuaJIT/src/host/buildvm_peobj.c",
        "extern/LuaJIT/src/host/buildvm_lib.c",
        "extern/LuaJIT/src/host/buildvm_fold.c",
    };
    for (buildvm_sources) |source| {
        buildvm.root_module.addCSourceFile(.{
            .file = b.path(source),
            .flags = host_c_flags,
        });
    }
    buildvm.root_module.addIncludePath(source_root);
    buildvm.root_module.addIncludePath(buildvm_arch_h.dirname());
    buildvm.root_module.addIncludePath(luajit_h.dirname());
    buildvm.root_module.linkSystemLibrary("m", .{});
    buildvm.step.dependOn(&version.step);
    buildvm.step.dependOn(&dynasm.step);

    const library_sources = [_][]const u8{
        "extern/LuaJIT/src/lib_base.c",
        "extern/LuaJIT/src/lib_math.c",
        "extern/LuaJIT/src/lib_bit.c",
        "extern/LuaJIT/src/lib_string.c",
        "extern/LuaJIT/src/lib_table.c",
        "extern/LuaJIT/src/lib_io.c",
        "extern/LuaJIT/src/lib_os.c",
        "extern/LuaJIT/src/lib_package.c",
        "extern/LuaJIT/src/lib_debug.c",
        "extern/LuaJIT/src/lib_jit.c",
        "extern/LuaJIT/src/lib_ffi.c",
        "extern/LuaJIT/src/lib_buffer.c",
    };

    var generated_steps: std.ArrayListUnmanaged(*std.Build.Step) = .empty;
    defer generated_steps.deinit(b.allocator);
    try generated_steps.append(b.allocator, &version.step);
    try generated_steps.append(b.allocator, &dynasm.step);

    var generated_include_dirs: std.ArrayListUnmanaged(std.Build.LazyPath) = .empty;
    defer generated_include_dirs.deinit(b.allocator);

    const definition_headers = [_]struct {
        mode: []const u8,
        file_name: []const u8,
    }{
        .{ .mode = "bcdef", .file_name = "lj_bcdef.h" },
        .{ .mode = "ffdef", .file_name = "lj_ffdef.h" },
        .{ .mode = "libdef", .file_name = "lj_libdef.h" },
        .{ .mode = "recdef", .file_name = "lj_recdef.h" },
    };
    for (definition_headers) |header| {
        const run = b.addRunArtifact(buildvm);
        run.addArgs(&.{ "-m", header.mode, "-o" });
        const output = run.addOutputFileArg(header.file_name);
        for (library_sources) |source| {
            run.addFileArg(b.path(source));
        }
        try generated_steps.append(b.allocator, &run.step);
        try generated_include_dirs.append(b.allocator, output.dirname());
    }

    const folddef = b.addRunArtifact(buildvm);
    folddef.addArgs(&.{ "-m", "folddef", "-o" });
    const folddef_output = folddef.addOutputFileArg("lj_folddef.h");
    folddef.addFileArg(b.path("extern/LuaJIT/src/lj_opt_fold.c"));
    try generated_steps.append(b.allocator, &folddef.step);
    try generated_include_dirs.append(b.allocator, folddef_output.dirname());

    const vm_assembly = b.addRunArtifact(buildvm);
    vm_assembly.addArgs(&.{ "-m", "elfasm", "-o" });
    const vm_assembly_output = vm_assembly.addOutputFileArg("lj_vm.S");
    try generated_steps.append(b.allocator, &vm_assembly.step);

    const luajit_c = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    luajit_c.addIncludePath(source_root);
    luajit_c.addIncludePath(luajit_h.dirname());
    for (generated_include_dirs.items) |include_dir| {
        luajit_c.addIncludePath(include_dir);
    }
    luajit_c.addCSourceFile(.{
        .file = b.path("extern/LuaJIT/src/ljamalg.c"),
        .flags = target_c_flags,
    });
    luajit_c.addAssemblyFile(vm_assembly_output);
    luajit_c.linkSystemLibrary("m", .{});
    // LuaJIT's external unwinder calls into the GCC unwinder. Zig's default
    // glibc link does not pull libgcc_s in on its own.
    luajit_c.linkSystemLibrary("gcc_s", .{});

    const library = b.addLibrary(.{
        .name = "luajit",
        .linkage = .static,
        .root_module = luajit_c,
    });
    for (generated_steps.items) |step| {
        library.step.dependOn(step);
    }

    const c_module = b.createModule(.{
        .root_source_file = b.path("src/zlua/luajit_c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    c_module.addIncludePath(source_root);

    return .{
        .library = library,
        .c_module = c_module,
    };
}
