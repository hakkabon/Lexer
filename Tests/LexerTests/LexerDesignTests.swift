//
//  LexerDesignTests.swift
//  LexerFSATests
//
//  Tests written to cover the design issues surfaced in the codebase review.
//
//  They are organised in three groups:
//
//    A. Lexer entry-point ergonomics — pins the contract that `Lexer(_
//       regex:)` must gracefully handle a fresh (non-deterministic) `Regex`,
//       and that `Regex.isDeterministic = true` performs a real
//       determinization rather than just flipping a label. Both were once
//       bugs (the init mis-wrapped a fresh ε-NFA as `.dfa` and trapped on
//       the first ε-transition; the setter didn't call `determinize()` at
//       all) — both are fixed in `Lexer.swift`/`Regex.swift`, so these tests
//       are enabled rather than `.disabled`.
//
//    B. The end-to-end lexer pipeline that the library is meant to support
//       ([Regex]×N -> union -> determinize -> minimize -> Lexer). This is
//       now `LexerBuilder`'s job; `makeLexer` below is a thin wrapper around
//       it so these tests double as `LexerBuilder` integration tests.
//
//    C. Duplication/abstraction contracts — properties that any
//       de-duplicated `move`/`step`/`epsClosure`/`run` implementation
//       must keep holding for both NFA and DFA, plus the reproducibility
//       of construction that the local-counter union relies on.
//

import Testing
@testable import Lexer
@testable import LexerFSA

