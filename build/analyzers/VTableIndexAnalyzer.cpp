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
//   vtable-index-analyzer <header.h> <ClassName> <method1|*> [method2 ...] [--write-into <file.toml>] -- <compiler args...>
//   vtable-index-analyzer '{{<header.h> <ClassName> <method...>}, {<header.h> const! <macro|*>}}' [--write-into <file.toml>] -- <compiler args...>
//   Use const! instead of a class name to inspect object-like #define constants.
//
// Example, for TF2's hl2sdk-tf2 checkout:
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h IVEngineServer \
//       LogPrint ServerCommand -- \
//       -I hl2sdk-tf2/public -I hl2sdk-tf2/public/engine -I hl2sdk-tf2/public/tier1 \
//       -DCOMPILER_GCC -DPOSIX -D_LINUX -DGNUC -std=gnu++14 -m32
//
// Constants defined directly in the requested header:
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h const! \
//       INTERFACEVERSION_VENGINESERVER INTERFACEVERSION_VENGINESERVER_INT -- \
//       -I hl2sdk-tf2/public -I hl2sdk-tf2/public/engine -I hl2sdk-tf2/public/tier1 \
//       -DCOMPILER_GCC -DPOSIX -D_LINUX -DGNUC -std=gnu++14 -m32
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h const! '*' -- <compiler args...>
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
#include "clang/Lex/MacroInfo.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Tooling/Tooling.h"
#include "llvm/Support/raw_ostream.h"
#include "toml.hpp"

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
    std::string headerPath;
    std::string className;
    std::vector<std::string> methodNames;
    std::string writeIntoPath;
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
    IndexVisitor(ASTContext &Context, const Query &Q, std::ostream *Output)
        : Context(Context), Q(Q), Output(Output) {}

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
                writeTomlEntry(Method->getNameAsString(), SlotIndex, true);
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
            writeTomlEntry(methodName, index, false);
          }
        }

        return true;
    }

    bool processMacros(Preprocessor &PP, const SourceManager &SM) {
        const bool AllMacros = Q.methodNames.size() == 1 && Q.methodNames.front() == "*";
        std::vector<std::string> FoundNames;

        for (const auto &Entry : PP.macros(false)) {
            const IdentifierInfo *Identifier = Entry.first;
            const MacroInfo *MI = PP.getMacroInfo(Identifier);
            if (MI == nullptr || MI->isFunctionLike() || MI->isBuiltinMacro() ||
                MI->tokens_empty() ||
                !definitionIsInHeader(SM, MI->getDefinitionLoc(), Q.headerPath))
                continue;

            const std::string Name = Identifier->getName().str();
            if (!AllMacros && std::find(Q.methodNames.begin(), Q.methodNames.end(), Name) ==
                                  Q.methodNames.end())
                continue;

            const std::string Value = macroValueAsToml(PP, *MI);
            writeTomlEntryValue(Name, Value, true, std::to_string(FoundNames.size()));
            llvm::outs() << Q.headerPath << "::" << Name << " = " << Value << '\n';
            FoundNames.push_back(Name);
        }

        if (!AllMacros) {
            for (const std::string &Requested : Q.methodNames) {
                if (std::find(FoundNames.begin(), FoundNames.end(), Requested) == FoundNames.end()) {
                    llvm::errs() << "error: no object-like macro named '" << Requested
                                 << "' defined in " << Q.headerPath << "\n";
                    return false;
                }
            }
        } else if (FoundNames.empty()) {
            llvm::errs() << "error: no object-like macros found in " << Q.headerPath << "\n";
            return false;
        }
        return true;
    }

    bool found = false;
    bool fatal_error = false;

private:
    static bool definitionIsInHeader(const SourceManager &SM, SourceLocation Loc,
                                     const std::string &HeaderPath) {
        const std::string DefinitionPath = SM.getFilename(Loc).str();
        if (DefinitionPath == HeaderPath)
            return true;
        // Clang may report a resolved path while argv contains a relative path.
        if (DefinitionPath.size() > HeaderPath.size() &&
            DefinitionPath.compare(DefinitionPath.size() - HeaderPath.size(),
                                   HeaderPath.size(), HeaderPath) == 0) {
            const char Separator = DefinitionPath[DefinitionPath.size() - HeaderPath.size() - 1];
            if (Separator == '/' || Separator == '\\')
                return true;
        }
        return false;
    }

    void writeTomlEntry(const std::string &MethodName, uint64_t Index,
                        bool EnsureUniqueKey) {
        writeTomlEntryValue(MethodName, std::to_string(Index), EnsureUniqueKey,
                            std::to_string(Index));
    }

    void writeTomlEntryValue(const std::string &Name, const std::string &Value,
                             bool EnsureUniqueKey, const std::string &DuplicateSuffix) {
        if (Output == nullptr)
            return;

        std::string Key = Name;
        if (EnsureUniqueKey &&
            std::find(WrittenKeys.begin(), WrittenKeys.end(), Key) != WrittenKeys.end())
            Key += "@" + DuplicateSuffix;
        WrittenKeys.push_back(Key);

        if (!OutputHeaderWritten) {
            *Output << "[";
            writeTomlBasicString(*Output, Q.className == "const!"
                ? "const::" + Q.headerPath : "class::" + Q.className);
            *Output << "]\n";
            OutputHeaderWritten = true;
        }

        writeTomlKey(*Output, Key);
        *Output << " = " << Value << '\n';
        if (!*Output) {
            llvm::errs() << "error: failed writing TOML output\n";
            fatal_error = true;
        }
    }

    ASTContext &Context;
    const Query &Q;
    std::ostream *Output = nullptr;
    bool OutputHeaderWritten = false;
    std::vector<std::string> WrittenKeys;
};

