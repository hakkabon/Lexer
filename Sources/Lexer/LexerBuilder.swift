//
//  LexerBuilder.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/06/20.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import LexerFSA

/// Synopsis:
/// Collects lexer rules (regular-language patterns tagged with a
/// `TokenClass`), compiles each into an NFA, ε-unions them into one
/// token-tagged NFA, determinizes (and minimizes) the result, and hands a
/// ready-to-scan `Lexer` back to the caller.
///
/// This is the pipeline a parser front-end actually wants; previously the
/// same pipeline could only be assembled by hand (see the now-removed
/// `LexerDesignTests.makeLexer` helper).

/// A single lexer rule: a regular language tagged with the `TokenClass` to
/// emit when it matches. The language can be supplied either as a regex
/// pattern `String` (parsed via Thompson's construction at `build()` time)
/// or as a pre-compiled `Regex`.
///
/// `skipped` rules (whitespace, comments) are still recognized — they keep
/// the scanner advancing — but their tokens are dropped from the output of
/// `Lexer.tokenize(_:skipping:)`.
public struct LexerRule {

    /// The token class emitted on a match.
    public let token: TokenClass
    /// The regular language to match, given as a regex source string. This
    /// is parsed (or the pre-compiled regex is used) at `LexerBuilder.build()`
    /// time.
    public let pattern: String
    /// A pre-compiled regex, when the rule was registered via
    /// `addRule(regex:token:skipped:)`; `nil` otherwise.
    public let compiledRegex: Regex?
    /// `true` for whitespace/comment rules whose tokens should be dropped.
    public let skipped: Bool

    /// Creates a rule from a regex pattern string.
    public init(pattern: String, token: TokenClass, skipped: Bool = false) {
        self.pattern = pattern
        self.token = token
        self.compiledRegex = nil
        self.skipped = skipped
    }

    /// Creates a rule from a pre-compiled `Regex`. Its NFA topology is used
    /// directly; the regex is *not* re-parsed at build time.
    public init(regex: Regex, token: TokenClass, skipped: Bool = false) {
        self.pattern = regex.flattenExpressionTree
        self.token = token
        self.compiledRegex = regex
        self.skipped = skipped
    }
}

/// Builds a `Lexer` from a collection of lexer rules.
///
/// Each rule's language is compiled to an ε-NFA via Thompson's construction
/// (or taken directly if pre-compiled), its accepting states are tagged with
/// the rule's `TokenClass`, and the component NFAs are ε-unified into a
/// single NFA. That union is then determinized (the token-aware powerset
/// construction resolves conflicts by keeping the highest-priority — lowest
/// `priority` integer — token class for each DFA accepting state) and
/// minimized, yielding the deterministic automaton the `Lexer` drives.
///
/// Keyword vs. identifier: if a keyword rule `if` and an identifier rule
/// `[a-z]+` are both registered, the string `"if"` matches both. Give the
/// keyword a *lower* `priority` integer so its token class wins the
/// determinizer's conflict resolution on exact match; a longer identifier
/// (`"iffy"`) still classifies as ID because maximal munch lands on the ID
/// accepting state.
public struct LexerBuilder {

    /// Errors that can occur while building a lexer.
    public enum BuildError: Error, Equatable {
        /// A rule's pattern could not be parsed as a regular expression.
        case invalidPattern(String)
        /// `build()` was called with no rules registered.
        case noRules
    }

    /// The rules registered so far, in registration order.
    private(set) var rules: [LexerRule] = []

    public init() {}

    // MARK: - Registration

    /// Adds a rule. Lower `TokenClass.priority` integers win ties.
    @discardableResult
    public mutating func addRule(_ rule: LexerRule) -> LexerBuilder {
        rules.append(rule)
        return self
    }

    /// Convenience: add a rule from a regex pattern string. The pattern is
    /// parsed via Thompson's construction at `build()` time.
    @discardableResult
    public mutating func addRule(pattern: String, token: TokenClass, skipped: Bool = false) -> LexerBuilder {
        return addRule(LexerRule(pattern: pattern, token: token, skipped: skipped))
    }

