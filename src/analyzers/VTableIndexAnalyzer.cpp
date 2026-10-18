// Compile-time vtable index analyzer, separate from VTableResolver.zig
// (which resolves addresses at runtime, against an already-loaded,
// already-running engine). This tool never runs any engine code at all -
// it parses an SDK header's AST and asks Clang's own vtable-layout logic
// (clang::ItaniumVTableContext - the exact code Clang uses to generate
// real vtables) where a given virtual method would land. That's the
// point of going through Clang instead of hand-counting `virtual`
// declarations by eye: overrides, inherited methods, and the two-slot
// pair a virtual destructor reserves are all handled by the same logic
// the compiler itself relies on, not reimplemented here.
//
// This is meant to feed EngineVersions.zig's calibrated table: run it
// once per SDK checkout/branch you want to support, and add the reported
// indices (together with that branch's real IVEngineServer version
// string) as a new row there.
//
// Usage:
//   vtable-index-analyzer <header.h> <ClassName> <method1|*> [method2 ...] -- <compiler args...>
//
// Example, for TF2's hl2sdk-tf2 checkout:
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h IVEngineServer \
//       LogPrint ServerCommand -- \
//       -I hl2sdk-tf2/public -I hl2sdk-tf2/public/engine -I hl2sdk-tf2/public/tier1 \
//       -DCOMPILER_GCC -DPOSIX -D_LINUX -DGNUC -std=gnu++14 -m32
//
// *** The compiler args after `--` carry the exact same risk engine_adapter.cpp
// already flagged ***: eiface.h pulls in a real dependency tree
// (KeyValues, CUtlVector, edict_t, ...), and the SDK headers are
// sensitive to the same COMPILER_GCC/POSIX/_LINUX-style defines Valve's
// own build uses - check hl2sdk-tf2's own CMakeLists.txt/premake5.lua for
// the exact set your checkout expects, the same way you would to compile
// engine_adapter.cpp itself. Getting a define wrong here can shift a
// struct's layout behind an #ifdef exactly the same way it could there -
// this tool resolving successfully and printing a number is not by
// itself proof that number is right if the headers were parsed under the
// wrong defines for the branch you actually care about.
//
// Scope: single inheritance only. Multiple or virtual inheritance in
// Source SDK interfaces is rare (IVEngineServer/IServerGameDLL are
// simple, single-base interfaces), but this tool warns rather than
// silently producing a possibly-wrong index if it sees either on the
// class you asked about - treat a warning as "verify this one a
// different way" (e.g. engine_adapter.cpp's runtime pointer-to-member
// trick against a real build), not as a number to trust as-is.
//
// *** UNVERIFIED - I could not build or run this myself ***
// No Clang/LLVM development headers or libraries are available in this
// environment, so none of this has been compiled, let alone run against
// a real SDK checkout. The riskiest API surface, if something doesn't
// build: `clang::tooling::buildASTFromCodeWithArgs`'s exact signature and
// `ItaniumVTableContext`'s constructor have both shifted shape across
// LLVM releases historically - if compilation fails there specifically,
// check your installed Clang/LLVM version's own
// clang/Tooling/Tooling.h and clang/AST/VTableBuilder.h for the current
// signatures; the AST-walking logic (RecursiveASTVisitor, looking up a
// named virtual method, calling getMethodVTableIndex) is much less
// likely to have changed and is the part actually worth trusting here.

#include "clang/AST/ASTConsumer.h"
#include "clang/AST/ASTContext.h"
#include "clang/AST/RecursiveASTVisitor.h"
#include "clang/AST/VTableBuilder.h"
#include "clang/Tooling/Tooling.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

using namespace clang;

namespace {

struct Query {
    std::string className;
    std::vector<std::string> methodNames;
};

const CXXMethodDecl *findVirtualMethod(const CXXRecordDecl *RD, const std::string &name) {
    DeclarationName DN(&RD->getASTContext().Idents.get(name));
    for (const auto *D : RD->lookup(DN)) {
        if (const auto *M = dyn_cast<CXXMethodDecl>(D)) {
            if (M->isVirtual())
                return M;
        }
    }
    return nullptr;
}

class IndexVisitor : public RecursiveASTVisitor<IndexVisitor> {
public:
    IndexVisitor(ASTContext &Context, const Query &Q) : Context(Context), Q(Q) {}

