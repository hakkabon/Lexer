//
//  TokenStream.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/06.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import Grammar

/// The abstract interface a parser (Earley, CYK, LL, LR, RNGLR, GLR, …)
/// pulls tokens through, regardless of which front end produced them.
///
/// Two front ends satisfy this protocol today:
///  - `LexerTokenStream` wraps the array a `LexerBuilder`-built DFA `Lexer`
///    produces — the fully automated, `GrammarVocabulary`-driven path.
///  - `TokenizerStream` wraps the array GrammarTokenizer's hand-written
///    `Tokenizer` (or `InputTokenizer`) produces — the fixed-category path.
///
/// A parser only ever needs three things from a stream: how many tokens
/// there are, the original source text (for building human-readable
/// diagnostics around a range), and — for each position — the `Terminal` to
/// test against the grammar's alphabet plus the `Range<String.Index>` of the
/// source text it came from. Everything else about a token (its category,
/// its concrete representation) stays private to whichever tokenizer or
/// lexer produced it; two structurally unrelated `Token` types can both
/// drive the same parser without either one leaking into the parser's API.
///
/// Random access (an indexed `terminal(at:)`, rather than a `next()`/`peek()`
/// cursor) is deliberate. Earley's chart needs `chart[i]`, and GLR/RNGLR fork
/// parse state at a position and must be able to re-read that same position
/// from more than one continuation — something a single-pass iterator can't
/// support once it has advanced past it. Both built-in streams materialize
/// their token array eagerly, so this is always safe.
public protocol TokenStream {
    /// The original source text this stream was scanned from. Used for
    /// building diagnostics (line/column, surrounding context) around a
    /// `Range<String.Index>` returned by `terminal(at:)`.
    var source: String { get }

    /// The number of tokens in the stream.
    var count: Int { get }

    /// The `Terminal` to test against the grammar's alphabet at `position`,
    /// together with the range of `source` it spans.
    ///
    /// - Throws: if the underlying tokenizer/lexer recorded a lexical error
    ///   at this position (e.g. an unrecognized character or an un-lexable
    ///   sequence). A parser should surface this as its own syntax error
    ///   rather than continue scanning past it.
    func terminal(at position: Int) throws -> (terminal: Terminal, range: Range<String.Index>)
}

public extension TokenStream {
    /// All `(terminal, range)` pairs in order.
    ///
    /// Convenience for callers that want the whole stream materialized up
    /// front (e.g. to precompute the ranges an SPPF/CST extraction step
    /// needs) rather than pulling position by position.
    func terminals() throws -> [(terminal: Terminal, range: Range<String.Index>)] {
        try (0..<count).map { try terminal(at: $0) }
    }
}
