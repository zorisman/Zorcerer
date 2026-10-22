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
// *** VERIFIED - compiled and exercised in this environment ***
// This file now builds and links against the system Clang/LLVM 21
// (libclang-cpp, libstdc++), and all query forms (class, wildcard,
// macro, brace set, --write-into, error paths) were run end to end
// against synthetic headers. Real hl2sdk checkouts and other LLVM
// releases are still unexercised here: if a build fails on a different
// LLVM version, treat `clang::tooling::buildASTFromCodeWithArgs`'s
// exact signature and `ItaniumVTableContext`'s constructor as the
// risky API surface - both have shifted shape across LLVM releases
// historically. The AST-walking logic (RecursiveASTVisitor, looking up
// a named virtual method, calling getMethodVTableIndex) is much less
// likely to have changed and is the part actually worth trusting.

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
#include <utility>
#include <vector>

using namespace clang;

namespace {

/// A single user request: which header to parse, what target to inspect
/// ("const!" inspects object-like #define macros instead of a class),
/// and which method (or macro) names to resolve. A lone "*" as the only
/// selector means every callable vtable slot of the class's primary
/// vtable, or every object-like macro defined in the header itself.
///
/// User-facing results are printed to stdout while resolving; the TOML
/// output path is a per-invocation option, not per-query, so it lives
/// outside this struct and is threaded through the run helpers.
struct Query {
    /// Path of the header to parse, exactly as given on the command
    /// line; also used for the macro-path TOML section key.
    std::string headerPath;
    /// Class name to look up, or the literal "const!" for the macro path.
    std::string className;
    /// Method (or macro) names to resolve; a lone "*" enables wildcard
    /// mode. Never empty (validated during parse).
    std::vector<std::string> methodNames;
};

/// TOML section key under which a query's results are grouped in the
/// --write-into file: "[class::<name>]" for class queries and
/// "[const::<headerPath>]" for macro queries.
///
/// \param Q the query being written out.
/// \returns the section key without enclosing brackets.
std::string tomlSectionName(const Query &Q) {
    return Q.className == "const!"
        ? "const::" + Q.headerPath
        : "class::" + Q.className;
}

/// Accumulates the TOML section generated for one query and writes each
/// entry to a stream. When \p Output is null (--write-into was not
/// given), every entry is discarded and the section stays empty; the
/// caller then must not flush anything.
///
/// Invariants:
/// - The "[<section-name>]" header is emitted lazily, exactly once,
///   before the first surviving entry.
/// - Keys recorded with \c ensureUnique never collide within the
///   section: a duplicate receives "@" + the caller's suffix so the
///   destructor pair and repeated macro names stay distinct.
/// - \c failed() is sticky: \c true forever once a stream write fails,
///   and callers must treat the generated section as unusable then.
class TomlSectionWriter {
public:
    /// Prepares a writer for one query's section.
    ///
    /// \param Output destination stream, or null to discard all entries.
    /// \param SectionName section key (see \c tomlSectionName); emitted
    ///                    inside brackets on first entry.
    TomlSectionWriter(std::ostream *Output, std::string SectionName)
        : Output(Output), SectionName(std::move(SectionName)) {}

    /// Records a vtable index entry for a method (in wildcard mode the
    /// whole slot, in named mode a single method); the key is
    /// deduplicated against previously written keys using the decimal
    /// slot index as suffix when \p EnsureUniqueKey is set. Named-mode
    /// callers pass false there because a duplicate method name cannot
    /// be requested twice after parse validation.
    void addMethodEntry(const std::string &MethodName, uint64_t Index,
                        bool EnsureUniqueKey) {
        addEntry(MethodName, std::to_string(Index), EnsureUniqueKey,
                 std::to_string(Index));
    }

    /// Records a macro entry whose value is an arbitrary string; keys are
    /// deduplicated with \p SequenceNumber as suffix.
    void addMacroEntry(const std::string &Name, const std::string &Value,
                       std::size_t SequenceNumber) {
        addEntry(Name, Value, true, std::to_string(SequenceNumber));
    }

