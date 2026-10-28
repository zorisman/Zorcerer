// Literal formatting for the compile-time vtable index analyzer.
//
// The analyzer no longer writes TOML documents; its stdout lines carry
// `name = value` pairs whose value is a literal that the Zig adapter
// classifies as a string, integer, boolean, or float. This header keeps
// only the helper that turns one object-like macro definition into such
// a literal, split out of VTableIndexAnalyzer.cpp so analyzer changes
// and literal-syntax changes stay independent. The definitions are
// `inline`, so a single-header include is enough and no translation unit
// owns the symbols.
//
// The helper deliberately formats literals by hand instead of linking a
// TOML library: it only needs the subset of TOML scalar syntax that SDK
// constants use (basic strings, decimal/hex integers, booleans).

#ifndef ZORCERER_ANALYZERS_TOML_HPP
#define ZORCERER_ANALYZERS_TOML_HPP

#include "clang/Basic/TokenKinds.h"
#include "clang/Lex/MacroInfo.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Lex/Token.h"

#include <sstream>
#include <string>

/// Writes \p Value as a TOML basic string, escaping the characters that
/// cannot appear verbatim inside double quotes.
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

/// Formats the replacement list of an object-like macro as a literal.
///
/// A single-token macro resolves to its spelling when that is a string,
/// numeric, or boolean literal; a single identifier is followed through
/// its own object-like definition (up to \p Depth aliases). Any other
/// replacement list is preserved as a quoted basic string so the emitted
/// line still has a well-formed value.
///
/// \param PP preprocessor that owns \p MI and can resolve aliases.
/// \param MI the macro definition to format.
/// \param Depth current alias-following depth; callers normally omit it.
/// \returns the literal text, without a trailing newline.
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

    // Preserve complex replacement lists as strings rather than invalid syntax.
    std::ostringstream Out;
    writeTomlBasicString(Out, Raw);
    return Out.str();
}

#endif // ZORCERER_ANALYZERS_TOML_HPP
