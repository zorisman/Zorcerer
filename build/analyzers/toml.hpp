// TOML support for the compile-time vtable index analyzer: basic-string and
// key formatting for generated entries, TOML-typed encoding of macro values,
// and the merge/update routine that writes a generated table into an existing
// .toml file. Split out of VTableIndexAnalyzer.cpp so that analyzer changes
// and TOML syntax changes stay independent; the definitions are `inline` so a
// single-header include is enough and no translation unit owns the symbols.
//
// These helpers deliberately write TOML by hand instead of linking a TOML
// library: the generated files hold one table per class with scalar keys, so
// full parser is unnecessary for the update path (tomlKeyFromLine) and the
// serializer only needs to escape the subset of TOML that can appear.

#ifndef ZORCERER_ANALYZERS_TOML_HPP
#define ZORCERER_ANALYZERS_TOML_HPP

#include "clang/Basic/TokenKinds.h"
#include "clang/Lex/MacroInfo.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Lex/Token.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <vector>

inline void writeTomlBasicString(std::ostream &Out, const std::string &Value) {
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

inline void writeTomlKey(std::ostream &Out, const std::string &Key) {
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

inline std::string macroValueAsToml(const clang::Preprocessor &PP,
                                    const clang::MacroInfo &MI,
                                    unsigned Depth = 0) {
    std::string Raw;
    for (unsigned I = 0; I < MI.getNumTokens(); ++I) {
        if (I != 0)
            Raw += ' ';
        Raw += PP.getSpelling(MI.getReplacementToken(I));
    }

    if (MI.getNumTokens() == 1) {
        const clang::Token &TokenValue = MI.getReplacementToken(0);
        const std::string Spelling = PP.getSpelling(TokenValue);
        if (TokenValue.is(clang::tok::identifier) && Depth < 16) {
            if (const clang::MacroInfo *Alias =
                    PP.getMacroInfo(TokenValue.getIdentifierInfo())) {
                if (Alias != &MI && !Alias->isFunctionLike() && !Alias->tokens_empty())
                    return macroValueAsToml(PP, *Alias, Depth + 1);
            }
        }
        if (TokenValue.is(clang::tok::string_literal) && Spelling.size() >= 2 &&
            Spelling.front() == '"' && Spelling.back() == '"')
            return Spelling;
        if (TokenValue.is(clang::tok::numeric_constant)) {
            std::string Number = Spelling;
            while (!Number.empty() &&
                   (Number.back() == 'u' || Number.back() == 'U' ||
                    Number.back() == 'l' || Number.back() == 'L'))
                Number.pop_back();
            bool Decimal = !Number.empty();
            for (const char C : Number)
                Decimal = Decimal && C >= '0' && C <= '9';
            const bool HexPrefix = Number.size() > 2 && Number[0] == '0' &&
                                   (Number[1] == 'x' || Number[1] == 'X');
            bool HexDigits = HexPrefix;
            if (HexPrefix) {
                for (std::size_t I = 2; I < Number.size(); ++I) {
                    const char C = Number[I];
                    HexDigits = HexDigits &&
                        ((C >= '0' && C <= '9') || (C >= 'a' && C <= 'f') ||
                         (C >= 'A' && C <= 'F'));
                }
            }
            if ((Decimal && (Number.size() == 1 || Number[0] != '0')) ||
                HexDigits || Number == "0")
                return Number;
        }
        if (Spelling == "true" || Spelling == "false")
            return Spelling;
    }

    // Preserve complex replacement lists as strings rather than invalid TOML syntax.
    std::ostringstream Out;
    writeTomlBasicString(Out, Raw);
    return Out.str();
}

inline std::string trimLine(const std::string &Line) {
    const std::size_t First = Line.find_first_not_of(" \t\r");
    if (First == std::string::npos)
        return "";
    const std::size_t Last = Line.find_last_not_of(" \t\r");
    return Line.substr(First, Last - First + 1);
}

inline bool isTomlTableHeader(const std::string &Line) {
    const std::string Trimmed = trimLine(Line);
    return Trimmed.size() >= 2 && Trimmed.front() == '[';
}

inline std::string tomlKeyFromLine(const std::string &Line) {
    const std::size_t Equals = Line.find('=');
    if (Equals == std::string::npos)
        return "";
    return trimLine(Line.substr(0, Equals));
}

// Merge GeneratedToml (a single '[table]' header followed by key = value lines)
// into the TOML file at Path: existing entries with the same key are replaced
// in place, new entries are inserted before the table's trailing blank lines,
// and a missing table (or file) is appended. Returns 0 on success, 2 on a
// read/write failure or if nothing was generated.
inline int updateTomlFile(const std::string &Path, const std::string &GeneratedToml) {
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

#endif // ZORCERER_ANALYZERS_TOML_HPP