// Split brace-set syntax even when the whole expression is quoted as one
// shell argument, e.g. '{{a.h A Foo}, {b.h B Bar}}'.
std::vector<std::string> tokenizeSetArguments(
    const std::vector<std::string> &Arguments) {
    std::vector<std::string> Tokens;
    for (const std::string &Argument : Arguments) {
        std::string Current;
        for (const char C : Argument) {
            if (C == '{' || C == '}' || C == ',') {
                if (!Current.empty()) {
                    Tokens.push_back(Current);
                    Current.clear();
                }
                Tokens.emplace_back(1, C);
            } else if (C == ' ' || C == '\t' || C == '\r' || C == '\n') {
                if (!Current.empty()) {
                    Tokens.push_back(Current);
                    Current.clear();
                }
            } else {
                Current += C;
            }
        }
        if (!Current.empty())
            Tokens.push_back(Current);
    }
    return Tokens;
}

bool parseQueryBody(const std::vector<std::string> &Tokens,
                    std::size_t &Position, Query &Q, std::string &Error) {
    if (Position >= Tokens.size() || Tokens[Position] != "{") {
        Error = "expected '{' before a query";
        return false;
    }
    ++Position;

    std::vector<std::string> Body;
    while (Position < Tokens.size() && Tokens[Position] != "}") {
        if (Tokens[Position] == "{" || Tokens[Position] == ",") {
            Error = "unexpected brace or comma inside a query; expected: {header.h Class method...}";
            return false;
        }
        Body.push_back(Tokens[Position++]);
    }
    if (Position >= Tokens.size()) {
        Error = "missing '}' at the end of a query";
        return false;
    }
    ++Position;

    if (Body.size() < 3) {
        Error = "each query must contain a header, class name, and at least one method";
        return false;
    }

    Q.headerPath = Body[0];
    Q.className = Body[1];
    Q.methodNames.assign(Body.begin() + 2, Body.end());

    const bool HasWildcard = std::find(
        Q.methodNames.begin(), Q.methodNames.end(), "*") != Q.methodNames.end();
    if (HasWildcard && (Q.methodNames.size() != 1 || Q.methodNames.front() != "*")) {
        Error = "'*' must be the only method selector in a query for " + Q.className;
        return false;
    }
    return true;
}

bool parseSetQueries(const std::vector<std::string> &Arguments,
                     std::vector<Query> &Queries, std::string &Error) {
    const std::vector<std::string> Tokens = tokenizeSetArguments(Arguments);
    if (Tokens.empty() || Tokens.front() != "{") {
        Error = "a query set must start with '{'";
        return false;
    }

    // Accept both a set of queries '{{...}, {...}}' and a single braced
    // query '{header.h Class method...}'.
    if (Tokens.size() < 2 || Tokens[1] != "{") {
        std::size_t Position = 0;
        Query Q;
        if (!parseQueryBody(Tokens, Position, Q, Error))
            return false;
        if (Position != Tokens.size()) {
            Error = "unexpected arguments after the braced query";
            return false;
        }
        Queries.push_back(Q);
        return true;
    }

    std::size_t Position = 1; // Consume the outer set's opening brace.
    bool ClosedOuter = false;
    while (Position < Tokens.size()) {
        if (Tokens[Position] == "}") {
            ++Position;
            ClosedOuter = true;
            break;
        }

        Query Q;
        if (!parseQueryBody(Tokens, Position, Q, Error))
            return false;
        Queries.push_back(Q);

        if (Position < Tokens.size() && Tokens[Position] == ",") {
            ++Position;
            if (Position >= Tokens.size() || Tokens[Position] == "}") {
                Error = "expected a query after ',' in the query set";
                return false;
            }
        } else if (Position < Tokens.size() && Tokens[Position] == "}") {
            ++Position;
            ClosedOuter = true;
            break;
        } else {
            Error = "expected ',' or '}' between queries";
            return false;
        }
    }

    if (!ClosedOuter || Position != Tokens.size()) {
        Error = "query set has mismatched braces or trailing arguments";
        return false;
    }
    if (Queries.empty()) {
        Error = "query set must contain at least one query";
        return false;
    }
    return true;
}

} // namespace

