// LexerPipelineTests.swift
// End-to-end exercise of the token-tracking feature as a multi-pattern
// lexer pipeline: several regular languages, each tagged with its own
// TokenClass, merged into one NFA, determinized, and queried.
//
// Coverage areas:
//  1. Three-pattern union (KEYWORD / IDENTIFIER / NUMBER) — priority resolution
//  2. Splitting a buffer into multiple adjacent tokens, via `LexerBuilder` +
//     `Lexer.tokenize`
//
// `LexerPipelineTests` below builds its merged automaton by hand, with
// deliberately disjoint, hand-picked state numbers (not relying on the
// `LexerBuilder` pipeline), specifically so it exercises the underlying
// `State<NFSA>.recognizeWithToken` primitive in isolation from any
// higher-level construction path. That primitive does whole-string
// recognition only — it cannot, by itself, split a buffer like "if123"
// into the two tokens "if" and "123" (see
// `wholeStringRecognitionCannotSplitTwoAdjacentTokens` below). That is
// exactly the gap `LexerBuilder`/`Lexer` close: `LexerBuilderTokenizeTests`
// further down builds the *same* three-pattern grammar via the public
// `LexerBuilder` API and shows `Lexer.tokenize` correctly splitting
// "if123" into `["if", "123"]` via maximal-munch scanning.

import Testing
@testable import Lexer
@testable import LexerFSA

@Suite("Multi-Pattern Lexer Pipeline")
struct LexerPipelineTests {

    let keyword    = TokenClass(id: 1, name: "KEYWORD",    priority: 1)
    let identifier = TokenClass(id: 2, name: "IDENTIFIER", priority: 10)
    let number     = TokenClass(id: 3, name: "NUMBER",     priority: 5)

    /// Manually-unioned, token-tagged NFA for:
    ///   KEYWORD     "if"      (priority 1, wins ties)
    ///   IDENTIFIER  [a-z]+    (priority 10)
    ///   NUMBER      [0-9]+    (priority 5)
    ///
    /// State layout (disjoint by construction):
    ///   0 --ε--> 1 --'i'--> 2 --'f'--> 3            (final: KEYWORD)
    ///   0 --ε--> 4 --[a-z]--> 5 --[a-z]--> 5         (final: IDENTIFIER)
    ///   0 --ε--> 6 --[0-9]--> 7 --[0-9]--> 7         (final: NUMBER)
    func buildMergedLexerState() -> State<NFSA> {
        var state: State<NFSA> = .nfa(
            initial: 0,
            finals: [3, 5, 7],
            transitions: [
                Transition(from: 0, AlphabetRange.epsilon, to: 1),
                Transition(from: 0, AlphabetRange.epsilon, to: 4),
                Transition(from: 0, AlphabetRange.epsilon, to: 6),

                Transition(from: 1, AlphabetRange.char("i"), to: 2),
                Transition(from: 2, AlphabetRange.char("f"), to: 3),

                Transition(from: 4, AlphabetRange.range("a", "z"), to: 5),
                Transition(from: 5, AlphabetRange.range("a", "z"), to: 5),

                Transition(from: 6, AlphabetRange.range("0", "9"), to: 7),
                Transition(from: 7, AlphabetRange.range("0", "9"), to: 7),
            ],
            tokenMap: [3: keyword, 5: identifier, 7: number]
        )
        state.determinize()
        return state
    }

    @Test func keywordWinsOverIdentifierOnExactMatch() {
        let state = buildMergedLexerState()
        #expect(state.recognizeWithToken(string: "if") == keyword)
    }

    @Test func longerIdentifierIsNotMisclassifiedAsKeyword() {
        let state = buildMergedLexerState()
        #expect(state.recognizeWithToken(string: "iffy") == identifier)
        #expect(state.recognizeWithToken(string: "ifx") == identifier)
    }

    @Test func numberPatternMatchesIndependently() {
        let state = buildMergedLexerState()
        #expect(state.recognizeWithToken(string: "123") == number)
        #expect(state.recognizeWithToken(string: "0") == number)
    }

