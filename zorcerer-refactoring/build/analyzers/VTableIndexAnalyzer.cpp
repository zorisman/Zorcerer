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
// This feeds the generated engine index table
// (src/codegen_generated/engine_indexes.zig): the adapter runs it once per
// SDK checkout/branch you want to support, and its stdout supplies the
// vtable indices and version strings that EngineIndexesGenerator turns into
// Zig constants.
//
// Usage:
//   vtable-index-analyzer -- <compiler args...>
//   The query set is read from standard input in either the brace-set
//   form '{{<header.h> <target> <selector...>}, ...}' or the legacy
//   positional form '<header.h> <target> <selector...>' (a single line
//   is enough for one query). Results are written to standard output;
//   the tool no longer writes TOML files itself.
//   <target> selects what is resolved: a class name resolves that
//   class's virtual method vtable indices (named selectors may also
//   resolve static const/constexpr data members of the class);
//   "enum::<EnumName>" resolves the enumerator values of one enum type;
//   the bare "const::" resolves object-like #define constants and
//   namespace-scope const/constexpr variables defined in the requested
//   header itself. A lone "*", as the only selector, asks for
//   everything of the chosen element kind (vtable slots, enumerators,
//   or header constants).
//
// Example, for TF2's hl2sdk-tf2 checkout:
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h IVEngineServer \
//       LogPrint ServerCommand -- \
//       -I hl2sdk-tf2/public -I hl2sdk-tf2/public/engine -I hl2sdk-tf2/public/tier1 \
//       -DCOMPILER_GCC -DPOSIX -D_LINUX -DGNUC -std=gnu++14 -m32
//
// Constants defined directly in the requested header:
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h 'const::' \
//       INTERFACEVERSION_VENGINESERVER INTERFACEVERSION_VENGINESERVER_INT -- \
//       -I hl2sdk-tf2/public -I hl2sdk-tf2/public/engine -I hl2sdk-tf2/public/tier1 \
//       -DCOMPILER_GCC -DPOSIX -D_LINUX -DGNUC -std=gnu++14 -m32
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h 'const::' '*' -- <compiler args...>
//
// Enumerators of one enum type (use whichever branch defines it):
//   vtable-index-analyzer hl2sdk-tf2/public/game/shared/in_buttons.h enum::IN_BUTTONS \
//       FIRST LAST '*' -- <compiler args...>
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
// This file previously built and linked against the system Clang/LLVM 21
// (libclang-cpp, libstdc++), and its query forms (class, wildcard,
// macro, brace set, error paths) were run end to end against synthetic
// headers. Reading queries from standard input reuses that parser but
// was not exercised after the change. Real hl2sdk checkouts and other
// LLVM releases are still unexercised here: if a build fails on a
// different
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
#include "llvm/ADT/APFloat.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/raw_ostream.h"
#include "toml.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

using namespace clang;

