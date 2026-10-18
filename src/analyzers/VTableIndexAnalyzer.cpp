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
//   --write-into also records discovered interface-version macros in ["global::Variables"].
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
#include "clang/Lex/Lexer.h"
#include "clang/Lex/MacroInfo.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Tooling/Tooling.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <utility>
#include <sys/stat.h>
#include <vector>

using namespace clang;

namespace {

struct Query {
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

// Source SDK interface versions are usually string-valued preprocessor macros,
// for example INTERFACEVERSION_VENGINESERVER = "VEngineServer023". Iterate
// the preprocessor after parsing the requested header so included headers are
// searched as well.
bool looksLikeInterfaceVersion(const std::string &Value) {
    const std::size_t LastNonDigit = Value.find_last_not_of("0123456789");
    if (LastNonDigit == std::string::npos || LastNonDigit + 1 == Value.size())
        return false;
    if (Value.size() - LastNonDigit - 1 < 2)
        return false;

    bool HasLetter = false;
    for (std::size_t Index = 0; Index <= LastNonDigit; ++Index) {
        const unsigned char C = static_cast<unsigned char>(Value[Index]);
        if ((C >= 'A' && C <= 'Z') || (C >= 'a' && C <= 'z')) {
            HasLetter = true;
        } else if (C != '_' && C != '-') {
            return false;
        }
    }
    return HasLetter;
}

void appendFactoryVersions(Preprocessor &PP, std::ostream &Output) {
    std::vector<std::pair<std::string, std::string>> Versions;

    for (const auto &Entry : PP.macros()) {
        const IdentifierInfo *Identifier = Entry.first;
        if (Identifier == nullptr)
            continue;

        const std::string MacroName = Identifier->getName().str();
        if (MacroName.find("VERSION") == std::string::npos &&
            MacroName.find("INTERFACE") == std::string::npos)
            continue;

        const MacroInfo *Info = PP.getMacroInfo(Identifier);
        if (Info == nullptr || Info->isFunctionLike() || Info->getNumTokens() != 1)
            continue;

        const Token &ValueToken = Info->tokens().front();
        if (!ValueToken.is(tok::string_literal))
            continue;

        bool InvalidSpelling = false;
        const std::string Spelling = Lexer::getSpelling(
            ValueToken, PP.getSourceManager(), PP.getLangOpts(), &InvalidSpelling);
        if (InvalidSpelling || Spelling.size() < 2 ||
            Spelling.front() != '"' || Spelling.back() != '"')
            continue;

        const std::string Value = Spelling.substr(1, Spelling.size() - 2);
        if (looksLikeInterfaceVersion(Value))
            Versions.emplace_back(MacroName, Value);
    }

    if (Versions.empty())
        return;

    std::sort(Versions.begin(), Versions.end(),
              [](const auto &A, const auto &B) { return A.first < B.first; });

    // ':' requires a quoted table name in TOML.
    Output << "[\"global::Variables\"]\n";
    for (const auto &Version : Versions)
        Output << Version.first << " = \"" << Version.second << "\"\n";
}

} // namespace

int main(int argc, char **argv) {
    // Deliberately plain argv handling rather than
    // clang::tooling::CommonOptionsParser: that helper's own API
    // (CommonOptionsParser::create returning llvm::Expected, vs. older
    // constructor-based forms) has changed shape across LLVM releases
    // more than the lower-level pieces this tool actually depends on.
    if (argc < 4) {
        llvm::errs() << "usage: vtable-index-analyzer <header.h> <ClassName> "
                         "<method1|*> [method2 ...] [--write-into <file.toml>] "
                         "-- <compiler args...>\n";
        return 2;
    }

    const std::string headerPath = argv[1];
    Query Q;
    Q.className = argv[2];

    std::vector<std::string> extraArgs;
    int i = 3;
    for (; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--") {
            ++i;
            break;
        }
        if (arg == "--write-into") {
            if (i + 1 >= argc || std::string(argv[i + 1]) == "--") {
                llvm::errs() << "error: --write-into requires a file path\n";
                return 2;
            }
            Q.writeIntoPath = argv[++i];
            continue;
        }
        Q.methodNames.push_back(arg);
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

    // Buffer the generated table first. updateTomlFile() then merges its entries
    // into an existing class table instead of blindly appending duplicate keys.
    std::ostringstream tomlBuffer;

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

    IndexVisitor Visitor(AST->getASTContext(), Q,
                         Q.writeIntoPath.empty() ? nullptr : &tomlBuffer);
    Visitor.TraverseDecl(AST->getASTContext().getTranslationUnitDecl());

    if (!Visitor.found) {
        llvm::errs() << "error: class '" << Q.className
                     << "' (as a complete definition) was never found while "
                        "parsing this header and its includes\n";
        return 1;
    }
    if (Visitor.fatal_error)
        return 1;

    if (!Q.writeIntoPath.empty()) {
        const int WriteResult = updateTomlFile(Q.writeIntoPath, tomlBuffer.str());
        if (WriteResult != 0)
            return WriteResult;

        std::ostringstream variablesBuffer;
        appendFactoryVersions(AST->getPreprocessor(), variablesBuffer);
        const std::string variablesToml = variablesBuffer.str();
        if (variablesToml.empty()) {
            llvm::errs() << "warning: no interface-version string macros found in the parsed headers\n";
        } else {
            const int VariablesWriteResult =
                updateTomlFile(Q.writeIntoPath, variablesToml);
            if (VariablesWriteResult != 0)
                return VariablesWriteResult;
        }
    }

    return 0;
}