    /// Whether any entry was recorded (i.e. the section contains data
    /// worth flushing to the --write-into file).
    bool hasEntries() const { return !WrittenKeys.empty(); }

    /// Whether a stream write has failed (see class invariants).
    bool failed() const { return WriteFailed; }

private:
    /// Shared implementation of both public entry forms.
    void addEntry(const std::string &Name, const std::string &Value,
                  bool EnsureUniqueKey, const std::string &DuplicateSuffix) {
        if (Output == nullptr)
            return;

        std::string Key = Name;
        if (EnsureUniqueKey &&
            std::find(WrittenKeys.begin(), WrittenKeys.end(), Key) != WrittenKeys.end())
            Key += "@" + DuplicateSuffix;
        WrittenKeys.push_back(Key);

        if (!SectionHeaderWritten) {
            *Output << "[";
            writeTomlBasicString(*Output, SectionName);
            *Output << "]\n";
            SectionHeaderWritten = true;
        }

        writeTomlKey(*Output, Key);
        *Output << " = " << Value << '\n';
        if (!*Output) {
            llvm::errs() << "error: failed writing TOML output\n";
            WriteFailed = true;
        }
    }

    std::ostream *Output;
    std::string SectionName;
    bool SectionHeaderWritten = false;
    std::vector<std::string> WrittenKeys;
    bool WriteFailed = false;
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

/// AST visitor that resolves the method-index part of a class query
/// against the vtable layout Clang computes for the requested class.
///
/// It walks the parsed translation unit looking for a complete class
/// definition matching the query's class name (by qualified or simple
/// name), then reports each requested method's Itanium vtable index to
/// stdout and records it in the section writer. Lifetime: bound
/// references must outlive the traversal; the writer is shared state
/// owned by the run helper.
class IndexVisitor : public RecursiveASTVisitor<IndexVisitor> {
public:
    /// Prepares a visitor for one class query.
    IndexVisitor(ASTContext &Context, const Query &Q, TomlSectionWriter &Writer)
        : Context(Context), Q(Q), Writer(Writer) {}

    /// Reports every completed class definition whose qualified or
    /// simple name matches the query, then resolves its requested
    /// methods; other declarations are skipped.
    bool VisitCXXRecordDecl(CXXRecordDecl *RD) {
        if (!RD->isCompleteDefinition())
            return true;
        if (RD->getQualifiedNameAsString() != Q.className &&
            RD->getNameAsString() != Q.className)
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

        if (Q.methodNames.size() == 1 && Q.methodNames.front() == "*")
            reportWildcardSlots(RD, VTContext);
        else
            for (const std::string &MethodName : Q.methodNames)
                reportNamedMethod(RD, VTContext, MethodName);

        return true;
    }

    /// True once at least one matching complete class definition was
    /// seen during traversal; callers must report the class as missing
    /// when this stays false.
    bool found = false;
    /// Sticky failure flag set when a reported vtable layout is
    /// internally inconsistent (invalid address point) and the
    /// generated indices cannot be trusted; callers must abort the
    /// query without flushing TOML output.
    bool fatalError = false;

private:
    /// Reports (and records) every callable method slot in the class's
    /// primary vtable - the "*" query mode. VTableLayout indices are
    /// relative to the address point, matching getMethodVTableIndex()'s
    /// index convention; ABI metadata (including RTTI) and unused slots
    /// are skipped. Destructor variants are annotated in the report and
    /// deduplicated in the TOML keys by their slot index.
    void reportWildcardSlots(const CXXRecordDecl *RD, ItaniumVTableContext &VTContext) {
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
            fatalError = true;
            return;
        }

