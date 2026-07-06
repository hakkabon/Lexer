import Testing
@testable import Lexer
@testable import LexerFSA


// ──────────────────────────────────────────────────────────────────────────────
// MARK: - The Realistic Parser-Frontend Use Case
// ──────────────────────────────────────────────────────────────────────────────
//
// This is how a parser actually assembles a multi-pattern lexer: register
// each token's pattern with a `LexerBuilder`, then `build()` once. The old
// version of this test built the equivalent by hand with
// `Automaton<Regex>` and explicitly called out, in a trailing comment, that
// there was no way to identify *which* pattern matched without "fancy
// book-keeping over the final states" — that gap is exactly what
// `TokenClass`/`recognizeWithToken` below close.

@Test
func testRegexUnion() async throws {
    let stringTok = TokenClass(id: 1, name: "STRING", priority: 10)
    let numTok    = TokenClass(id: 2, name: "NUM",    priority: 10)
    let floatTok  = TokenClass(id: 3, name: "FLOAT",  priority: 5)

    let STRING = "[a-zA-Z]+"
    let NUM = "[+-]?([0-9])+"
    let FLOAT = "[-+]?[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?"

    var builder = LexerBuilder()
    builder.addRule(pattern: STRING, token: stringTok)
    builder.addRule(pattern: NUM, token: numTok)
    builder.addRule(pattern: FLOAT, token: floatTok)
    let lexer = try builder.build()

    #expect(lexer.dfa.run(string: "abba"), "valid lexeme 'abba'")
    #expect(lexer.dfa.run(string: "123456"), "valid lexeme '123456'")
    #expect(lexer.dfa.run(string: "123.45"), "valid lexeme '123.45'")
    #expect(lexer.dfa.run(string: "-0.123e-6"), "valid lexeme '-0.123e-6'")

    // Unambiguous lexemes resolve to their expected token class with no
    // extra bookkeeping required from the caller.
    #expect(lexer.dfa.recognizeWithToken(string: "abba") == stringTok)
    #expect(lexer.dfa.recognizeWithToken(string: "123.45") == floatTok)
    #expect(lexer.dfa.recognizeWithToken(string: "-0.123e-6") == floatTok)
    // "123456" is ambiguous between NUM and FLOAT (FLOAT's fractional and
    // exponent parts are both optional); FLOAT's lower priority integer
    // wins the determinizer's conflict resolution.
    #expect(lexer.dfa.recognizeWithToken(string: "123456") == floatTok)
}
