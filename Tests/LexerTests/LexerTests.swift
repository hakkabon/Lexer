import Testing
@testable import Lexer
@testable import LexerFSA

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Lexer (§3.1, §3.2)
// ──────────────────────────────────────────────────────────────────────────────
//
// Originally written against the `Automaton<Type>` container, which has
// since been removed. The hand-rolled "union two NFAs, determinize, wrap as
// a DFA" pipeline in `makeTwoTokenDFA`/`makeKeywordIdentifierDFA` below is
// exactly what `LexerBuilder` now does for you (see LexerDesignTests.swift
// for the `LexerBuilder`-based equivalent); it's kept here, low-level and
// hand-assembled, so these tests exercise `Lexer` itself independently of
// how its DFA was constructed.

@Suite("Lexer — maximal-munch scanning")
struct LexerTests {

    /// Two-token DFA: NUM = [0-9]+, IDENT = [a-z]+. After union +
    /// determinize the result is a DFA where NUM final states carry the
    /// NUM token class and IDENT final states carry the IDENT class. The
    /// lexer should walk it character by character, emitting one token
    /// per maximal-munch run.
    private func makeTwoTokenDFA() -> DFSA {
        let numTok  = TokenClass(id: 1, name: "NUM",  priority: 1)
        let identTok = TokenClass(id: 2, name: "IDENT", priority: 1)

        let num = NFSA(
            initial: 0, finals: [1],
            transitions: [
                Transition(from: 0, AlphabetRange.range("0","9"), to: 1),
                Transition(from: 1, AlphabetRange.range("0","9"), to: 1),
            ],
            tokenMap: [1: numTok])
        let ident = NFSA(
            initial: 0, finals: [1],
            transitions: [
                Transition(from: 0, AlphabetRange.range("a","z"), to: 1),
                Transition(from: 1, AlphabetRange.range("a","z"), to: 1),
            ],
            tokenMap: [1: identTok])

        // NFA union, then determinize.
        var united = NFSA.union(num, ident)
        united.determinize()

        switch united.state {
        case let .dfa(initial, finals, transitions, minimal, tokenMap):
            return DFSA(
                initial: initial, finals: finals,
                transitions: transitions, minimal: minimal,
                tokenMap: tokenMap)
        case .nfa:
            fatalError("determinize() did not produce a .dfa state")
        }
    }

    @Test func singleTokenMatchesWholeInput() {
        let lexer = Lexer(makeTwoTokenDFA())
        let result = lexer.tokenize("42")
        switch result {
        case .success(let tokens):
            #expect(tokens.count == 1)
            #expect(tokens[0].tokenClass.name == "NUM")
            #expect(String(tokens[0].lexeme) == "42")
        case .failure(let err):
            Issue.record("expected success, got \(err)")
        }
    }

    @Test func maximalMunchPicksLongestAcceptingPrefix() {
        // "abc" should lex as a single IDENT token — maximal munch
        // continues past each character because the self-loop on the
        // accepting state accepts more.
        let lexer = Lexer(makeTwoTokenDFA())
        let result = lexer.tokenize("abc")
        switch result {
        case .success(let tokens):
            #expect(tokens.count == 1)
            #expect(tokens[0].tokenClass.name == "IDENT")
            #expect(String(tokens[0].lexeme) == "abc")
        case .failure(let err):
            Issue.record("expected success, got \(err)")
        }
    }

    @Test func alternatingTokenKinds() {
        let lexer = Lexer(makeTwoTokenDFA())
        let result = lexer.tokenize("123abc45")
        switch result {
        case .success(let tokens):
            #expect(tokens.count == 3)
            #expect(tokens[0].tokenClass.name == "NUM")
            #expect(String(tokens[0].lexeme) == "123")
            #expect(tokens[1].tokenClass.name == "IDENT")
            #expect(String(tokens[1].lexeme) == "abc")
            #expect(tokens[2].tokenClass.name == "NUM")
            #expect(String(tokens[2].lexeme) == "45")
        case .failure(let err):
            Issue.record("expected success, got \(err)")
        }
    }