    bool VisitCXXRecordDecl(CXXRecordDecl *RD) {
        if (!RD->isCompleteDefinition())
            return true;
        if (RD->getQualifiedNameAsString() != Q.className && RD->getNameAsString() != Q.className)
            return true;

        found = true;

        if (RD->getNumBases() > 1 || RD->getNumVBases() > 0) {
            llvm::errs() << "warning: " << Q.className
                         << " uses multiple or virtual inheritance - this tool "
                            "only reliably handles single inheritance. Verify "
                            "these indices another way (e.g. engine_adapter.cpp's "
                            "runtime pointer-to-member trick against a real "
                            "build) before trusting them.\n";
        }

        ItaniumVTableContext VTContext(Context);

        // A single "*" requests all callable method slots in the selected
        // class's primary vtable, including inherited methods and destructor
        // variants. VTableLayout indices are relative to the address point,
        // matching getMethodVTableIndex()'s index convention.
        if (Q.methodNames.size() == 1 && Q.methodNames.front() == "*") {
            const VTableLayout &Layout = VTContext.getVTableLayout(RD);
            const auto AddressPoint =
                Layout.getAddressPoint(BaseSubobject(RD, CharUnits::Zero()));
            const auto Components = Layout.vtable_components();
            const std::size_t VTableStart =
                Layout.getVTableOffset(AddressPoint.VTableIndex);
            const std::size_t VTableEnd =
                VTableStart + Layout.getVTableSize(AddressPoint.VTableIndex);

            if (AddressPoint.AddressPointIndex < VTableStart ||
                AddressPoint.AddressPointIndex >= VTableEnd) {
                llvm::errs() << "error: invalid vtable address point for "
                             << Q.className << "\n";
                fatal_error = true;
                return true;
            }

            for (std::size_t componentIndex = AddressPoint.AddressPointIndex;
                 componentIndex < VTableEnd; ++componentIndex) {
                const VTableComponent &Component = Components[componentIndex];
                // Exclude ABI metadata (including RTTI) and unused slots.
                if (!Component.isUsedFunctionPointerKind())
                    continue;

                const CXXMethodDecl *Method = Component.getFunctionDecl();
                const uint64_t SlotIndex =
                    componentIndex - AddressPoint.AddressPointIndex;
                llvm::outs() << Q.className << "::" << Method->getNameAsString()
                             << " = " << SlotIndex;
                if (Component.getKind() == VTableComponent::CK_CompleteDtorPointer) {
                    llvm::outs() << "  (complete destructor)";
                } else if (Component.getKind() == VTableComponent::CK_DeletingDtorPointer) {
                    llvm::outs() << "  (deleting destructor)";
                }
                llvm::outs() << "\n";
            }
        } else {
          for (const auto &methodName : Q.methodNames) {
            const CXXMethodDecl *target = findVirtualMethod(RD, methodName);
            if (!target) {
              llvm::errs() << "error: no virtual method named '" << methodName
                << "' found on or inherited into " << Q.className << "\n";
              continue;
            }

            GlobalDecl GD;
            bool isDtor = false;
            if (const auto *dtor = dyn_cast<CXXDestructorDecl>(target)) {
              // Dtor_Complete (D1) is the first of the pair; the
              // deleting destructor (D0) occupies the slot right after
              // it in a standard Itanium layout - see the warning
              // printed below. If your SDK build somehow disagrees
              // with that adjacency assumption, query Dtor_Deleting
              // explicitly instead of assuming "+1".
              GD = GlobalDecl(dtor, Dtor_Complete);
              isDtor = true;
            } else {
              GD = GlobalDecl(target);
            }

            uint64_t index = VTContext.getMethodVTableIndex(GD);
            llvm::outs() << Q.className << "::" << methodName << " = " << index;
            if (isDtor) {
              llvm::outs() << "  (virtual destructor: also reserves the next "
                "slot, "
                << (index + 1) << ", for the deleting-destructor variant)";
            }
            llvm::outs() << "\n";
          }
        }

        return true;
    }

    bool found = false;
    bool fatal_error = false;

private:
    ASTContext &Context;
    const Query &Q;
};

} // namespace

int main(int argc, char **argv) {
    // Deliberately plain argv handling rather than
    // clang::tooling::CommonOptionsParser: that helper's own API
    // (CommonOptionsParser::create returning llvm::Expected, vs. older
    // constructor-based forms) has changed shape across LLVM releases
    // more than the lower-level pieces this tool actually depends on.
    if (argc < 4) {
        llvm::errs() << "usage: vtable-index-analyzer <header.h> <ClassName> "
                         "<method1|*> [method2 ...] -- <compiler args...>\n";
        return 2;
    }

    const std::string headerPath = argv[1];
    Query Q;
    Q.className = argv[2];

    std::vector<std::string> extraArgs;
    int i = 3;
    for (; i < argc; ++i) {
        if (std::string(argv[i]) == "--") {
            ++i;
            break;
        }
        Q.methodNames.push_back(argv[i]);
    }
    for (; i < argc; ++i) {
        extraArgs.push_back(argv[i]);
    }

    if (Q.methodNames.empty()) {
        llvm::errs() << "error: no method names given\n";
        return 2;
    }
    const bool hasWildcard =
        std::find(Q.methodNames.begin(), Q.methodNames.end(), "*") != Q.methodNames.end();
    if (hasWildcard && Q.methodNames.size() != 1) {
        llvm::errs() << "error: '*' must be the only method selector\n";
        return 2;
    }

    {
        std::ifstream probe(headerPath);
        if (!probe) {
            llvm::errs() << "error: couldn't open " << headerPath << "\n";
            return 2;
        }
    }

    // #include the real header (rather than feeding its text directly as
    // the "file") so any relative #includes inside it resolve normally,
    // the same as if you'd written `#include "eiface.h"` in an ordinary
    // .cpp file.
    const std::string code = "#include \"" + headerPath + "\"\n";

    std::unique_ptr<ASTUnit> AST =
        clang::tooling::buildASTFromCodeWithArgs(code, extraArgs, "vtable_index_analyzer_input.cpp");
    if (!AST) {
        llvm::errs() << "error: failed to parse (see diagnostics above)\n";
        return 1;
    }

    IndexVisitor Visitor(AST->getASTContext(), Q);
    Visitor.TraverseDecl(AST->getASTContext().getTranslationUnitDecl());

    if (!Visitor.found) {
        llvm::errs() << "error: class '" << Q.className
                     << "' (as a complete definition) was never found while "
                        "parsing this header and its includes\n";
        return 1;
    }
    if (Visitor.fatal_error)
        return 1;

    return 0;
}
