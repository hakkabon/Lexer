//
//  TokenStreams.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/06.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import Grammar
import Tokenizer

// MARK: - LexerTokenStream (option 1: DFA-driven)

/// Adapts the token array produced by a `LexerBuilder`-built DFA `Lexer` to
/// `TokenStream`.
///
/// A `LexerToken`'s lexeme is always a `Substring` of the original source,
/// so its `Range<String.Index>` comes for free from `lexeme.startIndex ..<
/// lexeme.endIndex` — no separate offset bookkeeping is needed here.
public struct LexerTokenStream: TokenStream {

    private let tokens: [LexerToken]
    public let source: String

    /// Wraps an already-scanned token array, e.g. the `.success` payload of
    /// `Lexer.tokenize(_:)`.
    public init(tokens: [LexerToken], source: String) {
        self.tokens = tokens
        self.source = source
    }

    /// Scans `source` with `lexer` and wraps the result.
    ///
    /// - Throws: the `LexerError` `lexer.tokenize(_:)` reports if scanning
    ///   gets stuck before reaching the end of `source`.
    public init(source: String, lexer: Lexer) throws {
        self.source = source
        switch lexer.tokenize(source) {
        case .success(let tokens):
            self.tokens = tokens
        case .failure(let error):
            throw error
        }
    }

    public var count: Int { tokens.count }

    public func terminal(at position: Int) -> (terminal: Terminal, range: Range<String.Index>) {
        let token = tokens[position]
        return (
            terminal: Terminal(string: String(token.lexeme)),
            range: token.lexeme.startIndex..<token.lexeme.endIndex
        )
    }
}

// MARK: - TokenizerStream (option 2: hand-written Tokenizer)

/// Adapts the token array produced by GrammarTokenizer's hand-written
/// `Tokenizer` (or `InputTokenizer`) to `TokenStream`.
///
/// Unlike `LexerToken`, GrammarTokenizer's `Token` stores only a
/// `Range<String.Index>`, not its own lexeme text, so `source` is kept
/// alongside the token array to recover it where needed (`.number`, `.eof`).
public struct TokenizerStream: TokenStream {

    private let tokens: [Token]
    public let source: String

    /// Wraps an already-scanned token array, e.g. the result of
    /// `Tokenizer(_:symbols:keywords:).tokenize()`.
    public init(tokens: [Token], source: String) {
        self.tokens = tokens
        self.source = source
    }

    /// Tokenizes `source` with a general-purpose `Tokenizer` configured with
    /// `symbols`/`keywords`, then wraps the result. This is the streaming
    /// equivalent of what `EarleyParser.parse(_:)` (and its peers) used to
    /// do inline before `TokenStream` existed.
    public init(source: String, symbols: Set<String> = [], keywords: Set<String> = []) {
        self.source = source
        self.tokens = Tokenizer(source, symbols: symbols, keywords: keywords).tokenize()
    }

    public var count: Int { tokens.count }

    /// Maps a GrammarTokenizer `TokenType` to the `Terminal` a grammar's
    /// alphabet is tested against.
    ///
    /// Every case that carries a `String` payload becomes `Terminal.string`
    /// keyed on that payload's own text — the payload *is* the lexeme, so
    /// this is exact, not a category-name stand-in. `.number` normalizes to
    /// its decimal value, matching prior behaviour. `.eof` maps to the
    /// grammar's own end-of-input meta-terminal. `.invalid` means the
    /// tokenizer itself got stuck; that is surfaced as a thrown error rather
    /// than silently coerced into some terminal, so the parser can report it
    /// as a syntax error instead of misinterpreting garbage input.
    ///
    /// - Throws: the `TokenError` GrammarTokenizer recorded, if the token at
    ///   `position` is `.invalid`.
    public func terminal(at position: Int) throws -> (terminal: Terminal, range: Range<String.Index>) {
        let token = tokens[position]
        switch token.type {
        case .symbol(let text), .literal(let text), .identifier(let text),
             .keyword(let text), .regex(let text), .comment(let text):
            return (terminal: Terminal(string: text), range: token.range)
        case .char(let character):
            return (terminal: Terminal(string: String(character)), range: token.range)
        case .number(let numeric):
            return (terminal: Terminal(string: "\(numeric.intValue)"), range: token.range)
        case .eof:
            return (terminal: .meta(.eof), range: token.range)
        case .invalid(let tokenError):
            throw tokenError
        }
    }
}
