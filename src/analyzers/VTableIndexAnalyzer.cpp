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
//   vtable-index-analyzer '{{<header.h> <ClassName> <method...>}, {<header.h> <ClassName> <method...>}}' [--write-into <file.toml>] -- <compiler args...>
//   vtable-index-analyzer --read-from <config.toml> [--write-into <file.toml>] -- <compiler args...>
//
// Example, for TF2's hl2sdk-tf2 checkout:
//   vtable-index-analyzer hl2sdk-tf2/public/eiface.h IVEngineServer \
//       LogPrint ServerCommand -- \
//       -I hl2sdk-tf2/public -I hl2sdk-tf2/public/engine -I hl2sdk-tf2/public/tier1 \
//       -DCOMPILER_GCC -DPOSIX -D_LINUX -DGNUC -std=gnu++14 -m32
//
// --read-from reads a config file instead of the <header.h> <ClassName>
// <method...> triple (or the brace-set form) - it replaces that argument
// entirely, not combines with it. Schema (see analyzer.toml for a worked
// example):
//
//   [root]
//   path = "extern/source/source-sdk-2013/src"
//
//   [[class]]
//   header = "game/server/baseentity.h"   # joined onto [root].path
//   name = "CBaseEntity"
//   methods = ["*"]                        # or a list of specific names
//
//   [[class]]
//   header = "public/eiface.h"
//   name = "IVEngineServer"
//   methods = ["ServerCommand", "LogPrint"]
//
// Each [[class]] becomes exactly one Query, fed through the same
// IndexVisitor/writeTomlEntry path as the other two input forms - the
// only thing --read-from changes is where Queries come from, not how
// they're resolved or reported. This is a deliberately minimal TOML
// subset (flat key = "string" pairs and one array-of-strings field, no
// escapes, no nested tables, no non-string values) - the same scope
// restriction as this file's own --write-into output.
//
// No exceptions, no RTTI: this file was already free of both (Clang/
// LLVM's dyn_cast is its own RTTI-free mechanism, not dynamic_cast/
// typeid, and nothing here used try/throw/catch to begin with) - the
// --read-from config parser added below keeps that property, using bool
// returns and an out-param error string instead of exceptions, and
// guarding every std::string::substr call against the out-of-range
// cases that would otherwise throw.
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
#include <sys/stat.h>
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

    bool found = false;
    bool fatal_error = false;