    @Test func emptyAndUnmatchedInputReturnNil() {
        let state = buildMergedLexerState()
        #expect(state.recognizeWithToken(string: "") == nil)
        #expect(state.recognizeWithToken(string: "_") == nil)
        #expect(state.recognizeWithToken(string: "12a") == nil)
    }

    /// `recognizeWithToken` classifies a string that matches ONE compiled
    /// pattern *in its entirety* — it has no notion of scanning forward and
    /// splitting off a prefix. A merged automaton correctly rejects "if123"
    /// as a whole, because no single pattern matches it end to end. Pinning
    /// this behaviour matters because it's precisely the limitation
    /// `Lexer.tokenize` (exercised below) is built to work around, by
    /// repeatedly applying maximal-munch from the current offset instead of
    /// matching the whole buffer at once.
    @Test func wholeStringRecognitionCannotSplitTwoAdjacentTokens() {
        let state = buildMergedLexerState()
        #expect(state.recognizeWithToken(string: "if123") == nil)
        #expect(state.recognizeWithToken(string: "x99") == nil)
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - The same grammar, assembled via the public LexerBuilder API,
//          splitting a buffer into multiple tokens.
// ──────────────────────────────────────────────────────────────────────────────

@Suite("LexerBuilder assembles the same grammar and tokenizes a buffer")
struct LexerBuilderTokenizeTests {

    private func makeKeywordIdentNumberLexer() throws -> Lexer {
        var builder = LexerBuilder()
        builder.addRule(pattern: "if", token: TokenClass(id: 1, name: "KEYWORD", priority: 1))
        builder.addRule(pattern: "[a-z]+", token: TokenClass(id: 2, name: "IDENTIFIER", priority: 10))
        builder.addRule(pattern: "[0-9]+", token: TokenClass(id: 3, name: "NUMBER", priority: 5))
        return try builder.build()
    }

    @Test func unionWithTokenClassesResolvesWholeStringMatches() throws {
        let lexer = try makeKeywordIdentNumberLexer()
        #expect(lexer.dfa.recognizeWithToken(string: "abba")?.name == "IDENTIFIER")
        #expect(lexer.dfa.recognizeWithToken(string: "123")?.name == "NUMBER")
    }

    /// This is the resolution of the gap pinned by
    /// `wholeStringRecognitionCannotSplitTwoAdjacentTokens` above:
    /// `Lexer.tokenize` performs repeated maximal-munch scans, so "if123"
    /// splits into the keyword "if" followed by the number "123" — exactly
    /// the buffer-scanning capability that whole-string `recognizeWithToken`
    /// cannot provide on its own.
    @Test func tokenizeSplitsAdjacentTokens() throws {
        let lexer = try makeKeywordIdentNumberLexer()
        guard case .success(let toks) = lexer.tokenize("if123") else {
            Issue.record("expected tokenize(\"if123\") to succeed")
            return
        }
        #expect(toks.map { $0.tokenClass.name } == ["KEYWORD", "NUMBER"])
        #expect(toks.map { String($0.lexeme) } == ["if", "123"])
    }

    @Test func tokenizeDistinguishesKeywordFromLongerIdentifier() throws {
        // tokenize(_:) fails the *entire* call on the first unmatched
        // character, so a space between "if" and "iffy" needs an explicit
        // skip rule rather than being left to interrupt the scan.
        var builder = LexerBuilder()
        builder.addRule(pattern: "if", token: TokenClass(id: 1, name: "KEYWORD", priority: 1))
        builder.addRule(pattern: "[a-z]+", token: TokenClass(id: 2, name: "IDENTIFIER", priority: 10))
        builder.addSkip(" ")
        let lexer = try builder.build()

        guard case .success(let toks) = lexer.tokenize("if iffy") else {
            Issue.record("expected tokenize(\"if iffy\") to succeed")
            return
        }
        #expect(toks.map { $0.tokenClass.name } == ["KEYWORD", "IDENTIFIER"])
        #expect(toks.map { String($0.lexeme) } == ["if", "iffy"])
    }
}
