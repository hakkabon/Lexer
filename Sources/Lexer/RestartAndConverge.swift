/// A UTF-16 position at which a restartable lexer is in its normal state.
public struct LexicalPosition: Sendable, Equatable {
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(offset: Int, line: Int, column: Int) {
        precondition(offset >= 0 && line >= 1 && column >= 1)
        self.offset = offset
        self.line = line
        self.column = column
    }

    public static let start = LexicalPosition(offset: 0, line: 1, column: 1)
}

/// One replacement expressed in UTF-16 code units.
public struct IncrementalLexerEdit: Sendable, Equatable {
    public let baseRevision: UInt64?
    public let replacedRange: Range<Int>
    public let replacementLength: Int

    public init(baseRevision: UInt64? = nil, replacedRange: Range<Int>,
                replacementLength: Int) {
        precondition(replacedRange.lowerBound >= 0 && replacementLength >= 0)
        self.baseRevision = baseRevision
        self.replacedRange = replacedRange
        self.replacementLength = replacementLength
    }
}

/// A significant token that can participate in restart-and-converge reuse.
public protocol IncrementalLexicalToken: Sendable {
    associatedtype Kind: Sendable & Equatable

    var incrementalID: String { get }
    var incrementalKind: Kind { get }
    var incrementalLexeme: String { get }
    var incrementalRange: Range<Int> { get }
    var incrementalPosition: LexicalPosition { get }
    /// The scanner's normal-state position immediately after this token.
    var incrementalEndPosition: LexicalPosition { get }
    var incrementalIsEndOfInput: Bool { get }

    func relocated(by delta: Int, from oldAnchor: Self, to newAnchor: Self) -> Self
}

/// Trivia or other lossless lexical evidence retained beside parser tokens.
public protocol IncrementalLexicalElement: Sendable {
    var incrementalID: String { get }
    /// The significant token represented by this element, or `nil` for trivia.
    var incrementalTokenID: String? { get }
    var incrementalRange: Range<Int> { get }

    func relocated(by delta: Int,
                   from oldAnchor: LexicalPosition,
                   to newAnchor: LexicalPosition) -> Self
}

/// A source-located lexer diagnostic that can be shifted with a reused suffix.
public protocol IncrementalLexicalDiagnostic: Sendable {
    var incrementalRange: Range<Int> { get }
    func relocated(by delta: Int) -> Self
}

public struct RestartableLexicalScan<Token: IncrementalLexicalToken,
                                     Element: IncrementalLexicalElement,
                                     Diagnostic: IncrementalLexicalDiagnostic>: Sendable {
    public let tokens: [Token]
    public let elements: [Element]
    public let diagnostics: [Diagnostic]
    public let scannedEnd: Int
    public let stoppedForConvergence: Bool

    public init(tokens: [Token], elements: [Element], diagnostics: [Diagnostic],
                scannedEnd: Int, stoppedForConvergence: Bool) {
        self.tokens = tokens
        self.elements = elements
        self.diagnostics = diagnostics
        self.scannedEnd = scannedEnd
        self.stoppedForConvergence = stoppedForConvergence
    }
}

public protocol RestartableLexer: Sendable {
    associatedtype Token: IncrementalLexicalToken
    associatedtype Element: IncrementalLexicalElement
    associatedtype Diagnostic: IncrementalLexicalDiagnostic

    /// Scan from a known-normal boundary. Call `shouldStopBefore` before
    /// appending a token so the matching token can be reused with the suffix.
    func scan(text: String, from position: LexicalPosition, revision: UInt64,
              shouldStopBefore: ((Token) -> Bool)?)
        -> RestartableLexicalScan<Token, Element, Diagnostic>
}

public struct IncrementalLexicalOutput<Token: IncrementalLexicalToken,
                                      Element: IncrementalLexicalElement,
                                      Diagnostic: IncrementalLexicalDiagnostic>: Sendable {
    public let tokens: [Token]
    public let elements: [Element]
    public let diagnostics: [Diagnostic]

    public init(tokens: [Token], elements: [Element], diagnostics: [Diagnostic]) {
        self.tokens = tokens
        self.elements = elements
        self.diagnostics = diagnostics
    }
}