namespace {

/// Which kind of element a query target names.
enum class TargetKind {
    /// A plain class name: resolve that class's virtual method vtable
    /// indices through Itanium vtable layout. Named selectors may also
    /// resolve static const/constexpr data members as constants.
    Class,
    /// "enum::<EnumName>": resolve the enumerator values of one enum
    /// type.
    Enum,
    /// The bare "const::": resolve object-like #define macros and
    /// namespace-scope const/constexpr variables whose definitions
    /// live in the queried header itself.
    Constants,
};

/// A single user request: which header to parse, what element kind and
/// target to inspect, and which selector names to resolve. A lone "*"
/// as the only selector means "everything of the chosen kind": all
/// vtable slots of the class's primary vtable, all enumerators of the
/// enum, or all constant definitions of the header.
///
/// User-facing results are printed to stdout while resolving; callers
/// that need machine-readable data consume that stream directly.
struct Query {
    /// Path of the header to parse, exactly as given on the command
    /// line; also used as the key of the Constants section, for the
    /// macro/variable in-header filter, and in reports.
    std::string headerPath;
    /// What the query resolves; see \c TargetKind.
    TargetKind kind = TargetKind::Class;
    /// Class or enum name to look up (empty for \c Constants, whose
    /// selectors each name their own constant).
    std::string targetName;
    /// Method, enumerator, or constant selectors; a lone "*" enables
    /// wildcard mode. Never empty (validated during parse).
    std::vector<std::string> selectors;
};

/// Classifies a query's target token from the command line.
///
/// "enum::<Name>" and the bare "const::" (name part empty) are element
/// queries; anything else - including qualified names like
/// "ns::ClassName" - is treated as a plain class name, so preexisting
/// qualified-class queries keep working.
///
/// \param Token target token exactly as it appears in the query.
/// \param Kind receives the resolved element kind.
/// \param Name receives the target name (empty for \c Constants).
/// \param Error receives a user-facing message for malformed element
///              queries ("enum::" with no name, or "const::<Name>").
/// \returns true for well-formed targets; false and fills \p Error for
///          malformed ones ("const::<Name>" has no meaning under the
///          "const::" grammar where selectors carry the names).
bool parseTarget(const std::string &Token, TargetKind &Kind,
                 std::string &Name, std::string &Error) {
    const std::size_t Separator = Token.find("::");
    if (Separator == std::string::npos) {
        Kind = TargetKind::Class;
        Name = Token;
        return true;
    }

    const std::string Type = Token.substr(0, Separator);
    const std::string Rest = Token.substr(Separator + 2);
    if (Type == "enum") {
        if (Rest.empty()) {
            Error = "enum::<Name> requires the enum type name";
            return false;
        }
        Kind = TargetKind::Enum;
        Name = Rest;
        return true;
    }
    if (Type == "const" && Rest.empty()) {
        Kind = TargetKind::Constants;
        Name.clear();
        return true;
    }
    if (Type == "const") {
        Error = "'const::' takes no name; name the constants as selectors";
        return false;
    }
    // Unknown prefix (or a leading "::") - keep treating the token as a
    // class name so qualified-class queries are unaffected.
    Kind = TargetKind::Class;
    Name = Token;
    return true;
}

/// Whether the query's selectors are the lone "*" wildcard form.
bool wildcardsEverything(const Query &Q) {
    return Q.selectors.size() == 1 && Q.selectors.front() == "*";
}

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

/// Serializes an evaluated constant value as a TOML value literal:
/// booleans as "true"/"false", integers as signed decimal literals, and
/// floating-point values in round-trippable decimal form. Anything else
/// (pointers, strings, class types, ...) is rejected - SDK headers
/// define their string-ish values as #define macros, which follow a
/// separate path.
///
/// \param Value evaluated initializer value, e.g. from
///              \c VarDecl::evaluateValue() or \c EnumConstantDecl::
///              \c getInitVal().
/// \param Type declared type of the constant; distinguishes boolean
///             from integer constants.
/// \param Result receives the TOML literal on success.
/// \param Error receives a user-facing message on failure.
/// \returns true unless the value kind is unsupported (or the declared
///          floating type is not half/float/double).
bool apValueAsToml(const APValue &Value, const QualType &Type,
                   std::string &Result, std::string &Error) {
    if (Value.isInt()) {
        if (Type->isBooleanType())
            Result = Value.getInt().getBoolValue() ? "true" : "false";
        else
            Result = llvm::toString(Value.getInt(), 10);
        return true;
    }
    if (Value.isFloat()) {
        const llvm::APFloat &Float = Value.getFloat();
        const llvm::fltSemantics &Semantics = Float.getSemantics();
        if (&Semantics != &llvm::APFloat::IEEEhalf() &&
            &Semantics != &llvm::APFloat::IEEEsingle() &&
            &Semantics != &llvm::APFloat::IEEEdouble()) {
            Error = "long double constants cannot be serialized";
            return false;
        }
        // Plenty of digits for double round-trip; paddingLeft/precision
        // improvements are not worth inventing a decimal printer here.
        char Buffer[64];
        std::snprintf(Buffer, sizeof(Buffer), "%.17g", Float.convertToDouble());
        Result = Buffer;
        return true;
    }
    Error = "unsupported constant kind (only integer, boolean, and "
            "floating-point constants can be resolved)";
    return false;
}

/// Finds one static const/constexpr data member named \p Name in the
/// class, searching its bases recursively (Source SDK interfaces are
/// single-inheritance per this tool's scope; the AST visitor reports
/// multiple/virtual inheritance separately as a warning).
///
/// \param RD complete class definition to search.
/// \param Name unqualified member name.
/// \returns the first matching declaration found, or nullptr. The
///          pointer is owned by the translation unit's AST.
const VarDecl *findConstantMember(const CXXRecordDecl *RD, const std::string &Name) {
    DeclarationName DN(&RD->getASTContext().Idents.get(Name));
    for (const auto *D : RD->lookup(DN)) {
        if (const auto *VD = dyn_cast<VarDecl>(D)) {
            if (VD->isStaticDataMember() &&
                (VD->getType().isConstQualified() || VD->isConstexpr()))
                return VD;
        }
    }
    for (const auto &Base : RD->bases()) {
        if (const auto *BaseRD = Base.getType()->getAsCXXRecordDecl()) {
            if (BaseRD->isCompleteDefinition()) {
                if (const VarDecl *Found = findConstantMember(BaseRD, Name))
                    return Found;
            }
        }
    }
    return nullptr;
}

/// AST visitor that resolves the class part of a query against the
/// vtable layout Clang computes for the requested class.
///
/// It walks the parsed translation unit looking for a complete class
/// definition matching the query's target name (by qualified or simple
/// name, first match wins), then reports each requested method's
/// Itanium vtable index to stdout. Named selectors that are not virtual
/// methods fall back to static const/constexpr data members, resolved
/// through the compiler's own value evaluation.
class IndexVisitor : public RecursiveASTVisitor<IndexVisitor> {
public:
    /// Prepares a visitor for one class query.
    IndexVisitor(ASTContext &Context, const Query &Q)
        : Context(Context), Q(Q) {}