private:
    static void writeTomlBasicString(std::ostream &Out, const std::string &Value) {
        Out << '"';
        for (const char C : Value) {
            switch (C) {
            case '\\': Out << "\\\\"; break;
            case '"': Out << "\\\""; break;
            case '\n': Out << "\\n"; break;
            case '\r': Out << "\\r"; break;
            case '\t': Out << "\\t"; break;
            default: Out << C; break;
            }
        }
        Out << '"';
    }

    static void writeTomlKey(std::ostream &Out, const std::string &Key) {
        // TOML bare keys may contain only ASCII letters, digits, '_' and '-'.
        const bool BareKey = !Key.empty() &&
            std::all_of(Key.begin(), Key.end(), [](unsigned char C) {
                return (C >= 'A' && C <= 'Z') || (C >= 'a' && C <= 'z') ||
                       (C >= '0' && C <= '9') || C == '_' || C == '-';
            });
        if (BareKey)
            Out << Key;
        else
            writeTomlBasicString(Out, Key);
    }

    void writeTomlEntry(const std::string &MethodName, uint64_t Index,
                        bool EnsureUniqueKey) {
        if (Output == nullptr)
            return;

        std::string Key = MethodName;
        if (EnsureUniqueKey &&
            std::find(WrittenKeys.begin(), WrittenKeys.end(), Key) != WrittenKeys.end()) {
            Key += "@" + std::to_string(Index);
        }
        WrittenKeys.push_back(Key);

        if (!OutputHeaderWritten) {
            // A quoted table key is required because ':' is not allowed in a TOML bare key.
            *Output << "[";
            writeTomlBasicString(*Output, "class::" + Q.className);
            *Output << "]\n";
            OutputHeaderWritten = true;
        }

        writeTomlKey(*Output, Key);
        *Output << " = " << Index << '\n';
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

std::string trimLine(const std::string &Line) {
    const std::size_t First = Line.find_first_not_of(" \t\r");
    if (First == std::string::npos)
        return "";
    const std::size_t Last = Line.find_last_not_of(" \t\r");
    return Line.substr(First, Last - First + 1);
}

bool isTomlTableHeader(const std::string &Line) {
    const std::string Trimmed = trimLine(Line);
    return Trimmed.size() >= 2 && Trimmed.front() == '[';
}

std::string tomlKeyFromLine(const std::string &Line) {
    const std::size_t Equals = Line.find('=');
    if (Equals == std::string::npos)
        return "";
    return trimLine(Line.substr(0, Equals));
}

int updateTomlFile(const std::string &Path, const std::string &GeneratedToml) {
    std::istringstream GeneratedStream(GeneratedToml);
    std::vector<std::string> GeneratedLines;
    std::string Line;
    while (std::getline(GeneratedStream, Line))
        GeneratedLines.push_back(Line);

    if (GeneratedLines.empty()) {
        llvm::errs() << "error: no TOML entries were generated\n";
        return 2;
    }

    const std::string TargetHeader = trimLine(GeneratedLines.front());
    std::vector<std::string> Lines;
    {
        std::ifstream Input(Path);
        if (Input.is_open()) {
            while (std::getline(Input, Line))
                Lines.push_back(Line);
            const bool ReadFailed = Input.bad();
            Input.close();
            if (ReadFailed) {
                llvm::errs() << "error: failed reading TOML file " << Path << "\n";
                return 2;
            }
        } else {
            struct stat FileInfo;
            if (::stat(Path.c_str(), &FileInfo) == 0) {
                llvm::errs() << "error: couldn't read existing TOML file " << Path << "\n";
                return 2;
            }
            // A missing file is allowed; it will be created below.
        }
    }

    std::size_t SectionStart = Lines.size();
    for (std::size_t Index = 0; Index < Lines.size(); ++Index) {
        if (trimLine(Lines[Index]) == TargetHeader) {
            SectionStart = Index;
            break;
        }
    }

    if (SectionStart == Lines.size()) {
        if (!Lines.empty() && !Lines.back().empty())
            Lines.push_back("");
        Lines.push_back(TargetHeader);
        for (std::size_t Index = 1; Index < GeneratedLines.size(); ++Index)
            Lines.push_back(GeneratedLines[Index]);
    } else {
        std::size_t SectionEnd = SectionStart + 1;
        while (SectionEnd < Lines.size() && !isTomlTableHeader(Lines[SectionEnd]))
            ++SectionEnd;

        // Insert new methods before trailing blank lines that separate this table
        // from the next one. Existing entries are replaced in place, even if the
        // generated index is identical to the stored value.
        std::size_t InsertAt = SectionEnd;
        while (InsertAt > SectionStart + 1 && trimLine(Lines[InsertAt - 1]).empty())
            --InsertAt;

        for (std::size_t NewIndex = 1; NewIndex < GeneratedLines.size(); ++NewIndex) {
            const std::string &NewEntry = GeneratedLines[NewIndex];
            const std::string NewKey = tomlKeyFromLine(NewEntry);
            if (NewKey.empty())
                continue;

            bool Replaced = false;
            for (std::size_t ExistingIndex = SectionStart + 1;
                 ExistingIndex < SectionEnd; ++ExistingIndex) {
                if (tomlKeyFromLine(Lines[ExistingIndex]) == NewKey) {
                    Lines[ExistingIndex] = NewEntry;
                    Replaced = true;
                    break;
                }
            }

            if (!Replaced) {
                Lines.insert(Lines.begin() + InsertAt, NewEntry);
                ++InsertAt;
                ++SectionEnd;
            }
        }
    }

    std::ofstream Output(Path, std::ios::out | std::ios::trunc);
    if (!Output.is_open()) {
        llvm::errs() << "error: couldn't open TOML output file " << Path << "\n";
        return 2;
    }

    for (const std::string &OutputLine : Lines) {
        Output << OutputLine << '\n';
        if (!Output) {
            llvm::errs() << "error: failed writing TOML output file " << Path << "\n";
            Output.close();
            return 2;
        }
    }

    Output.close();
    if (!Output) {
        llvm::errs() << "error: failed closing TOML output file " << Path << "\n";
        return 2;
    }
    return 0;
}

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

// ---- --read-from config file parsing ----
// See the file's top comment for the schema. Deliberately minimal: flat
// `key = "string"` pairs, one `[root]` table, any number of `[[class]]`
// array-of-tables entries, `#` comments. No escapes, no nested tables, no
// non-string values - matching this tool's existing --write-into output
// scope rather than a general-purpose TOML implementation.

bool parseQuotedTomlString(const std::string &Raw, std::string &Out) {
    const std::string Trimmed = trimLine(Raw);
    if (Trimmed.size() < 2 || Trimmed.front() != '"' || Trimmed.back() != '"')
        return false;
    // No escape handling, by design - see the module comment.
    Out = Trimmed.substr(1, Trimmed.size() - 2);
    return true;
}

bool parseTomlStringArray(const std::string &Raw, std::vector<std::string> &Out,
                          std::string &Error) {
    const std::string Trimmed = trimLine(Raw);
    if (Trimmed.size() < 2 || Trimmed.front() != '[' || Trimmed.back() != ']') {
        Error = "expected an array of quoted strings, got: " + Raw;
        return false;
    }
    const std::string Inner = Trimmed.substr(1, Trimmed.size() - 2);
    Out.clear();
    std::size_t Pos = 0;
    while (Pos < Inner.size()) {
        const std::size_t Comma = Inner.find(',', Pos);
        const std::string Item = trimLine(
            Comma == std::string::npos ? Inner.substr(Pos) : Inner.substr(Pos, Comma - Pos));
        if (!Item.empty()) {
            std::string Value;
            if (!parseQuotedTomlString(Item, Value)) {
                Error = "expected a quoted string in array, got: " + Item;
                return false;
            }
            Out.push_back(Value);
        }
        if (Comma == std::string::npos)
            break;
        Pos = Comma + 1;
    }
    return true;
}

// Reads `Path` and appends one Query per [[class]] entry to `Queries`.
// `Queries` is only appended to on full success (an error partway through
// doesn't leave a partially-populated result for the caller to trip
// over) - everything is built into locals and only pushed in `FlushCurrent`,
// which itself bails out through `Error` the same way every other
// function here does, no throw involved.
bool parseConfigFile(const std::string &Path, std::vector<Query> &Queries,
                     std::string &Error) {
    std::ifstream File(Path);
    if (!File.is_open()) {
        Error = "couldn't open " + Path;
        return false;
    }

    std::vector<Query> Parsed;

    enum class Section { None, Root, Class };
    Section CurrentSection = Section::None;

    std::string RootPath;
    bool HaveRootPath = false;

    struct PendingClass {
        std::string header;
        std::string name;
        std::vector<std::string> methods;
        bool haveHeader = false;
        bool haveName = false;
        bool haveMethods = false;
    };
    PendingClass Current;
    bool HaveCurrent = false;

    auto FlushCurrent = [&](std::string &FlushError) -> bool {
        if (!HaveCurrent)
            return true;
        if (!Current.haveHeader || !Current.haveName || !Current.haveMethods) {
            FlushError = "every [[class]] needs header, name, and methods";
            return false;
        }

        Query Q;
        Q.headerPath = HaveRootPath ? (RootPath + "/" + Current.header) : Current.header;
        Q.className = Current.name;
        Q.methodNames = Current.methods;

        const bool HasWildcard = std::find(
            Q.methodNames.begin(), Q.methodNames.end(), "*") != Q.methodNames.end();
        if (HasWildcard && (Q.methodNames.size() != 1 || Q.methodNames.front() != "*")) {
            FlushError = "'*' must be the only method selector for " + Q.className;
            return false;
        }

        Parsed.push_back(Q);
        Current = PendingClass();
        HaveCurrent = false;
        return true;
    };

    std::string RawLine;
    while (std::getline(File, RawLine)) {
        const std::string Line = trimLine(RawLine);
        if (Line.empty() || Line.front() == '#')
            continue;

        if (Line.front() == '[') {
            if (!FlushCurrent(Error))
                return false;

            if (Line.size() >= 4 && Line.compare(0, 2, "[[") == 0 &&
                Line.compare(Line.size() - 2, 2, "]]") == 0) {
                const std::string TableName = trimLine(Line.substr(2, Line.size() - 4));
                if (TableName != "class") {
                    Error = "unknown table array '[[" + TableName + "]]'";
                    return false;
                }
                CurrentSection = Section::Class;
                HaveCurrent = true;
                continue;
            }
            if (Line.back() == ']') {
                const std::string TableName = trimLine(Line.substr(1, Line.size() - 2));
                if (TableName == "root") {
                    CurrentSection = Section::Root;
                    continue;
                }
                Error = "unknown table '[" + TableName + "]'";
                return false;
            }
            Error = "malformed table header: " + Line;
            return false;
        }

        const std::size_t Equals = Line.find('=');
        if (Equals == std::string::npos) {
            Error = "expected 'key = value', got: " + Line;
            return false;
        }
        const std::string Key = trimLine(Line.substr(0, Equals));
        const std::string Value = trimLine(Line.substr(Equals + 1));

        if (CurrentSection == Section::Root) {
            if (Key == "path") {
                if (!parseQuotedTomlString(Value, RootPath)) {
                    Error = "[root].path must be a quoted string";
                    return false;
                }
                HaveRootPath = true;
            } else {
                Error = "unknown key '" + Key + "' in [root]";
                return false;
            }
        } else if (CurrentSection == Section::Class) {
            if (Key == "header") {
                if (!parseQuotedTomlString(Value, Current.header)) {
                    Error = "[[class]].header must be a quoted string";
                    return false;
                }
                Current.haveHeader = true;
            } else if (Key == "name") {
                if (!parseQuotedTomlString(Value, Current.name)) {
                    Error = "[[class]].name must be a quoted string";
                    return false;
                }
                Current.haveName = true;
            } else if (Key == "methods") {
                if (!parseTomlStringArray(Value, Current.methods, Error))
                    return false;
                if (Current.methods.empty()) {
                    Error = "[[class]].methods must have at least one entry";
                    return false;
                }
                Current.haveMethods = true;
            } else {
                Error = "unknown key '" + Key + "' in [[class]]";
                return false;
            }
        } else {
            Error = "key-value pair outside of any table: " + Line;
            return false;
        }
    }

    if (!FlushCurrent(Error))
        return false;

    if (!HaveRootPath) {
        Error = "[root].path is required";
        return false;
    }
    if (Parsed.empty()) {
        Error = "config file defined no [[class]] entries";
        return false;
    }

    Queries.insert(Queries.end(), Parsed.begin(), Parsed.end());
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
                         "[--write-into <file.toml>] -- <compiler args...>\n"
                         "   or: vtable-index-analyzer --read-from <config.toml> "
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
    std::string ReadFromPath;
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
        if (Arg == "--read-from") {
            if (ArgIndex + 1 >= Separator) {
                llvm::errs() << "error: --read-from requires a file path before '--'\n";
                return 2;
            }
            ReadFromPath = argv[++ArgIndex];
            continue;
        }
        QueryArguments.push_back(Arg);
    }

    std::vector<std::string> ExtraArgs;
    if (Separator < argc) {
        for (int ArgIndex = Separator + 1; ArgIndex < argc; ++ArgIndex)
            ExtraArgs.push_back(argv[ArgIndex]);
    }

    std::vector<Query> Queries;

    if (!ReadFromPath.empty()) {
        // --read-from replaces the <header.h> <ClassName> <method...>
        // triple (and the brace-set form) entirely - it's not meant to be
        // combined with either, so catch that rather than silently
        // ignoring whichever one the caller didn't mean to pass.
        if (!QueryArguments.empty()) {
            llvm::errs() << "error: --read-from replaces <header.h> <ClassName> "
                            "<method...> (or a brace-set query) - don't pass both\n";
            return 2;
        }
        std::string ConfigError;
        if (!parseConfigFile(ReadFromPath, Queries, ConfigError)) {
            llvm::errs() << "error: " << ReadFromPath << ": " << ConfigError << "\n";
            return 2;
        }
    } else {
        if (QueryArguments.empty()) {
            llvm::errs() << "error: no query was specified\n";
            return 2;
        }

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