        for (std::size_t ComponentIndex = AddressPoint.AddressPointIndex;
             ComponentIndex < VTableEnd; ++ComponentIndex) {
            const VTableComponent &Component = Components[ComponentIndex];
            if (!Component.isUsedFunctionPointerKind())
                continue;

            const CXXMethodDecl *Method = Component.getFunctionDecl();
            const uint64_t SlotIndex =
                ComponentIndex - AddressPoint.AddressPointIndex;
            llvm::outs() << Q.className << "::" << Method->getNameAsString()
                         << " = " << SlotIndex;
            if (Component.getKind() == VTableComponent::CK_CompleteDtorPointer) {
                llvm::outs() << "  (complete destructor)";
            } else if (Component.getKind() == VTableComponent::CK_DeletingDtorPointer) {
                llvm::outs() << "  (deleting destructor)";
            }
            llvm::outs() << "\n";
            Writer.addMethodEntry(Method->getNameAsString(), SlotIndex, true);
        }
    }

    /// Resolves and reports one named virtual method of the class,
    /// including methods it inherits. Destructors are resolved through
    /// their D1 (complete) variant; see the adjacency note in the
    /// report. Names without any virtual method are reported as errors
    /// on stderr and skipped (other requested names are still
    /// processed).
    void reportNamedMethod(const CXXRecordDecl *RD, ItaniumVTableContext &VTContext,
                           const std::string &MethodName) {
        const CXXMethodDecl *Target = findVirtualMethod(RD, MethodName);
        if (!Target) {
            llvm::errs() << "error: no virtual method named '" << MethodName
                         << "' found on or inherited into " << Q.className << "\n";
            return;
        }

        GlobalDecl GD;
        bool IsDtor = false;
        if (const auto *Dtor = dyn_cast<CXXDestructorDecl>(Target)) {
            // Dtor_Complete (D1) is the first of the pair; the
            // deleting destructor (D0) occupies the slot right after
            // it in a standard Itanium layout. If the target SDK build
            // somehow disagrees with that adjacency assumption, query
            // Dtor_Deleting explicitly instead of assuming "+1".
            GD = GlobalDecl(Dtor, Dtor_Complete);
            IsDtor = true;
        } else {
            GD = GlobalDecl(Target);
        }

        const uint64_t Index = VTContext.getMethodVTableIndex(GD);
        llvm::outs() << Q.className << "::" << MethodName << " = " << Index;
        if (IsDtor) {
            llvm::outs() << "  (virtual destructor: also reserves the next "
                            "slot, " << (Index + 1) << ", for the deleting-destructor "
                            "variant)";
        }
        llvm::outs() << "\n";
        Writer.addMethodEntry(MethodName, Index, false);
    }