    @Test func unexpectedCharacterSignalsError() {
        // "@" matches neither [0-9] nor [a-z]; the lexer should reject.
        let lexer = Lexer(makeTwoTokenDFA())
        let result = lexer.tokenize("@")
        if case .failure(let err) = result {
            // Accept either noMatch or unexpectedCharacter — both signal
            // "stuck at offset 0".
            switch err {
            case .noMatch(let offset), .unexpectedCharacter(let offset):
                #expect(offset == 0)
            }
        } else {
            Issue.record("expected failure, got \(result)")
        }
    }

    @Test func nextTokenStreamingRoundTrip() {
        // Exercise the single-token API: read tokens one at a time from
        // increasing offsets; the concatenation of all lexemes should
        // reconstruct the source.
        let lexer = Lexer(makeTwoTokenDFA())
        let source = "abc123de"
        var offset = 0
        var collected = ""
        var tokenCount = 0
        while offset < source.unicodeScalars.count {
            switch lexer.nextToken(in: source, from: offset) {
            case .success(let token):
                collected += String(token.lexeme)
                offset = token.endOffset
                tokenCount += 1
            case .failure:
                break
            }
        }
        #expect(collected == source)
        #expect(tokenCount == 3)   // "abc", "123", "de"
    }
}

@Suite("Lexer — keyword-vs-identifier priority")
struct LexerPriorityTests {

    /// Classic scanner ambiguity: "if" matches both the keyword pattern
    /// and the identifier pattern. After determinize, the accepting DFA
    /// state for "if" must carry the higher-priority KEYWORD class.
    private func makeKeywordIdentifierDFA() -> DFSA {
        let kw    = TokenClass(id: 1, name: "KW",    priority: 1)
        let ident = TokenClass(id: 2, name: "IDENT", priority: 10)

        // NFA for "if"
        let ifNfa = NFSA(
            initial: 0, finals: [2],
            transitions: [
                Transition(from: 0, AlphabetRange.char("i"), to: 1),
                Transition(from: 1, AlphabetRange.char("f"), to: 2),
            ],
            tokenMap: [2: kw])
        // NFA for [a-z]+
        let identNfa = NFSA(
            initial: 0, finals: [1],
            transitions: [
                Transition(from: 0, AlphabetRange.range("a","z"), to: 1),
                Transition(from: 1, AlphabetRange.range("a","z"), to: 1),
            ],
            tokenMap: [1: ident])

        var united = NFSA.union(ifNfa, identNfa)
        united.determinize()

        switch united.state {
        case let .dfa(initial, finals, transitions, minimal, tokenMap):
            return DFSA(
                initial: initial, finals: finals,
                transitions: transitions, minimal: minimal,
                tokenMap: tokenMap)
        case .nfa:
            fatalError("determinize() did not produce a .dfa state")
        }
    }

    @Test func keywordWinsOverIdentifierForExactMatch() {
        let lexer = Lexer(makeKeywordIdentifierDFA())
        let result = lexer.tokenize("if")
        switch result {
        case .success(let tokens):
            #expect(tokens.count == 1)
            // The DFA's accepting state for "if" was tagged by the
            // determinizer with the highest-priority token class
            // (priority=1, KW).
            #expect(tokens[0].tokenClass.name == "KW")
        case .failure(let err):
            Issue.record("expected success, got \(err)")
        }
    }

    @Test func longerIdentifierStillClassifiedAsIdent() {
        // "iffy" must be IDENT, not KW — maximal munch consumes all four
        // characters and the accepting state reached is the IDENT one
        // (the KW pattern is only two chars long).
        let lexer = Lexer(makeKeywordIdentifierDFA())
        let result = lexer.tokenize("iffy")
        switch result {
        case .success(let tokens):
            #expect(tokens.count == 1)
            #expect(tokens[0].tokenClass.name == "IDENT")
            #expect(String(tokens[0].lexeme) == "iffy")
        case .failure(let err):
            Issue.record("expected success, got \(err)")
        }
    }
}