    /// Reports every completed class definition whose qualified or
    /// simple name matches the query, then resolves its requested
    /// selectors; other declarations are skipped.
    bool VisitCXXRecordDecl(CXXRecordDecl *RD) {
        if (!RD->isCompleteDefinition())
            return true;
        if (RD->getQualifiedNameAsString() != Q.targetName &&
            RD->getNameAsString() != Q.targetName)
            return true;

        found = true;

        if (RD->getNumBases() > 1 || RD->getNumVBases() > 0) {
            llvm::errs() << "warning: " << Q.targetName
                         << " uses multiple or virtual inheritance - this tool "
                            "only reliably handles single inheritance. Verify "
                            "these indices another way (e.g. engine_adapter.cpp's "
                            "runtime pointer-to-member trick against a real "
                            "build) before trusting them.\n";
        }

        ItaniumVTableContext VTContext(Context);

        if (wildcardsEverything(Q))
            reportWildcardSlots(RD, VTContext);
        else
            for (const std::string &Selector : Q.selectors)
                reportNamedMethod(RD, VTContext, Selector);

        return true;
    }

    /// True once at least one matching complete class definition was
    /// seen during traversal; callers must report the class as missing
    /// when this stays false.
    bool found = false;
    /// Sticky failure flag set when a reported vtable layout is
    /// internally inconsistent (invalid address point) and the
    /// generated indices cannot be trusted; callers must abort the
    /// query without trusting its stdout.
    bool fatalError = false;

private:
    /// Reports (and records) every callable method slot in the class's
    /// primary vtable - the "*" query mode. VTableLayout indices are
    /// relative to the address point, matching getMethodVTableIndex()'s
    /// index convention; ABI metadata (including RTTI) and unused slots
    /// are skipped. Destructor variants are annotated in the report.
    /// This mode stays methods-only (no wildcard setup for constants
    /// exists).
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
                         << Q.targetName << "\n";
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
            llvm::outs() << Q.targetName << "::" << Method->getNameAsString()
                         << " = " << SlotIndex;
            if (Component.getKind() == VTableComponent::CK_CompleteDtorPointer) {
                llvm::outs() << "  (complete destructor)";
            } else if (Component.getKind() == VTableComponent::CK_DeletingDtorPointer) {
                llvm::outs() << "  (deleting destructor)";
            }
            llvm::outs() << "\n";
        }
    }

    /// Resolves and reports one named selector of the class: a virtual
    /// method (including inherited ones) or, as a fallback, a static
    /// const/constexpr data member evaluated as a constant. Destructors
    /// are resolved through their D1 (complete) variant; see the
    /// adjacency note in the report. Selectors matching neither are
    /// reported as errors on stderr and skipped (other requested
    /// selectors are still processed).
    void reportNamedMethod(const CXXRecordDecl *RD, ItaniumVTableContext &VTContext,
                           const std::string &MethodName) {
        const CXXMethodDecl *Target = findVirtualMethod(RD, MethodName);
        if (!Target) {
            // Not a virtual method - report it as a constant member when
            // the class (or a base) declares one with that name, so the
            // class path can also calibrate compile-time member values.
            if (reportConstantMember(RD, MethodName))
                return;
            llvm::errs() << "error: no virtual method or constant member named '"
                         << MethodName << "' found on or inherited into "
                         << Q.targetName << "\n";
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
        llvm::outs() << Q.targetName << "::" << MethodName << " = " << Index;
        if (IsDtor) {
            llvm::outs() << "  (virtual destructor: also reserves the next "
                            "slot, " << (Index + 1) << ", for the deleting-destructor "
                            "variant)";
        }
        llvm::outs() << "\n";
    }

    /// Evaluates and reports one static const/constexpr data member of
    /// the class - the named-method constant fallback.
    ///
    /// \param RD complete class definition containing (or whose bases
    ///           contain) the member.
    /// \param Name unqualified member name.
    /// \returns true if a member with that name was reported (even when
    ///          its value could not be evaluated - that is reported as
    ///          an error); false if the class has no such member, so
    ///          the caller can report the selector as missing.
    bool reportConstantMember(const CXXRecordDecl *RD, const std::string &Name) {
        const VarDecl *Member = findConstantMember(RD, Name);
        if (Member == nullptr)
            return false;

        const APValue *Value = Member->evaluateValue();
        if (Value == nullptr) {
            llvm::errs() << "error: constant " << Q.targetName << "::" << Name
                         << " has no evaluable compile-time value\n";
            return true;
        }
        std::string TomlValue;
        std::string EvalError;
        if (!apValueAsToml(*Value, Member->getType(), TomlValue, EvalError)) {
            llvm::errs() << "error: constant " << Q.targetName << "::" << Name
                         << ": " << EvalError << "\n";
            return true;
        }
        llvm::outs() << Q.targetName << "::" << Name << " = " << TomlValue << "\n";
        return true;
    }

    ASTContext &Context;
    const Query &Q;
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

/// AST visitor that resolves the namespace-scope constant-variable part
/// of a "const::" query: definitions of const or constexpr variables at
/// file scope whose definition lives in the query's header. Each value
/// is reported to stdout; received names are appended to the query's
/// shared found-name list in encounter order.
class ConstantVarVisitor : public RecursiveASTVisitor<ConstantVarVisitor> {
public:
    /// Prepares a visitor for one constant query.
    ///
    /// \param Q the query (header path and selectors; kind must be
    ///          \c TargetKind::Constants).
    /// \param SM source manager of the translation unit being walked;
    ///           used to match variable definitions against the header.
    /// \param FoundNames shared list that receives every name this
    ///                   visitor resolved.
    ConstantVarVisitor(const Query &Q, const SourceManager &SM,
                       std::vector<std::string> &FoundNames)
        : Q(Q), SM(SM), FoundNames(FoundNames) {}

    /// Reports every namespace-scope constant definition that lives in
    /// the query's header and (in named mode) matches a selector;
    /// declarations without a valued definition (e.g. `extern const`
    /// forward declarations, non-const variables) in other scopes are
    /// skipped.
    bool VisitVarDecl(VarDecl *VD) {
        const auto *Scope = VD->getDeclContext();
        if (Scope == nullptr || !Scope->isFileContext())
            return true;
        const QualType Type = VD->getType();
        if (!Type.isConstQualified() && !VD->isConstexpr())
            return true;
        if (VD->getInit() == nullptr)
            return true;
        if (!definitionIsInHeader(SM, VD->getLocation(), Q.headerPath))
            return true;

        const std::string Name = VD->getNameAsString();
        if (!wildcardsEverything(Q) &&
            std::find(Q.selectors.begin(), Q.selectors.end(), Name) ==
                Q.selectors.end())
            return true;

        const APValue *Value = VD->evaluateValue();
        if (Value == nullptr) {
            if (wildcardsEverything(Q)) {
                llvm::errs() << "warning: skipping constant " << Name
                             << " - its initializer is not a compile-time "
                                "constant value\n";
                return true;
            }
            llvm::errs() << "error: constant " << Name << " in " << Q.headerPath
                         << " has no evaluable compile-time value\n";
            errored = true;
            return true;
        }

        std::string TomlValue;
        std::string EvalError;
        if (!apValueAsToml(*Value, Type, TomlValue, EvalError)) {
            if (wildcardsEverything(Q)) {
                llvm::errs() << "warning: skipping constant " << Name
                             << ": " << EvalError << "\n";
                return true;
            }
            llvm::errs() << "error: constant " << Name << " in " << Q.headerPath
                         << ": " << EvalError << "\n";
            errored = true;
            return true;
        }

        llvm::outs() << Q.headerPath << "::" << Name << " = " << TomlValue << '\n';
        FoundNames.push_back(Name);
        return true;
    }

    /// Sticky failure flag: a named selector matched a constant that
    /// could not be evaluated. The caller must fail the query; other
    /// names written before stay recorded.
    bool errored = false;

private:
    const Query &Q;
    const SourceManager &SM;
    std::vector<std::string> &FoundNames;
};

/// Resolves the bare "const::" constant query against the preprocessor
/// state and AST of the parsed translation unit: object-like #define
/// macros whose definition lives in the query's header, plus
/// namespace-scope const/constexpr variables defined in that header.
/// A lone "*" selects all of them; otherwise only the requested names
/// are reported.
///
/// Results are printed to stdout; a missing requested name (or one whose
/// value cannot be evaluated) ends the query with \c false, lines
/// written before it stay on stdout. \c "#define" values keep the macro
/// expansion text; variable values are compiler-evaluated compile-time
/// constants (integer, boolean, or floating-point).
///
/// \param Q the constant query (kind \c TargetKind::Constants).
/// \param Context AST context of the parsed translation unit.
/// \param PP preprocessor of the same translation unit.
/// \param SM source manager of the same translation unit; used to match
///           macro and variable definitions against the header path.
/// \returns true if every requested name was resolved (or "*" mode
///          found at least one constant); false otherwise.
bool processConstantQuery(const Query &Q, ASTContext &Context,
                          Preprocessor &PP, const SourceManager &SM) {
    const bool AllConstants = wildcardsEverything(Q);
    std::vector<std::string> FoundNames;

    for (const auto &Entry : PP.macros(false)) {
        const IdentifierInfo *Identifier = Entry.first;
        const MacroInfo *MI = PP.getMacroInfo(Identifier);
        if (MI == nullptr || MI->isFunctionLike() || MI->isBuiltinMacro() ||
            MI->tokens_empty() ||
            !definitionIsInHeader(SM, MI->getDefinitionLoc(), Q.headerPath))
            continue;

        const std::string Name = Identifier->getName().str();
        if (!AllConstants && std::find(Q.selectors.begin(), Q.selectors.end(), Name) ==
                                 Q.selectors.end())
            continue;

        const std::string Value = macroValueAsToml(PP, *MI);
        llvm::outs() << Q.headerPath << "::" << Name << " = " << Value << '\n';
        FoundNames.push_back(Name);
    }

    ConstantVarVisitor VarVisitor(Q, SM, FoundNames);
    VarVisitor.TraverseDecl(Context.getTranslationUnitDecl());
    if (VarVisitor.errored)
        return false;

    if (!AllConstants) {
        for (const std::string &Requested : Q.selectors) {
            if (std::find(FoundNames.begin(), FoundNames.end(), Requested) == FoundNames.end()) {
                llvm::errs() << "error: no constant named '" << Requested
                             << "' (object-like #define or const variable) defined in "
                             << Q.headerPath << "\n";
                return false;
            }
        }
    } else if (FoundNames.empty()) {
        llvm::errs() << "error: no constants found in " << Q.headerPath << "\n";
        return false;
    }
    return true;
}

/// AST visitor that resolves the enum part of a query: finds the
/// complete definition of the named enum type (first match by qualified
/// or simple name, like the class path) and reports enumerator values.
/// Nested enums (declared inside classes) resolve the same way, so
/// "enum::Outer::Kind" works like a qualified class name.
class EnumVisitor : public RecursiveASTVisitor<EnumVisitor> {
public:
    /// Prepares a visitor for one enum query.
    EnumVisitor(const Query &Q) : Q(Q) {}

    /// Reports every completed enum definition whose qualified or
    /// simple name matches the query's target; other declarations are
    /// skipped. In wildcard mode every enumerator is reported; in named
    /// mode unknown selectors are reported as errors and skipped
    /// (other requested enumerators are still processed).
    bool VisitEnumDecl(EnumDecl *ED) {
        if (!ED->isCompleteDefinition())
            return true;
        if (ED->getQualifiedNameAsString() != Q.targetName &&
            ED->getNameAsString() != Q.targetName)
            return true;

        found = true;

        if (wildcardsEverything(Q)) {
            for (const EnumConstantDecl *Constant : ED->enumerators())
                reportEnumerator(Constant);
            return true;
        }

        for (const std::string &Selector : Q.selectors) {
            const EnumConstantDecl *Constant = nullptr;
            for (const EnumConstantDecl *Candidate : ED->enumerators()) {
                if (Candidate->getNameAsString() == Selector) {
                    Constant = Candidate;
                    break;
                }
            }
            if (Constant == nullptr) {
                llvm::errs() << "error: no enumerator named '" << Selector
                             << "' in enum " << Q.targetName << "\n";
                missing = true;
                continue;
            }
            reportEnumerator(Constant);
        }
        return true;
    }

    /// True once at least one matching complete enum definition was
    /// seen during traversal; callers must report the enum as missing
    /// when this stays false.
    bool found = false;
    /// Sticky failure flag: at least one requested enumerator name does
    /// not exist in the enum; callers must fail the query.
    bool missing = false;

private:
    /// Reports one enumerator as "<Enum>::<Name> = <value>" on stdout.
    void reportEnumerator(const EnumConstantDecl *Constant) {
        const std::string Name = Constant->getNameAsString();
        const std::string Value = llvm::toString(Constant->getInitVal(), 10);
        llvm::outs() << Q.targetName << "::" << Name << " = " << Value << '\n';
    }

    const Query &Q;
};

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
        Q.selectors.begin(), Q.selectors.end(), "*") != Q.selectors.end();
    if (HasWildcard && (Q.selectors.size() != 1 || Q.selectors.front() != "*")) {
        Error = "'*' must be the only selector in a query for " + Q.targetName;
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
        Error = "each query must contain a header, a target, and at least one selector";
        return false;
    }

    Q.headerPath = Body[0];
    if (!parseTarget(Body[1], Q.kind, Q.targetName, Error))
        return false;
    Q.selectors.assign(Body.begin() + 2, Body.end());
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
/// queries and the compiler arguments after '--'.
struct CommandLine {
    /// Query arguments before '--'; filled from standard input when no
    /// query arguments were supplied.
    std::vector<std::string> preQueryArgs;
    /// Parsed queries; empty until parsing succeeded.
    std::vector<Query> queries;
    /// Compiler arguments after '--', shared by all queries.
    std::vector<std::string> compilerArgs;
};