    ASTContext &Context;
    const Query &Q;
    TomlSectionWriter &Writer;
};

/// Whether a macro definition location lives in the query's header.
/// Clang may report a resolved absolute path while argv contains a
/// relative (or differently spelled) path, so exact equality is
/// supplemented by a suffix comparison that requires a path separator
/// immediately before the header path.
///
/// \param SM source manager owning \p Loc.
/// \param Loc macro definition location.
/// \param HeaderPath header path as spelled in the query.
/// \returns true if the definition is attributed to that header.
bool definitionIsInHeader(const SourceManager &SM, SourceLocation Loc,
                          const std::string &HeaderPath) {
    const std::string DefinitionPath = SM.getFilename(Loc).str();
    if (DefinitionPath == HeaderPath)
        return true;
    if (DefinitionPath.size() > HeaderPath.size() &&
        DefinitionPath.compare(DefinitionPath.size() - HeaderPath.size(),
                               HeaderPath.size(), HeaderPath) == 0) {
        const char Separator = DefinitionPath[DefinitionPath.size() - HeaderPath.size() - 1];
        if (Separator == '/' || Separator == '\\')
            return true;
    }
    return false;
}

/// Resolves the const! macro part of a query against the preprocessor
/// state of the parsed translation unit: object-like #define macros
/// whose definition lives in the query's header. A lone "*" selects all
/// matching macros; otherwise only the requested names are reported.
///
/// Results are printed to stdout and recorded in the writer; a missing
/// requested name only ends the query (reported on stderr, \c false
/// returned), other names written before it stay recorded.
///
/// \param Q the macro query ("const!" class name, method names as
///          macro names).
/// \param PP preprocessor of the translation unit parsed from the query
///           header.
/// \param SM source manager of the same translation unit; used to match
///           macro definitions against the header path.
/// \param Writer destination for the TOML section.
/// \returns true if every requested name was resolved (or "*" mode
///          found at least one macro); false otherwise.
bool processMacroQuery(const Query &Q, Preprocessor &PP, const SourceManager &SM,
                       TomlSectionWriter &Writer) {
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
        Writer.addMacroEntry(Name, Value, FoundNames.size());
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

/// Split brace-set syntax even when the whole expression is quoted as one
/// shell argument, e.g. '{{a.h A Foo}, {b.h B Bar}}'.
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

/// Validates a parsed query's method selectors: '*' must either be the
/// only selector or not appear at all.
bool validateMethodSelectors(Query &Q, std::string &Error) {
    const bool HasWildcard = std::find(
        Q.methodNames.begin(), Q.methodNames.end(), "*") != Q.methodNames.end();
    if (HasWildcard && (Q.methodNames.size() != 1 || Q.methodNames.front() != "*")) {
        Error = "'*' must be the only method selector in a query for " + Q.className;
        return false;
    }
    return true;
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
    return validateMethodSelectors(Q, Error);
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

/// Everything the query runners need from the command line: the parsed
/// queries, the --write-into target (empty when absent), and the
/// compiler arguments after '--'.
struct CommandLine {
    /// Query arguments on the command line, before '--'; the raw input
    /// the query parser consumes, with '--write-into' options removed.
    std::vector<std::string> preQueryArgs;
    /// Parsed queries; empty until parsing succeeded.
    std::vector<Query> queries;
    /// --write-into target file path, empty when the option was not given.
    std::string writeIntoPath;
    /// Compiler arguments after '--', shared by all queries.
    std::vector<std::string> compilerArgs;
};

/// Parses the tool invocation into \c CommandLine form.
///
/// Accepts the legacy positional form '<header> <class> <method...>'
/// and the braced set form '{{...}, {...}}'; see the usage text. No
/// parse failures are printed here - the caller reports \p Error.
///
/// \param argc \param argv the process arguments (argv[0] is skipped).
/// \param Command receives the parsed state on success.
/// \param Error receives a user-facing message on failure.
/// \returns true on success; false on any argument error.
bool parseCommandLine(int argc, char **argv, CommandLine &Command,
                      std::string &Error) {
    // Deliberately plain argv handling rather than
    // clang::tooling::CommonOptionsParser: that helper's own API
    // (CommonOptionsParser::create returning llvm::Expected, vs. older
    // constructor-based forms) has changed shape across LLVM releases
    // more than the lower-level pieces this tool actually depends on.
    int Separator = argc;
    for (int ArgIndex = 1; ArgIndex < argc; ++ArgIndex) {
        if (std::string(argv[ArgIndex]) == "--") {
            Separator = ArgIndex;
            break;
        }
    }

    for (int ArgIndex = 1; ArgIndex < Separator; ++ArgIndex) {
        const std::string Arg = argv[ArgIndex];
        if (Arg == "--write-into") {
            if (ArgIndex + 1 >= Separator) {
                Error = "--write-into requires a file path before '--'";
                return false;
            }
            Command.writeIntoPath = argv[++ArgIndex];
            continue;
        }
        Command.preQueryArgs.push_back(Arg);
    }

    for (int ArgIndex = Separator + 1; ArgIndex < argc; ++ArgIndex)
        Command.compilerArgs.push_back(argv[ArgIndex]);

    if (Command.preQueryArgs.empty()) {
        Error = "no query was specified";
        return false;
    }

    if (!Command.preQueryArgs.front().empty() &&
        Command.preQueryArgs.front().front() == '{') {
        // The brace-set form reports parse failures with an extra
        // prefix; keep its exact wording even though parseCommandLine
        // is shared with the legacy form.
        std::string SetError;
        if (!parseSetQueries(Command.preQueryArgs, Command.queries, SetError)) {
            Error = "invalid query set: " + SetError;
            return false;
        }
        return true;
    }

    // Backwards-compatible form: <header> <class> <method...>.
    if (Command.preQueryArgs.size() < 3) {
        Error = "expected <header.h> <ClassName> <method1|*> [method2 ...]";
        return false;
    }
    Query Q;
    Q.headerPath = Command.preQueryArgs[0];
    Q.className = Command.preQueryArgs[1];
    Q.methodNames.assign(Command.preQueryArgs.begin() + 2, Command.preQueryArgs.end());
    if (!validateMethodSelectors(Q, Error)) {
        // The legacy form used a shorter selector error; keep it for
        // existing users of the tool.
        Error = "'*' must be the only method selector";
        return false;
    }
    Command.queries.push_back(Q);
    return true;
}

/// Runs one query end to end: verifies the header exists, parses it
/// with Clang plus the shared compiler arguments, resolves the query
/// against the AST, emits the human-readable report, and (when a
/// --write-into path was given and anything was generated) appends the
/// generated TOML section to that file.
///
/// \param Q the query to run.
/// \param WriteIntoPath TOML file to append to, or empty to skip.
/// \param CompilerArgs arguments passed to Clang, shared by all queries.
/// \returns this query's process exit code contribution: 0 on success;
///          1 when parsing, resolution, or TOML generation failed; 2
///          when the header file could not be opened; or whatever
///          \c updateTomlFile reports if it fails.
int runQuery(const Query &Q, const std::string &WriteIntoPath,
             const std::vector<std::string> &CompilerArgs) {
    {
        std::ifstream Probe(Q.headerPath);
        if (!Probe) {
            llvm::errs() << "error: couldn't open " << Q.headerPath << "\n";
            return 2;
        }
    }

    std::ostringstream TomlBuffer;
    TomlSectionWriter Writer(WriteIntoPath.empty() ? nullptr : &TomlBuffer,
                             tomlSectionName(Q));

    const std::string Code = "#include \"" + Q.headerPath + "\"\n";
    std::unique_ptr<ASTUnit> AST = clang::tooling::buildASTFromCodeWithArgs(
        Code, CompilerArgs, "vtable_index_analyzer_input.cpp");
    if (!AST) {
        llvm::errs() << "error: failed to parse " << Q.headerPath
                     << " (see diagnostics above)\n";
        return 1;
    }

    int Status = 0;
    if (Q.className == "const!") {
        if (!processMacroQuery(Q, AST->getPreprocessor(), AST->getSourceManager(),
                               Writer))
            Status = 1;
    } else {
        IndexVisitor Visitor(AST->getASTContext(), Q, Writer);
        Visitor.TraverseDecl(AST->getASTContext().getTranslationUnitDecl());

        if (!Visitor.found) {
            llvm::errs() << "error: class '" << Q.className
                         << "' (as a complete definition) was never found while parsing '"
                         << Q.headerPath << "' and its includes\n";
            Status = 1;
        }
        if (Visitor.fatalError)
            Status = 1;
    }

    if (Writer.failed())
        Status = 1;

    if (Status == 0 && !WriteIntoPath.empty() && Writer.hasEntries()) {
        const int WriteResult = updateTomlFile(WriteIntoPath, TomlBuffer.str());
        if (WriteResult != 0)
            return WriteResult;
    }
    return Status;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        llvm::errs() << "usage: vtable-index-analyzer <header.h> <ClassName> "
                         "<method1|*> [method2 ...] [--write-into <file.toml>] "
                         "-- <compiler args...>\n"
                         "   or: vtable-index-analyzer '{{<header.h> <ClassName> <method...>}, "
                         "{<header.h> <ClassName> <method...>}}' "
                         "[--write-into <file.toml>] -- <compiler args...>\n";
        return 2;
    }

    CommandLine Command;
    std::string ParseError;
    if (!parseCommandLine(argc, argv, Command, ParseError)) {
        llvm::errs() << "error: " << ParseError << "\n";
        return 2;
    }

    // Process every query separately: each may name a different header and
    // class, while all queries share the compiler arguments after '--'.
    for (const Query &Q : Command.queries) {
        const int Status = runQuery(Q, Command.writeIntoPath, Command.compilerArgs);
        if (Status != 0)
            return Status;
    }

    return 0;
}
