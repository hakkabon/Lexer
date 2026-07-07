# Lexer

A DFA-driven lexer, its builder, and the `TokenStream` protocol that lets any
parser in the toolkit (Earley, CYK, LL, LR, RNGLR, GLR, …) consume tokens from
either this module's automated lexer or GrammarTokenizer's hand-written
`Tokenizer` — interchangeably, with no parser-side code change.

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)  
[![Platforms](https://img.shields.io/badge/platforms-macOS%2011%20%7C%20iOS%2012-blue.svg)](https://developer.apple.com/swift/)  
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)  

---

## Overview

`Lexer` sits between two lower-level packages and the parsing toolkit's
parsers:

- **Lexer-FSA** supplies the regular-expression engine and finite-state
  automata (Thompson construction, determinize, minimize) this module drives.
- **Grammar** supplies `GrammarVocabulary` — the protocol a grammar
  implements to describe its own keywords, symbols, and patterns — and
  `Terminal`, the alphabet a parser tests tokens against.

`Lexer` turns a `GrammarVocabulary` into a working DFA automatically
(`LexerBuilder.loadVocabulary(_:)`), and exposes both that DFA-driven lexer
and GrammarTokenizer's hand-written `Tokenizer` through the same `TokenStream`
protocol, so a parser can be written once against `TokenStream` and driven by
either front end.

```
Lexer-FSA ──┐
            ├──▶ Lexer ──▶ (Earley-Parser, CYK-Parser, LL-Parser, …)
Grammar ────┤        ▲
            │        │
GrammarTokenizer ─────┘
```

---

## Key Types

### `LexerToken` (`Token.swift`)

The token type this module's DFA `Lexer` emits: a `TokenClass` (from
Lexer-FSA), the matched `Substring` lexeme, and its scalar offsets.

Named `LexerToken` rather than the more obvious `Token` because
GrammarTokenizer already exports its own unrelated `Token` type, and `Lexer`
depends on `Tokenizer` (see below) — so both are simultaneously in scope
wherever this module is used. Giving each a distinct name resolves the
ambiguity everywhere at once, rather than only at the handful of call sites
that would otherwise happen to trigger it.

### `TokenStream` (`TokenStream.swift`)

The protocol a parser pulls tokens through:

```swift
public protocol TokenStream {
    var source: String { get }
    var count: Int { get }
    func terminal(at position: Int) throws -> (terminal: Terminal, range: Range<String.Index>)
}
```

A parser only ever needs a token count, the original source text (for
diagnostics), and — per position — the `Terminal` to test against the
grammar's alphabet plus the source range it spans. Random access
(`terminal(at:)`) rather than a `next()`/`peek()` cursor is deliberate: GLR
and RNGLR fork parse state at a position and need to re-read it from more
than one continuation, which a single-pass iterator can't support once it has
advanced past that position.

### `LexerTokenStream` and `TokenizerStream` (`TokenStreams.swift`)

Two built-in conformances:

- **`LexerTokenStream`** wraps a DFA `Lexer`'s output (option 1 — the fully
  automated, `GrammarVocabulary`-driven path).
- **`TokenizerStream`** wraps GrammarTokenizer's `Tokenizer` output (option 2
  — the fixed-category, hand-written path).

Both convert their own token representation to `(Terminal, Range<String.Index>)`
on demand; neither leaks its concrete token type into the parser-facing API.

### `GrammarVocabulary` loading (`LexerVocabulary.swift`)

```swift
public extension LexerBuilder {
    mutating func loadVocabulary(_ vocabulary: GrammarVocabulary) -> LexerBuilder
}
```

Registers a vocabulary's `keywords`, `symbols`, and `patterns` as lexer rules,
automating the keyword-vs-identifier priority problem:

- **Keywords** → exact match, `TokenClass.priority = 0`.
- **Symbols** → exact match, `priority = 1`.
- **Patterns** → regex match (passed through as-is), `priority = 2`.

`vocabulary.skippedTypes` is honored per rule, so whitespace/comment tags are
scanned (to keep the DFA advancing) but dropped from the token stream, same
as a manually-built `Lexer`.

#### Why priority, not `\b` word-boundary anchoring

The obvious-looking fix for `"if"` colliding with an identifier pattern is to
anchor it as `\bif\b`. That doesn't apply here:

1. Lexer-FSA's regex engine has no boundary assertion — it's a classical
   Thompson/DFA engine, and boundaries aren't a regular-language primitive.
2. It isn't needed. The DFA lexer already implements **maximal munch**, so
   `"iffy"` never stops at `"if"` — the identifier rule keeps matching all
   four characters, and a longer match always wins. The *only* real ambiguity
   is an exact-length tie (input `"if"` alone matches both rules at length
   2), and that's exactly what `TokenClass.priority` resolves.

#### Why literals are quoted, not backslash-escaped

Grammar symbols are often made of exactly the characters this regex engine
treats as metacharacters (`+ * ( ) [ ] { } | < > ; : ,`). The obvious fix —
backslash-escape every character — is a trap: this engine's escape table
gives `\n`, `\t`, `\r` their control-character meanings, not the literal
letters 'n', 't', 'r', so blanket escaping silently corrupts any keyword
containing one of those letters (`"return"`, `"int"`, `"print"`, …).
`loadVocabulary` instead wraps each literal in double quotes (`"if"` becomes
the pattern `"if"`), using the engine's dedicated quoted-string syntax, under
which everything up to the closing quote is taken verbatim with no escape
processing at all.

---

## Usage

```swift
import Grammar
import Lexer

struct JSONGrammar: GrammarVocabulary {
    enum Tag { case lbrace, rbrace, colon, comma, string, number, boolean }

    let keywords: [String: AnyHashable] = ["true": Tag.boolean, "false": Tag.boolean]
    let symbols: [String: AnyHashable] = ["{": Tag.lbrace, "}": Tag.rbrace, ":": Tag.colon, ",": Tag.comma]
    let patterns: [String: AnyHashable] = [
        "\"[^\"]*\"": Tag.string,
        "[0-9]+": Tag.number,
    ]
    let skippedTypes: Set<AnyHashable> = []
}

var builder = LexerBuilder()
builder.loadVocabulary(JSONGrammar())
let lexer = try builder.build()

let stream = try LexerTokenStream(source: #"{"a": 1}"#, lexer: lexer)
let result = try parser.parse(stream: stream)   // any TokenStream-driven parser
```

`LexerBuilder`'s existing `addRule`/`addSkip` calls can still be mixed in
alongside `loadVocabulary(_:)` on the same builder — rule ids are numbered
starting one past whatever is already registered, so there's no collision
either way round.

---

## Dependencies

- [Lexer-FSA](https://github.com/hakkabon/Lexer-FSA) (regex engine, NFA/DFA, `TokenClass`)
- [Grammar](https://github.com/hakkabon/Grammar) (`GrammarVocabulary`, `Terminal`)
- [GrammarTokenizer](https://github.com/hakkabon/GrammarTokenizer) (`Tokenizer`, bridged by `TokenizerStream`)

---

## License

MIT