/// Reads standard input to end and appends its query tokens to
/// \p Destinations.
///
/// A brace-set input is kept as one argument so \c parseSetQueries can
/// tokenize it; anything else is split on whitespace, matching the
/// legacy positional '<header> <target> <selector...>' form.
///
/// \param Destinations receives the query arguments in input order.
/// \param Error receives a user-facing message when reading fails.
/// \returns true on success; false when standard input could not be read
///          or contained no query text.
bool readStdinQueries(std::vector<std::string> &Destinations,
                      std::string &Error) {
    std::ostringstream Buffer;
    Buffer << std::cin.rdbuf();
    if (std::cin.bad()) {
        Error = "failed reading queries from standard input";
        return false;
    }

    const std::string Input = Buffer.str();
    const std::size_t First = Input.find_first_not_of(" \t\r\n");
    if (First == std::string::npos) {
        Error = "no query was specified on the command line or standard input";
        return false;
    }

    if (Input[First] == '{') {
        // Drop leading whitespace so the caller's brace-set detection sees
        // '{' as the first character.
        Destinations.push_back(Input.substr(First));
        return true;
    }

    std::istringstream Tokens(Input);
    std::string Token;
    while (Tokens >> Token)
        Destinations.push_back(Token);
    return true;
}

/// Parses the tool invocation into \c CommandLine form.
///
/// Accepts the legacy positional form '<header> <class> <method...>'
/// and the braced set form '{{...}, {...}}'; see the usage text. When no
/// query arguments precede '--', the same forms are read from standard
/// input. No parse failures are printed here - the caller reports
/// \p Error.
///
/// \param argc \param argv the process arguments (argv[0] is skipped).
/// \param Command receives the parsed state on success.
/// \param Error receives a user-facing message on failure.
/// \returns true on success; false on any argument or input error.
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

    for (int ArgIndex = 1; ArgIndex < Separator; ++ArgIndex)
        Command.preQueryArgs.push_back(argv[ArgIndex]);

    for (int ArgIndex = Separator + 1; ArgIndex < argc; ++ArgIndex)
        Command.compilerArgs.push_back(argv[ArgIndex]);

    if (Command.preQueryArgs.empty() && !readStdinQueries(Command.preQueryArgs, Error))
        return false;

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

    // Backwards-compatible form: <header> <target> <selector...>.
    if (Command.preQueryArgs.size() < 3) {
        Error = "expected <header.h> <Class|enum::<Enum>|const::> <select1|*> [more ...]";
        return false;
    }
    Query Q;
    Q.headerPath = Command.preQueryArgs[0];
    if (!parseTarget(Command.preQueryArgs[1], Q.kind, Q.targetName, Error))
        return false;
    Q.selectors.assign(Command.preQueryArgs.begin() + 2, Command.preQueryArgs.end());
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
/// against the AST, and emits the machine-readable report on stdout.
///
/// \param Q the query to run.
/// \param CompilerArgs arguments passed to Clang, shared by all queries.
/// \returns this query's process exit code contribution: 0 on success;
///          1 when parsing or resolution failed; 2 when the header file
///          could not be opened.
int runQuery(const Query &Q, const std::vector<std::string> &CompilerArgs) {
    {
        std::ifstream Probe(Q.headerPath);
        if (!Probe) {
            llvm::errs() << "error: couldn't open " << Q.headerPath << "\n";
            return 2;
        }
    }

    const std::string Code = "#include \"" + Q.headerPath + "\"\n";
    std::unique_ptr<ASTUnit> AST = clang::tooling::buildASTFromCodeWithArgs(
        Code, CompilerArgs, "vtable_index_analyzer_input.cpp");
    if (!AST) {
        llvm::errs() << "error: failed to parse " << Q.headerPath
                     << " (see diagnostics above)\n";
        return 1;
    }

    int Status = 0;
    switch (Q.kind) {
    case TargetKind::Constants:
        if (!processConstantQuery(Q, AST->getASTContext(), AST->getPreprocessor(),
                                  AST->getSourceManager()))
            Status = 1;
        break;
    case TargetKind::Enum: {
        EnumVisitor Visitor(Q);
        Visitor.TraverseDecl(AST->getASTContext().getTranslationUnitDecl());
        if (!Visitor.found) {
            llvm::errs() << "error: enum '" << Q.targetName
                         << "' (as a complete definition) was never found while parsing '"
                         << Q.headerPath << "' and its includes\n";
            Status = 1;
        }
        if (Visitor.missing)
            Status = 1;
        break;
    }
    case TargetKind::Class: {
        IndexVisitor Visitor(AST->getASTContext(), Q);
        Visitor.TraverseDecl(AST->getASTContext().getTranslationUnitDecl());

        if (!Visitor.found) {
            llvm::errs() << "error: class '" << Q.targetName
                         << "' (as a complete definition) was never found while parsing '"
                         << Q.headerPath << "' and its includes\n";
            Status = 1;
        }
        if (Visitor.fatalError)
            Status = 1;
        break;
    }
    }

    return Status;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        llvm::errs() << "usage: vtable-index-analyzer [<header.h> "
                         "<Class|enum::<Enum>|const::> <selector1|*> "
                         "[selector2 ...]] -- <compiler args...>\n"
                         "   or: vtable-index-analyzer [{{<header.h> <target> <selector...>}, "
                         "{<header.h> <target> <selector...>}}] -- <compiler args...>\n"
                         "   Queries omitted from the command line are read from "
                         "standard input; results are written to standard output.\n";
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
        const int Status = runQuery(Q, Command.compilerArgs);
        if (Status != 0)
            return Status;
    }

    return 0;
}