public struct RestartAndConvergeMetrics: Sendable, Equatable {
    public let scannedUTF16Length: Int
    public let generatedTokenCount: Int
    public let reusedPrefixTokenCount: Int
    public let reusedSuffixTokenCount: Int
    public let converged: Bool
    public let incremental: Bool

    public init(scannedUTF16Length: Int, generatedTokenCount: Int,
                reusedPrefixTokenCount: Int, reusedSuffixTokenCount: Int,
                converged: Bool, incremental: Bool) {
        self.scannedUTF16Length = scannedUTF16Length
        self.generatedTokenCount = generatedTokenCount
        self.reusedPrefixTokenCount = reusedPrefixTokenCount
        self.reusedSuffixTokenCount = reusedSuffixTokenCount
        self.converged = converged
        self.incremental = incremental
    }
}

public struct RestartAndConvergeResult<Token: IncrementalLexicalToken,
                                      Element: IncrementalLexicalElement,
                                      Diagnostic: IncrementalLexicalDiagnostic>: Sendable {
    public let revision: UInt64
    public let output: IncrementalLexicalOutput<Token, Element, Diagnostic>
    public let metrics: RestartAndConvergeMetrics
}

/// Generic incremental tokenization for a single document.
///
/// The coordinator owns reuse policy and state. A language scanner only needs
/// to restart at a supplied normal-state position and honor a stop predicate.
public struct RestartAndConvergeTokenizer<Scanner: RestartableLexer>: Sendable {
    public typealias Token = Scanner.Token
    public typealias Element = Scanner.Element
    public typealias Diagnostic = Scanner.Diagnostic

    private struct State: Sendable {
        let revision: UInt64
        let text: String
        let output: IncrementalLexicalOutput<Token, Element, Diagnostic>
    }

    var scanner: Scanner
    private var previous: State?

    public init(scanner: Scanner) {
        self.scanner = scanner
    }