    /// Convenience: add a rule from a pre-compiled `Regex`. Its NFA topology
    /// is used directly; the regex is *not* re-parsed at build time.
    @discardableResult
    public mutating func addRule(regex: Regex, token: TokenClass, skipped: Bool = false) -> LexerBuilder {
        return addRule(LexerRule(regex: regex, token: token, skipped: skipped))
    }

    /// Convenience: register a whitespace/comment rule whose tokens are
    /// dropped from the lexer's output. The token class is a placeholder
    /// named `"SKIP"` with a fresh negative id so it never collides with a
    /// caller's real ids.
    @discardableResult
    public mutating func addSkip(_ pattern: String) -> LexerBuilder {
        let skipToken = TokenClass(id: -(rules.count + 1), name: "SKIP", priority: Int.max)
        return addRule(pattern: pattern, token: skipToken, skipped: true)
    }

    // MARK: - Build

    /// Compiles the registered rules into a `Lexer`.
    ///
    /// Pipeline: per-rule Thompson NFA → ε-union → determinize → minimize.
    /// Skipped rules' token classes are recorded on the resulting lexer so
    /// `tokenize(_:skipping:)` can drop them.
    ///
    /// - Throws: `BuildError.invalidPattern` if a pattern fails to parse,
    ///   or `BuildError.noRules` if no rules were registered.
    public func build() throws -> Lexer {
        guard !rules.isEmpty else { throw BuildError.noRules }

        // 1. Compile each rule to an NFA and tag its accepting states.
        var componentNfas: [State<NFSA>] = []
        for rule in rules {
            let regex: Regex
            if let compiled = rule.compiledRegex {
                regex = compiled
            } else {
                do {
                    regex = try Regex(rule.pattern)
                } catch {
                    throw BuildError.invalidPattern(rule.pattern)
                }
            }
            // A freshly-parsed (or pre-compiled) Thompson regex is an NFA.
            // Use its (initial, finals, transitions) as this rule's component.
            switch regex.state {
            case let .nfa(initial, finals, transitions, _):
                let tokenMap = Dictionary(uniqueKeysWithValues: finals.map { ($0, rule.token) })
                componentNfas.append(.nfa(initial: initial, finals: finals,
                                          transitions: transitions, tokenMap: tokenMap))
            case let .dfa(initial, finals, transitions, _, _):
                // Already-deterministic rule: adopt its topology as the NFA.
                let tokenMap = Dictionary(uniqueKeysWithValues: finals.map { ($0, rule.token) })
                componentNfas.append(.nfa(initial: initial, finals: finals,
                                          transitions: transitions, tokenMap: tokenMap))
            }
        }

        // 2. ε-union the component NFAs (local counter ⇒ reproducible build).
        var united = State<NFSA>.union(list: componentNfas)

        // 3. Determinize (token-aware powerset construction resolves
        //    keyword/identifier conflicts by highest priority).
        united.determinize()

        guard case let .dfa(initial, finals, transitions, minimal, tokenMap) = united else {
            fatalError("LexerBuilder: determinize() did not produce a .dfa state")
        }

        // 4. Minimize. The minimize() step preserves the token map.
        var dfaState: State<DFSA> = .dfa(initial: initial, finals: finals,
                                         transitions: transitions,
                                         minimal: minimal, tokenMap: tokenMap)
        dfaState.minimize()

        guard case let .dfa(dInitial, dFinals, dTransitions, dMinimal, dTokenMap) = dfaState else {
            fatalError("LexerBuilder: minimize() did not preserve a .dfa state")
        }

        let dfsa = DFSA(initial: dInitial, finals: dFinals,
                        transitions: dTransitions, minimal: dMinimal,
                        tokenMap: dTokenMap)

        // 5. Collect the names of skipped token classes so the lexer can
        //    drop them from tokenize(_:skipping:) output.
        let skippedNames = Set(rules.filter(\.skipped).map { $0.token.name })

        return Lexer(dfsa, skippedTokenNames: skippedNames)
    }
}
