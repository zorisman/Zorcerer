// Thin C adapter over the real Source SDK C++ interfaces, so the Zig side
// never has to guess a vtable slot index or an interface version string by
// hand - the compiler resolves both from the real class declaration.
//
// Build this against the *actual* hl2sdk-tf2 headers for the engine build
// you're targeting (https://github.com/alliedmodders/hl2sdk-tf2). The
// whole point of this file is that correctness now depends on "did I
// compile against the right SDK checkout" instead of "did I count virtual
// methods correctly by eye" - which is a real, but much more mechanical
// and checkable, dependency. Two things to watch for, since I don't have
// that checkout or your build setup in front of me to verify against:
//   - eiface.h pulls in a fair dependency tree (KeyValues, CUtlVector,
//     edict_t, ...); getting the include paths right can take some
//     iterating the first time.
//   - the SDK's headers are sensitive to the same compiler defines Valve's
//     own build scripts use (COMPILER_GCC, POSIX, GNUC, _LINUX, and
//     friends) - check hl2sdk-tf2's own CMakeLists.txt/premake5.lua for
//     the exact set your checkout expects. A missing define can silently
//     change a struct's layout via an #ifdef'd member, which would be a
//     *new*, different way to get a wrong offset - just one the compiler
//     derives consistently instead of one I counted by hand.
//
// Compile as 32-bit (the TF2 server architecture confirmed from the crash
// dump) and link the resulting object file into the same shared library
// as the Zig code (e.g. via build.zig's addCSourceFile + linkLibCpp).

#include "eiface.h"     // IVEngineServer
#include "interface.h"  // CreateInterfaceFn

#include <cstddef>
#include <cstdint>

namespace {

// Itanium C++ ABI: a pointer-to-member-function for a *virtual* method
// stores (vtable_byte_offset + 1) in its "ptr" field instead of a real
// function address (ordinary function addresses are always even/aligned,
// so the low bit is free to use as a discriminator between "this is a
// direct address" and "this is a vtable offset"). Dividing that byte
// offset by the pointer size gives the plain slot index - derived by the
// compiler from the real class layout, not counted from a wiki page.
//
// This relies on GCC/Clang's implementation of the Itanium ABI rather
// than anything the C++ standard itself guarantees, and isn't portable to
// MSVC - but that's exactly the target here (Linux, GCC/Clang), and this
// specific technique is long-established and widely relied upon for
// exactly this purpose.
template <typename PMF>
std::size_t VirtualIndexOf(PMF pmf) {
  union {
    PMF as_pmf;
    struct {
      std::uintptr_t ptr;
      std::ptrdiff_t adj;
    } as_raw;
  } u;
  u.as_pmf = pmf;
  return static_cast<std::size_t>((u.as_raw.ptr - 1) / sizeof(void*));
}

} // namespace

extern "C" {

// ---- IVEngineServer: calling in ----
// Each of these is a one-line forward to the real virtual call; the
// compiler picks the right vtable slot, same as it would for any other
// C++ caller.

void EngineAdapter_LogPrint(IVEngineServer* engine, const char* msg) {
    engine->LogPrint(msg);
}

void EngineAdapter_ServerCommand(IVEngineServer* engine, const char* cmd) {
    engine->ServerCommand(cmd);
}

void EngineAdapter_ServerExecute(IVEngineServer* engine) {
    engine->ServerExecute();
}

// ---- IVEngineServer: real vtable indices, for VTableHooks ----
// Call these once (e.g. from TF2EngineDemo.install) instead of hard-coding
// an index - see VirtualIndexOf above for how this is derived.

std::size_t EngineAdapter_LogPrintIndex() {
    return VirtualIndexOf(&IVEngineServer::LogPrint);
}

std::size_t EngineAdapter_ServerCommandIndex() {
    return VirtualIndexOf(&IVEngineServer::ServerCommand);
}

// ---- Interface version strings, straight from the SDK's own macros ----
// Whatever INTERFACEVERSION_VENGINESERVER actually expands to in *your*
// checkout, correct for the engine build you compiled against - nothing
// to keep in sync by hand on the Zig side anymore.

const char* EngineAdapter_EngineInterfaceVersion() {
    return INTERFACEVERSION_VENGINESERVER;
}

} // extern "C"