    public mutating func tokenize(revision: UInt64, text: String,
                                  edit: IncrementalLexerEdit? = nil)
        -> RestartAndConvergeResult<Token, Element, Diagnostic> {
        guard let old = previous,
              let edit,
              revision > old.revision,
              edit.baseRevision == nil || edit.baseRevision == old.revision,
              isConsistent(edit: edit, oldText: old.text, newText: text) else {
            return fullTokenize(revision: revision, text: text)
        }

        let oldTokens = old.output.tokens
        let prefixCount = oldTokens.prefix { token in
            !token.incrementalIsEndOfInput
                && token.incrementalRange.upperBound < edit.replacedRange.lowerBound
        }.count
        let prefix = Array(oldTokens.prefix(prefixCount))
        let restart = prefix.last?.incrementalEndPosition ?? .start

        let delta = edit.replacementLength - edit.replacedRange.count
        let newEditEnd = edit.replacedRange.lowerBound + edit.replacementLength
        let oldIndexByLocation = Dictionary(uniqueKeysWithValues:
            oldTokens.enumerated().map { ($0.element.incrementalRange.lowerBound, $0.offset) })
        var convergedOldIndex: Int?
        var convergencePair: (new: Token, old: Token)?

        let scanned = scanner.scan(
            text: text, from: restart, revision: revision
        ) { newToken in
            guard newToken.incrementalRange.lowerBound >= newEditEnd else { return false }
            let oldLocation = newToken.incrementalRange.lowerBound - delta
            guard let oldIndex = oldIndexByLocation[oldLocation],
                  oldIndex >= prefixCount else { return false }
            let oldToken = oldTokens[oldIndex]
            guard oldToken.incrementalKind == newToken.incrementalKind,
                  oldToken.incrementalLexeme == newToken.incrementalLexeme else {
                return false
            }
            convergedOldIndex = oldIndex
            convergencePair = (newToken, oldToken)
            return true
        }

        var tokens = prefix + scanned.tokens
        let elementPrefix = old.output.elements.filter {
            $0.incrementalRange.upperBound <= restart.offset
        }
        var elements = elementPrefix + scanned.elements
        var suffix: [Token] = []
        if let oldIndex = convergedOldIndex, let pair = convergencePair {
            suffix = oldTokens[oldIndex...].map {
                $0.relocated(by: delta, from: pair.old, to: pair.new)
            }
            tokens.append(contentsOf: suffix)
            let elementIndex = old.output.elements.firstIndex(where: {
                $0.incrementalTokenID == pair.old.incrementalID
            }) ?? old.output.elements.firstIndex(where: {
                $0.incrementalRange.lowerBound
                    >= pair.old.incrementalRange.lowerBound
            })
            if let elementIndex {
                elements.append(contentsOf: old.output.elements[elementIndex...].map {
                    $0.relocated(by: delta,
                                 from: pair.old.incrementalPosition,
                                 to: pair.new.incrementalPosition)
                })
            }
        }

        let diagnosticPrefix = old.output.diagnostics.filter {
            $0.incrementalRange.upperBound <= restart.offset
        }
        var diagnostics = diagnosticPrefix + scanned.diagnostics
        if let pair = convergencePair {
            diagnostics.append(contentsOf: old.output.diagnostics
                .filter {
                    $0.incrementalRange.lowerBound
                        >= pair.old.incrementalRange.lowerBound
                }
                .map { $0.relocated(by: delta) })
        }

        let output = IncrementalLexicalOutput(
            tokens: tokens, elements: elements, diagnostics: diagnostics)
        previous = State(revision: revision, text: text, output: output)
        return RestartAndConvergeResult(
            revision: revision,
            output: output,
            metrics: RestartAndConvergeMetrics(
                scannedUTF16Length: max(0, scanned.scannedEnd - restart.offset),
                generatedTokenCount: scanned.tokens.count,
                reusedPrefixTokenCount: prefix.count,
                reusedSuffixTokenCount: suffix.count,
                converged: scanned.stoppedForConvergence,
                incremental: true))
    }

    public mutating func reset() { previous = nil }

    /// Replaces lexical semantics and discards cached tokens. Returns the
    /// number of significant tokens that were invalidated.
    @discardableResult
    public mutating func replaceScanner(_ scanner: Scanner) -> Int {
        let removed = previous?.output.tokens.count ?? 0
        self.scanner = scanner
        previous = nil
        return removed
    }

    var cachedTokenCount: Int { previous?.output.tokens.count ?? 0 }

    mutating func replaceScannerPreservingCache(_ scanner: Scanner) {
        self.scanner = scanner
    }

    private mutating func fullTokenize(revision: UInt64, text: String)
        -> RestartAndConvergeResult<Token, Element, Diagnostic> {
        let scanned = scanner.scan(
            text: text, from: .start, revision: revision, shouldStopBefore: nil)
        let output = IncrementalLexicalOutput(
            tokens: scanned.tokens,
            elements: scanned.elements,
            diagnostics: scanned.diagnostics)
        previous = State(revision: revision, text: text, output: output)
        return RestartAndConvergeResult(
            revision: revision,
            output: output,
            metrics: RestartAndConvergeMetrics(
                scannedUTF16Length: text.utf16.count,
                generatedTokenCount: scanned.tokens.count,
                reusedPrefixTokenCount: 0,
                reusedSuffixTokenCount: 0,
                converged: false,
                incremental: false))
    }

    private func isConsistent(edit: IncrementalLexerEdit,
                              oldText: String, newText: String) -> Bool {
        let oldLength = oldText.utf16.count
        return edit.replacedRange.upperBound <= oldLength
            && oldLength - edit.replacedRange.count + edit.replacementLength
                == newText.utf16.count
    }
}