// Small local helper so we never need `return Issue.record(...)` inside a
// `guard else { }` (which is illegal because `Issue.record` returns `Issue`,
// not `Never`). Returns the unwrapped tokens, recording an issue otherwise.
// Note: Swift Testing's `Issue.record(_:)` accepts string *literals* (via
// Comment) but not `String` variables, hence the fixed literal here.
private func tokens(_ result: Result<[Token], LexerError>) -> [Token] {
    if case .success(let toks) = result { return toks }
    Issue.record("expected tokenizing to succeed, but it failed")
    return []
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - A. Lexer entry-point ergonomics
// ──────────────────────────────────────────────────────────────────────────────

@Suite("Lexer entry points")
struct LexerEntryPointTests {

    /// The README "Quick Start" implies `Regex` is the starting point for
    /// lexing. The documented `Lexer(_ regex:)` convenience initializer
    /// promises (Lexer.swift) that passing a still-non-deterministic regex
    /// yields a working lexer rather than crashing.
    ///
    /// SPEC: it must not crash. A Thompson regex is an ε-NFA; `Lexer.init(_
    /// regex:)` now determinizes it in place before wrapping it as a `DFSA`,
    /// rather than mis-wrapping the raw NFA topology as `.dfa` (which used
    /// to `fatalError` on the first ε-transition).
    @Test
    func lexerOverFreshRegexMustNotTrap() throws {
        let re = try Regex("[a-z]+")
        #expect(!re.isDeterministic, "precondition: a fresh Regex is an NFA")

        let lexer = Lexer(re)
        let result = lexer.tokenize("abc")
        switch result {
        case .success(let toks):
            #expect(!toks.isEmpty)
        case .failure:
            // Graceful failure is acceptable per the doc comment; a trap is not.
            break
        }
        #expect(Bool(true))
    }

    /// A `Lexer` built from an explicitly-determinized regex must scan
    /// correctly. Setting `Regex.isDeterministic = true` is a promise that
    /// the underlying state is genuinely deterministic — the setter now
    /// calls `state.determinize()` rather than just flipping a label.
    @Test
    func lexerOverDeterminizedRegexScans() throws {
        var re = try Regex("[a-z]+")
        re.isDeterministic = true
        #expect(re.isDeterministic)

        let lexer = Lexer(re)
        let toks = tokens(lexer.tokenize("abc"))
        #expect(toks.count == 1)
        if let first = toks.first { #expect(String(first.lexeme) == "abc") }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - B. End-to-end pipeline ([Regex]×N -> union -> determinize -> Lexer)
// ──────────────────────────────────────────────────────────────────────────────

/// Helper: the pipeline a parser frontend actually wants, now provided
/// directly by `LexerBuilder`. Kept as a thin wrapper so the call sites
/// below read the same as before, while actually exercising the public
/// `LexerBuilder` API rather than re-implementing its internals by hand.
private func makeLexer(rules: [(String, TokenClass, Regex)]) throws -> Lexer {
    var builder = LexerBuilder()
    for (_, tok, re) in rules {
        builder.addRule(regex: re, token: tok)
    }
    return try builder.build()
}

@Suite("Lexer end-to-end pipeline (regex -> union -> determinize -> scan)")
struct LexerPipelineDesignTests {

    private func makeNumIdentLexer() throws -> Lexer {
        try makeLexer(rules: [
            ("NUM",  TokenClass(id: 1, name: "NUM",  priority: 1), Regex("[0-9]+")),
            ("ID",   TokenClass(id: 2, name: "ID",   priority: 2), Regex("[a-z]+")),
        ])
    }

    @Test func alternatesNumAndId() throws {
        let lexer = try makeNumIdentLexer()
        let toks = tokens(lexer.tokenize("123abc45"))
        #expect(toks.count == 3)
        #expect(toks.map { $0.tokenClass.name } == ["NUM", "ID", "NUM"])
        #expect(toks.map { String($0.lexeme) }    == ["123", "abc", "45"])
    }

    @Test func maximalMunchConsumesEntireRun() throws {
        let lexer = try makeNumIdentLexer()
        // "abc" is a single ID token — maximal munch walks the self-loop.
        let toks = tokens(lexer.tokenize("abc"))
        #expect(toks.count == 1)
        if let first = toks.first { #expect(String(first.lexeme) == "abc") }
    }

    @Test func offsetsAreContiguous() throws {
        let lexer = try makeNumIdentLexer()
        let toks = tokens(lexer.tokenize("1aa22"))
        // Verify start/end offsets chain correctly.
        #expect(toks.isEmpty || toks[0].startOffset == 0)
        for i in 1..<toks.count {
            #expect(toks[i].startOffset == toks[i - 1].endOffset,
                    "token \(i) start must equal previous token end")
        }
        if let last = toks.last { #expect(last.endOffset == 5) } // "1aa22".count == 5
    }

    @Test func unexpectedCharIsReportedAtCorrectOffset() throws {
        let lexer = try makeNumIdentLexer()
        // '@' matches neither [0-9] nor [a-z].
        let result = lexer.tokenize("ab@")
        // The lexer accepts "ab" then gets stuck at offset 2.
        switch result {
        case .success:
            // tokenize stops at first error and returns failure, so success
            // for a stuck input would be wrong — but be lenient about *how*
            // the error surfaces as long as it surfaces.
            Issue.record("expected a failure on 'ab@'")
        case .failure(let err):
            switch err {
            case .noMatch(let off), .unexpectedCharacter(let off):
                #expect(off == 2, "error offset must point at '@'")
            }
        }
    }
}

@Suite("Lexer keyword-vs-identifier priority")
struct LexerKeywordPriorityTests {

    /// Classic scanner ambiguity: "if" matches both the keyword rule and the
    /// identifier rule. The lower-priority-integer token class must win on
    /// exact match; a longer identifier must still classify as ID.
    private func makeKwIdentLexer() throws -> Lexer {
        try makeLexer(rules: [
            ("KW",   TokenClass(id: 1, name: "KW",  priority: 1),  Regex("if")),
            ("ID",   TokenClass(id: 2, name: "ID",  priority: 10), Regex("[a-z]+")),
        ])
    }

    @Test func keywordWinsOnExactMatch() throws {
        let lexer = try makeKwIdentLexer()
        let toks = tokens(lexer.tokenize("if"))
        #expect(toks.count == 1)
        if let first = toks.first { #expect(first.tokenClass.name == "KW") }
    }

    @Test func longerIdentifierClassifiedAsId() throws {
        let lexer = try makeKwIdentLexer()
        // "iffy" — maximal munch consumes all four; the accepting state is
        // the ID one (the KW pattern is only 2 chars).
        let toks = tokens(lexer.tokenize("iffy"))
        #expect(toks.count == 1)
        if let first = toks.first {
            #expect(first.tokenClass.name == "ID")
            #expect(String(first.lexeme) == "iffy")
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - C. Duplication / abstraction contracts
// ──────────────────────────────────────────────────────────────────────────────

@Suite("NFA/DFA move & step parity (de-duplication contract)")
struct MoveStepParityTests {

    /// `move`/`step` is implemented four times (State<NFSA>, State<DFSA>,
    /// State<Regex>, RegexRecognize). Regardless of how it's factored, the
    /// observable result must agree. Build the same language as both a
    /// `Regex` and a hand-rolled `NFSA`, and confirm they match on every
    /// probe string.
    @Test
    func regexAndNfaAgreeOnMoveSemantics() throws {
        // Pattern: (a|b)*  — union + star, exercises ε-transitions & ranges.
        let regex = try Regex("(a|b)*")

        // A hand-built NFA for the same language:
        //   0 -ε-> 1 (loop head)
        //   1 -a/b-> 1
        //   0 -ε-> 2 (accept, for the empty string)
        let nfa = NFSA(
            initial: 0,
            finals: [1, 2],
            transitions: [
                Transition(from: 0, .epsilon,     to: 1),
                Transition(from: 0, .epsilon,     to: 2),
                Transition(from: 1, .char("a"),   to: 1),
                Transition(from: 1, .char("b"),   to: 1),
            ])

        let probes = ["", "a", "b", "aa", "ab", "ba", "bb", "aabba", "c"]
        for s in probes {
            #expect(regex.recognize(string: s) == nfa.run(string: s),
                    "Regex vs NFSA disagree on \"\(s)\"")
        }
    }

    /// A DFA produced by determinize must accept exactly the language of
    /// the source NFA. This is the contract that lets the lexer rely on a
    /// deterministic automaton.
    @Test
    func determinizePreservesLanguage() {
        let nfa = NFSA(
            initial: 0,
            finals: [2],
            transitions: [
                Transition(from: 0, .epsilon,    to: 1),
                Transition(from: 1, .range("a","z"), to: 1),
                Transition(from: 1, .epsilon,    to: 2),
            ])

        let beforeAccepts = ["", "a", "abc", "z", "1"].map { nfa.run(string: $0) }

        var dfa = nfa
        dfa.determinize()
        #expect(dfa.isDeterministic)

        let afterAccepts = ["", "a", "abc", "z", "1"].map { dfa.run(string: $0) }
        #expect(beforeAccepts == afterAccepts,
                "determinize must preserve the accepted language")
    }

    /// The determinizer must be idempotent on an already-deterministic
    /// automaton (a second `determinize()` is a no-op).
    @Test
    func determinizeIsIdempotentOnDfa() {
        let nfa = NFSA(
            initial: 0, finals: [1],
            transitions: [Transition(from: 0, .range("0","9"), to: 1)])

        var once = nfa;  once.determinize()
        var twice = once; twice.determinize()

        // Same language, and still deterministic.
        #expect(once.isDeterministic && twice.isDeterministic)
        for s in ["0", "9", ""] {
            #expect(once.run(string: s) == twice.run(string: s))
        }
    }
}

@Suite("Construction reproducibility (normalized)")
struct ConstructionReproducibilityTests {

    /// The Counter fix claims union results are reproducible. That's true for
    /// the *set* of transitions but NOT for `description`, which iterates a
    /// hashed Set in non-deterministic order. This test pins the contract
    /// that SHOULD hold: equal languages => equal normalized transition sets.
    @Test
    func unionProducesEqualTransitionSetsAcrossCalls() {
        let a = NFSA(
            initial: 0, finals: [1],
            transitions: [Transition(from: 0, .char("a"), to: 1)])
        let b = NFSA(
            initial: 0, finals: [1],
            transitions: [Transition(from: 0, .char("b"), to: 1)])

        let u1 = NFSA.union(a, b)
        let u2 = NFSA.union(a, b)

        // The same language — same finals, same initial, same transitions.
        guard case let .nfa(i1, f1, t1, _) = u1.state,
              case let .nfa(i2, f2, t2, _) = u2.state else {
            Issue.record("union did not produce NFA state")
            return
        }
        #expect(i1 == i2)
        #expect(f1 == f2)
        #expect(t1 == t2, "transition SETS must be equal across calls")
    }

    /// `tokenize` and the streaming `nextToken` API must agree: collecting
    /// tokens one at a time must yield the same sequence as a batch scan.
    @Test
    func streamingAndBatchTokenizeAgree() throws {
        let lexer = try makeLexer(rules: [
            ("NUM",  TokenClass(id: 1, name: "NUM", priority: 1), Regex("[0-9]+")),
            ("ID",   TokenClass(id: 2, name: "ID",  priority: 2), Regex("[a-z]+")),
        ])
        let source = "a1b2c3"

        // Batch.
        let batch: [Token] = {
            guard case .success(let ts) = lexer.tokenize(source) else { return [] }
            return ts
        }()

        // Streaming.
        var streamed: [Token] = []
        var offset = 0
        while offset < source.unicodeScalars.count {
            switch lexer.nextToken(in: source, from: offset) {
            case .success(let tk):
                streamed.append(tk)
                offset = tk.endOffset
            case .failure:
                break
            }
        }

        #expect(streamed.count == batch.count)
        for (s, b) in zip(streamed, batch) {
            #expect(s.tokenClass == b.tokenClass)
            #expect(String(s.lexeme) == String(b.lexeme))
        }
    }
}

@Suite("AlphabetRange / Transition edge cases (lexer-critical)")
struct LexerCriticalEdgeCases {

    /// A transition labelled with a `.range` must match any character inside
    /// it, not just the endpoints. The lexer walks DFA states via
    /// `step`, which goes through `inAlphabet(char:)`. This guards against
    /// the historical bug where `isSuccessor` only synthesized `.char`.
    @Test
    func rangeTransitionMatchesInteriorCharacters() {
        let dfa = DFSA(
            initial: 0, finals: [1],
            transitions: [Transition(from: 0, .range("a", "z"), to: 1)],
            minimal: false)

        for ch in "abcdefghijklmnopqrstuvwxyz" {
            #expect(dfa.step(state: 0, symbol: ch) == 1,
                    "range must match interior char '\(ch)'")
        }
        #expect(dfa.step(state: 0, symbol: "A") == nil, "outside the range")
        #expect(dfa.step(state: 0, symbol: "1") == nil)
    }

    /// The lexer's maximal-munch loop must record the *last* accept, not the
    /// first. Construct a DFA where an accepting state is followed by a
    /// non-accepting transition and verify the longest prefix wins.
    @Test
    func maximalMunchRecordsLastAccept() {
        // Language: "a" (accept) or "ab" (accept). Input "abc" must yield
        // token "ab" (the longest prefix that landed on an accept), and the
        // 'c' is then an error on the NEXT nextToken call.
        let dfa = DFSA(
            initial: 0, finals: [1, 2],
            transitions: [
                Transition(from: 0, .char("a"), to: 1),  // "a"  -> accept
                Transition(from: 1, .char("b"), to: 2),  // "ab" -> accept
            ],
            minimal: false,
            tokenMap: [1: TokenClass(id: 1, name: "A", priority: 1),
                       2: TokenClass(id: 2, name: "AB", priority: 1)])
        let lexer = Lexer(dfa)

        // First token: "ab", longest accept.
        switch lexer.nextToken(in: "abc", from: 0) {
        case .success(let tk):
            #expect(tk.tokenClass.name == "AB")
            #expect(String(tk.lexeme) == "ab")
            #expect(tk.endOffset == 2)
        case .failure(let err):
            Issue.record("expected token 'ab', got \(err)")
        }
    }
}
