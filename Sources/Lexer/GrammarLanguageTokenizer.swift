import Grammar
import IncrementalParsing

/// Converts grammar-driven lexical values into a language kit's public token,
/// lossless element and diagnostic types. Scanning, restart and convergence
/// remain entirely owned by Lexer.
public protocol GrammarLexicalProjection: Sendable {
    associatedtype Token: Sendable
    associatedtype Element: Sendable
    associatedtype Diagnostic: Sendable

    func token(_ token: GrammarLexicalToken) -> Token
    func element(_ element: GrammarLexicalElement) -> Element?
    func diagnostic(_ diagnostic: GrammarLexicalDiagnostic) -> Diagnostic
}

public struct ProjectedLexicalOutput<Projection: GrammarLexicalProjection>: Sendable {
    public let tokens: [Projection.Token]
    public let elements: [Projection.Element]
    public let diagnostics: [Projection.Diagnostic]

    public init(tokens: [Projection.Token], elements: [Projection.Element],
                diagnostics: [Projection.Diagnostic]) {
        self.tokens = tokens
        self.elements = elements
        self.diagnostics = diagnostics
    }
}

public struct ProjectedIncrementalLexResult<
    Projection: GrammarLexicalProjection
>: Sendable {
    public let revision: UInt64
    public let output: ProjectedLexicalOutput<Projection>
    public let metrics: RestartAndConvergeMetrics
}

/// Reusable language-kit facade over the grammar-driven restart-and-converge
/// tokenizer. Language kits provide only a typed projection.
public struct GrammarLanguageTokenizer<
    Projection: GrammarLexicalProjection
>: Sendable {
    private var tokenizer: GrammarIncrementalTokenizer
    private let projection: Projection

    public init(specification: LexicalSpecification,
                projection: Projection) throws {
        tokenizer = RestartAndConvergeTokenizer(
            scanner: try GrammarDrivenLexer(specification: specification))
        self.projection = projection
    }

    public mutating func tokenize(
        revision: UInt64, text: String, edit: IncrementalLexerEdit? = nil
    ) -> ProjectedIncrementalLexResult<Projection> {
        project(tokenizer.tokenize(revision: revision, text: text, edit: edit))
    }

    public mutating func tokenize(
        snapshot: SourceSnapshot, change: SourceChange? = nil
    ) -> ProjectedIncrementalLexResult<Projection> {
        project(tokenizer.tokenize(snapshot: snapshot, change: change))
    }

    public mutating func reset() { tokenizer.reset() }

    private func project(
        _ result: RestartAndConvergeResult<
            GrammarLexicalToken, GrammarLexicalElement,
            GrammarLexicalDiagnostic
        >
    ) -> ProjectedIncrementalLexResult<Projection> {
        ProjectedIncrementalLexResult(
            revision: result.revision,
            output: ProjectedLexicalOutput(
                tokens: result.output.tokens.map(projection.token),
                elements: result.output.elements.compactMap(projection.element),
                diagnostics: result.output.diagnostics.map(projection.diagnostic)),
            metrics: result.metrics)
    }
}
