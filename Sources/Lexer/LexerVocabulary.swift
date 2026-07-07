//
//  LexerVocabulary.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/06.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import LexerFSA

/// Bootstraps a `LexerBuilder` from any `GrammarVocabulary`, automating the
/// keyword-vs-identifier priority problem so a caller never has to think
/// about `TokenClass` priorities by hand.
public extension LexerBuilder {

    /// Registers `vocabulary`'s keywords, symbols, and patterns as lexer
    /// rules, in that priority order (keywords beat symbols beat patterns on
    /// an exact-length tie — see below), and marks any tag present in
    /// `vocabulary.skippedTypes` as a skip rule.
    ///
    /// ### Why priority, not word-boundary anchoring
    /// The obvious-looking fix for `"if"` (keyword) colliding with
    /// `[a-zA-Z_][a-zA-Z0-9_]*` (identifier) is to anchor the keyword with
    /// something like `\bif\b`. That doesn't apply here, for two reasons:
    ///
    /// 1. Lexer-FSA's regex engine is a classical Thompson/DFA engine over a
    ///    dk.brics.automaton-style grammar — it has no `\b` boundary
    ///    assertion (boundaries aren't a regular-language primitive in this
    ///    engine; see `RegexParser.swift`).
    /// 2. It isn't needed anyway. This engine's `Lexer` already implements
    ///    **maximal munch**: at every position it keeps scanning as long as
    ///    *some* rule can still extend the match, and emits the longest one.
    ///    So `"iffy"` never stops at `"if"` — the identifier rule keeps
    ///    matching through all four characters, and length 4 beats length 2.
    ///    The *only* real ambiguity is an exact-length tie: the input `"if"`
    ///    alone matches both the keyword rule and the identifier rule at
    ///    length 2. That is exactly what `TokenClass.priority` resolves —
    ///    the determinizer keeps the lowest-priority-integer tag for a given
    ///    accepting state — so keywords (priority 0) win over symbols
    ///    (priority 1), which win over patterns (priority 2), on a tie, with
    ///    no anchoring required.
    ///
    /// ### Why literals are quoted, not backslash-escaped
    /// Grammar symbols are frequently made of exactly the characters this
    /// regex engine treats as metacharacters (`+ * ( ) [ ] { } | < > ; : ,`),
    /// so a literal keyword or symbol can't be registered as-is. The
    /// straightforward fix — backslash-escape every character — is a trap
    /// here: this engine's escape table gives `\n`, `\t`, and `\r` their
    /// *control-character* meanings (newline/tab/carriage-return), not the
    /// literal letters 'n', 't', 'r' (see `RegexParser.parseCharExp()`), so
    /// blanket per-character escaping silently corrupts any keyword
    /// containing one of those letters — `"return"`, `"int"`, `"print"`,
    /// … . Wrapping the literal in double quotes instead (`"if"` written as
    /// the four-character pattern `"if"`) uses this engine's dedicated
    /// quoted-string syntax, under which everything up to the closing quote
    /// is taken verbatim with no escape processing at all — exactly the
    /// "this string, and only this string" semantics an exact keyword or
    /// symbol match needs.
    ///
    /// `vocabulary.patterns` entries are passed through unescaped, since
    /// they are meant to already be valid Lexer-FSA regex source (as the
    /// protocol's own doc comment shows for an identifier pattern).
    @discardableResult
    mutating func loadVocabulary(_ vocabulary: GrammarVocabulary) -> LexerBuilder {
        // Continue numbering from whatever ids are already in use, so this
        // can be combined with rules registered by hand (addRule/addSkip)
        // on the same builder without id collisions.
        var nextId = (rules.map(\.token.id).max() ?? -1) + 1
        func freshId() -> Int { defer { nextId += 1 }; return nextId }

        // 1. Keywords — exact match, highest priority (0).
        for (keyword, tag) in vocabulary.keywords {
            addRule(
                pattern: Self.literalPattern(for: keyword),
                token: TokenClass(id: freshId(), name: String(describing: tag), priority: 0),
                skipped: vocabulary.skippedTypes.contains(tag)
            )
        }

        // 2. Symbols — exact match, priority 1.
        for (symbol, tag) in vocabulary.symbols {
            addRule(
                pattern: Self.literalPattern(for: symbol),
                token: TokenClass(id: freshId(), name: String(describing: tag), priority: 1),
                skipped: vocabulary.skippedTypes.contains(tag)
            )
        }

        // 3. Patterns — regex match, lowest priority (2), so an exact
        //    keyword/symbol always wins a same-length tie against a general
        //    pattern such as an identifier or number rule.
        for (pattern, tag) in vocabulary.patterns {
            addRule(
                pattern: pattern,
                token: TokenClass(id: freshId(), name: String(describing: tag), priority: 2),
                skipped: vocabulary.skippedTypes.contains(tag)
            )
        }

        return self
    }

    /// Builds a Lexer-FSA regex pattern that matches `literal` exactly and
    /// only `literal`, using the engine's quoted-string syntax (`"…"`) so
    /// none of `literal`'s characters are reinterpreted as metacharacters or
    /// mis-escaped. See `loadVocabulary(_:)` for the full rationale.
    ///
    /// - Precondition: `literal` must not contain a `"` character — the
    ///   quoted-string form has no escape for an embedded quote, and no
    ///   realistic grammar keyword or symbol needs one.
    private static func literalPattern(for literal: String) -> String {
        precondition(
            !literal.contains("\""),
            "GrammarVocabulary literal \"\(literal)\" contains a double quote, which Lexer-FSA's quoted-string syntax cannot represent"
        )
        return "\"\(literal)\""
    }
}
