//
//  Lexer.swift
//  Lexer
//
//  Created by code review on 2026/06/17.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import LexerFSA

/// A streaming lexer over a deterministic finite-state automaton.
///
/// `Lexer` implements the **maximal-munch** (longest-match) rule used by
/// scanner generators such as lex/flex:
///
///   1. Begin at the current source offset and the DFA's initial state.
///   2. Consume characters one at a time, walking the DFA's transition
///      function. Whenever an accepting state is reached, remember it
///      along with the offset at which it was reached ("last accept").
///   3. Stop when either the input is exhausted or the DFA has no
///      transition for the next character.
///   4. If a last-accept was recorded, emit a token for the slice
///      `[start .. lastAcceptOffset]`, look up its `TokenClass` in the
///      DFA's `tokenMap`, advance the source offset to `lastAcceptOffset`,
///      and continue.
///   5. If no last-accept was recorded, the scanner is stuck — emit
///      `.unexpectedCharacter(offset:)` or `.noMatch(offset:)` and stop.
///
/// Whitespace / comments are handled by attaching a low-priority `SKIP`
/// `TokenClass` to the corresponding pattern, then dropping those tokens
/// from the output stream of the parser.
///
/// **Requirement**: the input `DFSA` must be deterministic. The
/// `init(_ regex:)` convenience initializer handles this automatically:
/// if the regex is still an ε-NFA (the form Thompson's construction
/// produces), it is determinized in place before the lexer is built, so a
/// freshly-parsed `Regex` is always safe to lex. For a hand-constructed
/// `NFSA`, call `nfa.determinize()` first.
public struct Lexer {

    /// The deterministic automaton this lexer drives.
    public let dfa: DFSA

    /// Token-class names whose tokens should be dropped from the output of
    /// `tokenize(_:skipping:)`. Populated by `LexerBuilder.build()` from the
    /// rules registered via `addSkip` (or with `skipped: true`). Empty for a
    /// lexer constructed directly from a `DFSA`/`Regex`, which preserves the
    /// previous behaviour of emitting every token.
    public let skippedTokenNames: Set<String>

    /// Creates a lexer over the given DFA. The DFA must already be
    /// deterministic; constructing a lexer over an NFA is a programmer
    /// error and will trap at the first call to `nextToken`. No token
    /// classes are skipped.
    public init(_ dfa: DFSA) {
        self.dfa = dfa
        self.skippedTokenNames = []
    }

    /// Internal initializer used by `LexerBuilder.build()` to record which
    /// token-class names were registered as skip rules.
    init(_ dfa: DFSA, skippedTokenNames: Set<String>) {
        self.dfa = dfa
        self.skippedTokenNames = skippedTokenNames
    }

    /// Convenience initializer over a `Regex`. The regex is determinized
    /// automatically if it is still a Thompson ε-NFA (the form produced by
    /// `Regex(_ pattern:)`), so a freshly-parsed regex is always safe to
    /// lex. A regex that is already `.dfa` is wrapped as-is.
    public init(_ regex: Regex) {
        self.skippedTokenNames = []
        switch regex.state {
        case .nfa:
            // A Thompson regex is an ε-NFA. Determinize its underlying state
            // (the token-aware powerset construction lives on `State`) so the
            // lexer's maximal-munch loop can assume `step` returns at most
            // one successor. This replaces the old behaviour, which mis-wrapped
            // the NFA topology as `.dfa` and then `fatalError`'d at the first
            // ε-transition.
            var state = regex.state
            state.determinize()
            guard case let .dfa(initial, finals, transitions, minimal, tokenMap) = state else {
                fatalError("State.determinize() did not produce a .dfa state")
            }
            self.dfa = DFSA(
                initial: initial, finals: finals,
                transitions: transitions, minimal: minimal,
                tokenMap: tokenMap)
        case let .dfa(initial, finals, transitions, minimal, tokenMap):
            self.dfa = DFSA(
                initial: initial, finals: finals,
                transitions: transitions, minimal: minimal,
                tokenMap: tokenMap)
        }
    }

    // MARK: - Single-token API