int main(int argc, char **argv) {
    // Deliberately plain argv handling rather than
    // clang::tooling::CommonOptionsParser: that helper's own API
    // (CommonOptionsParser::create returning llvm::Expected, vs. older
    // constructor-based forms) has changed shape across LLVM releases
    // more than the lower-level pieces this tool actually depends on.
    if (argc < 2) {
        llvm::errs() << "usage: vtable-index-analyzer <header.h> <ClassName> "
                         "<method1|*> [method2 ...] [--write-into <file.toml>] "
                         "-- <compiler args...>\n"
                         "   or: vtable-index-analyzer '{{<header.h> <ClassName> <method...>}, "
                         "{<header.h> <ClassName> <method...>}}' "
                         "[--write-into <file.toml>] -- <compiler args...>\n";
        return 2;
    }

    int Separator = argc;
    for (int ArgIndex = 1; ArgIndex < argc; ++ArgIndex) {
        if (std::string(argv[ArgIndex]) == "--") {
            Separator = ArgIndex;
            break;
        }
    }

    std::string WriteIntoPath;
    std::vector<std::string> QueryArguments;
    for (int ArgIndex = 1; ArgIndex < Separator; ++ArgIndex) {
        const std::string Arg = argv[ArgIndex];
        if (Arg == "--write-into") {
            if (ArgIndex + 1 >= Separator) {
                llvm::errs() << "error: --write-into requires a file path before '--'\n";
                return 2;
            }
            WriteIntoPath = argv[++ArgIndex];
            continue;
        }
        QueryArguments.push_back(Arg);
    }

    std::vector<std::string> ExtraArgs;
    if (Separator < argc) {
        for (int ArgIndex = Separator + 1; ArgIndex < argc; ++ArgIndex)
            ExtraArgs.push_back(argv[ArgIndex]);
    }

    if (QueryArguments.empty()) {
        llvm::errs() << "error: no query was specified\n";
        return 2;
    }

    std::vector<Query> Queries;
    std::string ParseError;
    if (!QueryArguments.front().empty() && QueryArguments.front().front() == '{') {
        if (!parseSetQueries(QueryArguments, Queries, ParseError)) {
            llvm::errs() << "error: invalid query set: " << ParseError << "\n";
            return 2;
        }
    } else {
        // Backwards-compatible form: <header> <class> <method...>.
        if (QueryArguments.size() < 3) {
            llvm::errs() << "error: expected <header.h> <ClassName> <method1|*> [method2 ...]\n";
            return 2;
        }
        Query Q;
        Q.headerPath = QueryArguments[0];
        Q.className = QueryArguments[1];
        Q.methodNames.assign(QueryArguments.begin() + 2, QueryArguments.end());
        const bool HasWildcard = std::find(
            Q.methodNames.begin(), Q.methodNames.end(), "*") != Q.methodNames.end();
        if (HasWildcard && (Q.methodNames.size() != 1 || Q.methodNames.front() != "*")) {
            llvm::errs() << "error: '*' must be the only method selector\n";
            return 2;
        }
        Queries.push_back(Q);
    }

    for (Query &Q : Queries)
        Q.writeIntoPath = WriteIntoPath;

    // Process every query separately: each may name a different header and
    // class, while all queries share the compiler arguments after '--'.
    for (const Query &Q : Queries) {
        {
            std::ifstream Probe(Q.headerPath);
            if (!Probe) {
                llvm::errs() << "error: couldn't open " << Q.headerPath << "\n";
                return 2;
            }
        }

        std::ostringstream TomlBuffer;
        const std::string Code = "#include \"" + Q.headerPath + "\"\n";
        std::unique_ptr<ASTUnit> AST = clang::tooling::buildASTFromCodeWithArgs(
            Code, ExtraArgs, "vtable_index_analyzer_input.cpp");
        if (!AST) {
            llvm::errs() << "error: failed to parse " << Q.headerPath
                         << " (see diagnostics above)\n";
            return 1;
        }

        IndexVisitor Visitor(AST->getASTContext(), Q,
                             WriteIntoPath.empty() ? nullptr : &TomlBuffer);
        if (Q.className == "const!") {
            if (!Visitor.processMacros(AST->getPreprocessor(), AST->getSourceManager()))
                return 1;
            if (Visitor.fatal_error)
                return 1;
            if (!WriteIntoPath.empty() && !TomlBuffer.str().empty()) {
                const int WriteResult = updateTomlFile(WriteIntoPath, TomlBuffer.str());
                if (WriteResult != 0)
                    return WriteResult;
            }
            continue;
        }
        Visitor.TraverseDecl(AST->getASTContext().getTranslationUnitDecl());

        if (!Visitor.found) {
            llvm::errs() << "error: class '" << Q.className
                         << "' (as a complete definition) was never found while parsing '"
                         << Q.headerPath << "' and its includes\n";
            return 1;
        }
        if (Visitor.fatal_error)
            return 1;

        if (!WriteIntoPath.empty() && !TomlBuffer.str().empty()) {
            const int WriteResult = updateTomlFile(WriteIntoPath, TomlBuffer.str());
            if (WriteResult != 0)
                return WriteResult;
        }
    }

    return 0;
}
