import Grammar
import Testing
@testable import Lexer

@Suite("Grammar-driven lexer")
struct GrammarDrivenLexerTests {
    private var specification: LexicalSpecification {
        LexicalSpecification(rules: [
            .init(name: "IF", matcher: .literal("if"), priority: 0),
            .init(name: "ASSIGN", matcher: .literal(":="), priority: 1),
            .init(name: "IDENTIFIER",
                  matcher: .regularExpression("[A-Za-z_][A-Za-z0-9_]*"), priority: 2),
            .init(name: "NUMBER", matcher: .regularExpression("[0-9]+"), priority: 2),
            .init(name: "WHITESPACE", matcher: .regularExpression("\\s+"),
                  channel: .trivia, priority: 3),
            .init(name: "BLOCK_COMMENT", matcher: .blockComment(open: "/*", close: "*/"),
                  channel: .trivia, priority: 3),
        ])
    }

    @Test func maximalMunchRetainsLosslessTriviaAndUsesUTF16() throws {
        let scanner = try GrammarDrivenLexer(specification: specification)
        let source = "if iffy /* note */ := 2"
        let result = scanner.scan(
            text: source, from: .start, revision: 1, shouldStopBefore: nil)

        #expect(result.tokens.map(\.kind) == [
            "IF", "IDENTIFIER", "ASSIGN", "NUMBER", "$EOF",
        ])
        #expect(result.elements.map(\.lexeme).joined() == source)
        #expect(result.elements.contains {
            if case .trivia("BLOCK_COMMENT") = $0.kind { true } else { false }
        })

        let invalid = scanner.scan(
            text: "🙂", from: .start, revision: 2, shouldStopBefore: nil)
        #expect(invalid.tokens.first?.range == 0..<2)
        #expect(invalid.diagnostics.first?.range == 0..<2)
    }

    @Test func artifactScannerParticipatesInRestartAndConverge() throws {
        var tokenizer = RestartAndConvergeTokenizer(
            scanner: try GrammarDrivenLexer(specification: specification))
        let first = tokenizer.tokenize(revision: 1, text: "if alpha := 1")
        let second = tokenizer.tokenize(
            revision: 2, text: "if beta := 1",
            edit: IncrementalLexerEdit(
                baseRevision: 1, replacedRange: 3..<8, replacementLength: 4))

        #expect(second.metrics.incremental)
        #expect(second.metrics.converged)
        #expect(second.metrics.reusedPrefixTokenCount == 1)
        #expect(second.metrics.reusedSuffixTokenCount > 0)
        #expect(second.output.tokens.last { $0.kind == "NUMBER" }?.id
            == first.output.tokens.last { $0.kind == "NUMBER" }?.id)
    }

    @Test func unterminatedDelimitedTriviaProducesBoundedDiagnostic() throws {
        let scanner = try GrammarDrivenLexer(specification: specification)
        let result = scanner.scan(
            text: "if /* open", from: .start, revision: 1,
            shouldStopBefore: nil)

        #expect(result.diagnostics.map(\.message) == ["Unterminated BLOCK_COMMENT"])
        #expect(result.diagnostics[0].range == 3..<10)
    }
}