    /// Attempts to read the next token from `source` starting at `offset`.
    ///
    /// On success, returns the token *and* the new source offset (the
    /// position immediately after the consumed lexeme). On failure,
    /// returns a `LexerError` indicating where the lexer got stuck.
    ///
    /// - Parameters:
    ///   - source: the source text being lexed.
    ///   - offset: the scalar offset at which to begin scanning.
    /// - Returns: the token and the offset of the next unread character.
    public func nextToken(in source: String, from offset: Int) -> Result<LexerToken, LexerError> {
        let scalars = source.unicodeScalars
        guard offset <= scalars.count else {
            return .failure(.noMatch(offset: offset))
        }
        if offset == scalars.count {
            // Nothing to scan — no token to emit.
            return .failure(.noMatch(offset: offset))
        }
        return scan(source: source, from: offset)
    }

    /// Scans the entire source into a token array, stopping at the first
    /// lexer error.
    ///
    /// Tokens whose class name is in `skippedTokenNames` (the rules
    /// registered via `LexerBuilder.addSkip` or with `skipped: true`) are
    /// *consumed but dropped* — the scanner still advances past them, but
    /// they do not appear in the returned array. For a lexer constructed
    /// directly from a `DFSA`/`Regex`, `skippedTokenNames` is empty and
    /// every token is emitted.
    ///
    /// Useful for batch lexing where the source is known to be valid.
    /// For streaming use, call `nextToken(in:from:)` in a loop.
    public func tokenize(_ source: String) -> Result<[LexerToken], LexerError> {
        return tokenize(source, skipping: skippedTokenNames)
    }

    /// Scans the entire source into a token array, dropping any token whose
    /// class name is in `skip`. This is the escape hatch for callers that
    /// build a `Lexer` directly (not via `LexerBuilder`) but still want
    /// whitespace/comment elision. Use an empty set to keep every token.
    ///
    /// Stops at the first lexer error.
    public func tokenize(_ source: String, skipping skip: Set<String>) -> Result<[LexerToken], LexerError> {
        var tokens: [LexerToken] = []
        var offset = 0
        let total = source.unicodeScalars.count
        while offset < total {
            switch nextToken(in: source, from: offset) {
            case .success(let token):
                if !skip.contains(token.tokenClass.name) {
                    tokens.append(token)
                }
                offset = token.endOffset
            case .failure(let err):
                return .failure(err)
            }
        }
        return .success(tokens)
    }

    // MARK: - Internals

    /// Core maximal-munch scan. Walks the DFA from `initial`, remembering
    /// the most recent accepting state and the offset at which it was
    /// reached. Stops when either the source is exhausted or `step`
    /// returns `nil` for the next character.
    private func scan(source: String, from startOffset: Int) -> Result<LexerToken, LexerError> {
        let scalars = source.unicodeScalars
        var scalarIndex = scalars.index(scalars.startIndex, offsetBy: startOffset)

        var current = dfa.initial
        // If the initial state is itself accepting (matches ε), record it
        // as the trivial last-accept at offset `startOffset`.
        var lastAccept: (state: Int, scalarOffset: Int)? =
            dfa.isFinal(state: current) ? (current, startOffset) : nil
        var consumed = startOffset

        while scalarIndex < scalars.endIndex {
            let ch = Character(scalars[scalarIndex])
            guard let next = dfa.step(state: current, symbol: ch) else {
                // No outgoing transition. Either emit the last accept
                // (longest match) or signal an error.
                break
            }
            current = next
            scalarIndex = scalars.index(after: scalarIndex)
            consumed += 1
            if dfa.isFinal(state: current) {
                lastAccept = (current, consumed)
            }
        }

        guard let (finalState, endOffset) = lastAccept else {
            // We consumed at least one character but never reached an
            // accepting state.
            return .failure(startOffset == consumed
                ? .noMatch(offset: startOffset)
                : .unexpectedCharacter(offset: startOffset))
        }

        guard let tokenClass = dfa.tokenClass(for: finalState) else {
            // An accepting state with no token class attached is a
            // programmer error in the DFA's construction. Treat it as a
            // scan failure rather than crash.
            return .failure(.noMatch(offset: startOffset))
        }

        // Slice the lexeme out of the source.
        let startScalarIdx = scalars.index(scalars.startIndex, offsetBy: startOffset)
        let endScalarIdx   = scalars.index(scalars.startIndex, offsetBy: endOffset)
        let lexeme = source[startScalarIdx..<endScalarIdx]

        return .success(LexerToken(
            tokenClass: tokenClass,
            lexeme: lexeme,
            startOffset: startOffset,
            endOffset: endOffset))
    }
}
