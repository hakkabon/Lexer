import Foundation
import Grammar

public struct GrammarLexicalToken: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let lexeme: String
    public let range: Range<Int>
    public let position: LexicalPosition
    public let endPosition: LexicalPosition
    public let isEndOfInput: Bool

    public init(id: String, kind: String, lexeme: String, range: Range<Int>,
                position: LexicalPosition, endPosition: LexicalPosition,
                isEndOfInput: Bool = false) {
        self.id = id
        self.kind = kind
        self.lexeme = lexeme
        self.range = range
        self.position = position
        self.endPosition = endPosition
        self.isEndOfInput = isEndOfInput
    }
}

public enum GrammarLexicalElementKind: Sendable, Equatable {
    case token(String)
    case trivia(String)
    case invalid
}

public struct GrammarLexicalElement: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: GrammarLexicalElementKind
    public let lexeme: String
    public let range: Range<Int>
    public let position: LexicalPosition

    public init(id: String, kind: GrammarLexicalElementKind, lexeme: String,
                range: Range<Int>, position: LexicalPosition) {
        self.id = id
        self.kind = kind
        self.lexeme = lexeme
        self.range = range
        self.position = position
    }
}

public struct GrammarLexicalDiagnostic: Sendable, Equatable {
    public let message: String
    public let range: Range<Int>

    public init(message: String, range: Range<Int>) {
        self.message = message
        self.range = range
    }
}

public enum GrammarDrivenLexerError: Error, Equatable {
    case duplicateRule(String)
    case invalidRegularExpression(rule: String, pattern: String)
    case emptyMatch(String)
}

/// Compiles and scans the lexical specification carried by a Grammar artifact.
/// Matching is maximal-munch; explicit priority and declaration order break
/// equal-length ties. All offsets are UTF-16, matching TextKit, LSP, and the
/// incremental parsing contracts.
public struct GrammarDrivenLexer: RestartableLexer {
    private struct Rule: @unchecked Sendable {
        let definition: LexicalRuleDefinition
        let expression: NSRegularExpression?
        let ordinal: Int
    }

    private let rules: [Rule]

    public init(specification: LexicalSpecification) throws {
        var names = Set<String>()
        var compiled: [Rule] = []
        for (ordinal, definition) in specification.rules.enumerated() {
            guard names.insert(definition.name).inserted else {
                throw GrammarDrivenLexerError.duplicateRule(definition.name)
            }
            let expression: NSRegularExpression?
            if case .regularExpression(let pattern) = definition.matcher {
                do {
                    expression = try NSRegularExpression(pattern: pattern)
                } catch {
                    throw GrammarDrivenLexerError.invalidRegularExpression(
                        rule: definition.name, pattern: pattern)
                }
                if expression?.firstMatch(
                    in: "", range: NSRange(location: 0, length: 0))?.range.length == 0 {
                    throw GrammarDrivenLexerError.emptyMatch(definition.name)
                }
            } else {
                expression = nil
            }
            compiled.append(Rule(
                definition: definition, expression: expression, ordinal: ordinal))
        }
        rules = compiled
    }

    public init(grammar: Grammar) throws {
        try self.init(specification: grammar.lexicalSpecification)
    }

    public func scan(
        text: String, from initial: LexicalPosition, revision: UInt64,
        shouldStopBefore: ((GrammarLexicalToken) -> Bool)?
    ) -> RestartableLexicalScan<GrammarLexicalToken, GrammarLexicalElement,
                                GrammarLexicalDiagnostic> {
        let source = text as NSString
        var offset = initial.offset
        var position = initial
        var tokens: [GrammarLexicalToken] = []
        var elements: [GrammarLexicalElement] = []
        var diagnostics: [GrammarLexicalDiagnostic] = []
        var ordinal = 0

        while offset < source.length {
            let candidates = rules.compactMap { rule -> (Rule, Int, Bool)? in
                guard let match = match(rule, in: source, at: offset), match.length > 0 else {
                    return nil
                }
                return (rule, match.length, match.unterminated)
            }
            let selected = candidates.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.definition.priority != $1.0.definition.priority {
                    return $0.0.definition.priority < $1.0.definition.priority
                }
                return $0.0.ordinal < $1.0.ordinal
            }.first

            guard let (rule, length, unterminated) = selected else {
                let length = utf16ScalarLength(in: source, at: offset)
                let range = offset..<(offset + length)
                let lexeme = source.substring(with: NSRange(location: offset, length: length))
                let id = "v\(revision):invalid:\(offset):\(ordinal)"
                let end = advanced(position, by: lexeme)
                let token = GrammarLexicalToken(
                    id: id, kind: "$INVALID", lexeme: lexeme,
                    range: range, position: position, endPosition: end)
                if shouldStopBefore?(token) == true {
                    return RestartableLexicalScan(
                        tokens: tokens, elements: elements, diagnostics: diagnostics,
                        scannedEnd: offset, stoppedForConvergence: true)
                }
                tokens.append(token)
                elements.append(GrammarLexicalElement(
                    id: id, kind: .invalid, lexeme: lexeme,
                    range: range, position: position))
                diagnostics.append(GrammarLexicalDiagnostic(
                    message: "Unexpected character '\(lexeme)'", range: range))
                position = end
                offset += length
                ordinal += 1
                continue
            }

            let range = offset..<(offset + length)
            let lexeme = source.substring(with: NSRange(location: offset, length: length))
            let end = advanced(position, by: lexeme)
            let id = "v\(revision):\(offset):\(ordinal)"
            if rule.definition.channel == .significant {
                let token = GrammarLexicalToken(
                    id: id, kind: rule.definition.name, lexeme: lexeme,
                    range: range, position: position, endPosition: end)
                if shouldStopBefore?(token) == true {
                    return RestartableLexicalScan(
                        tokens: tokens, elements: elements, diagnostics: diagnostics,
                        scannedEnd: offset, stoppedForConvergence: true)
                }
                tokens.append(token)
                elements.append(GrammarLexicalElement(
                    id: id, kind: .token(rule.definition.name), lexeme: lexeme,
                    range: range, position: position))
            } else {
                elements.append(GrammarLexicalElement(
                    id: id, kind: .trivia(rule.definition.name), lexeme: lexeme,
                    range: range, position: position))
            }
            if unterminated {
                diagnostics.append(GrammarLexicalDiagnostic(
                    message: "Unterminated \(rule.definition.name)", range: range))
            }
            offset += length
            position = end
            ordinal += 1
        }

        let eof = GrammarLexicalToken(
            id: "v\(revision):\(offset):eof", kind: "$EOF", lexeme: "",
            range: offset..<offset, position: position, endPosition: position,
            isEndOfInput: true)
        if shouldStopBefore?(eof) == true {
            return RestartableLexicalScan(
                tokens: tokens, elements: elements, diagnostics: diagnostics,
                scannedEnd: offset, stoppedForConvergence: true)
        }
        tokens.append(eof)
        return RestartableLexicalScan(
            tokens: tokens, elements: elements, diagnostics: diagnostics,
            scannedEnd: offset, stoppedForConvergence: false)
    }

    private func match(_ rule: Rule, in source: NSString, at offset: Int)
        -> (length: Int, unterminated: Bool)? {
        switch rule.definition.matcher {
        case .literal(let value):
            return literal(value, in: source, at: offset).map { ($0, false) }
        case .literals(let values):
            return values.compactMap { literal($0, in: source, at: offset) }
                .max().map { ($0, false) }
        case .characterRange(let lower, let upper):
            guard offset < source.length, lower.utf16.count == 1, upper.utf16.count == 1,
                  let first = lower.utf16.first, let last = upper.utf16.first else { return nil }
            let value = source.character(at: offset)
            return (first...last).contains(value) ? (1, false) : nil
        case .regularExpression:
            guard let result = rule.expression?.firstMatch(
                in: source as String,
                options: [.anchored],
                range: NSRange(location: offset, length: source.length - offset)),
                result.range.location == offset else { return nil }
            return (result.range.length, false)
        case .lineComment(let prefix):
            guard let prefixLength = literal(prefix, in: source, at: offset) else { return nil }
            var end = offset + prefixLength
            while end < source.length {
                let value = source.character(at: end)
                if value == 10 || value == 13 { break }
                end += utf16ScalarLength(in: source, at: end)
            }
            return (end - offset, false)
        case .blockComment(let open, let close):
            guard let openingLength = literal(open, in: source, at: offset) else { return nil }
            let searchStart = offset + openingLength
            let found = source.range(
                of: close, options: [],
                range: NSRange(location: searchStart, length: source.length - searchStart))
            if found.location == NSNotFound { return (source.length - offset, true) }
            return (found.location + found.length - offset, false)
        }
    }

    private func literal(_ value: String, in source: NSString, at offset: Int) -> Int? {
        let length = (value as NSString).length
        guard length > 0, offset + length <= source.length,
              source.substring(with: NSRange(location: offset, length: length)) == value else {
            return nil
        }
        return length
    }
}

public typealias GrammarIncrementalTokenizer =
    RestartAndConvergeTokenizer<GrammarDrivenLexer>

extension GrammarLexicalToken: IncrementalLexicalToken {
    public var incrementalID: String { id }
    public var incrementalKind: String { kind }
    public var incrementalLexeme: String { lexeme }
    public var incrementalRange: Range<Int> { range }
    public var incrementalPosition: LexicalPosition { position }
    public var incrementalEndPosition: LexicalPosition { endPosition }
    public var incrementalIsEndOfInput: Bool { isEndOfInput }

    public func relocated(by delta: Int, from oldAnchor: Self, to newAnchor: Self) -> Self {
        let relocatedPosition = relocate(
            position, from: oldAnchor.position, to: newAnchor.position, delta: delta)
        let relocatedEnd = relocate(
            endPosition, from: oldAnchor.position, to: newAnchor.position, delta: delta)
        return GrammarLexicalToken(
            id: id, kind: kind, lexeme: lexeme,
            range: (range.lowerBound + delta)..<(range.upperBound + delta),
            position: relocatedPosition, endPosition: relocatedEnd,
            isEndOfInput: isEndOfInput)
    }
}

extension GrammarLexicalElement: IncrementalLexicalElement {
    public var incrementalID: String { id }
    public var incrementalTokenID: String? {
        if case .token = kind { return id }
        return nil
    }
    public var incrementalRange: Range<Int> { range }

    public func relocated(by delta: Int, from oldAnchor: LexicalPosition,
                          to newAnchor: LexicalPosition) -> Self {
        GrammarLexicalElement(
            id: id, kind: kind, lexeme: lexeme,
            range: (range.lowerBound + delta)..<(range.upperBound + delta),
            position: relocate(position, from: oldAnchor, to: newAnchor, delta: delta))
    }
}

extension GrammarLexicalDiagnostic: IncrementalLexicalDiagnostic {
    public var incrementalRange: Range<Int> { range }
    public func relocated(by delta: Int) -> Self {
        GrammarLexicalDiagnostic(
            message: message,
            range: (range.lowerBound + delta)..<(range.upperBound + delta))
    }
}

private func utf16ScalarLength(in source: NSString, at offset: Int) -> Int {
    guard offset + 1 < source.length else { return 1 }
    let first = source.character(at: offset)
    let second = source.character(at: offset + 1)
    return (0xD800...0xDBFF).contains(first) && (0xDC00...0xDFFF).contains(second) ? 2 : 1
}

private func advanced(_ position: LexicalPosition, by text: String) -> LexicalPosition {
    let source = text as NSString
    var offset = 0
    var line = position.line
    var column = position.column
    while offset < source.length {
        let value = source.character(at: offset)
        if value == 13 {
            offset += offset + 1 < source.length && source.character(at: offset + 1) == 10 ? 2 : 1
            line += 1
            column = 1
        } else if value == 10 {
            offset += 1
            line += 1
            column = 1
        } else {
            let length = utf16ScalarLength(in: source, at: offset)
            offset += length
            column += length
        }
    }
    return LexicalPosition(
        offset: position.offset + source.length, line: line, column: column)
}

private func relocate(_ position: LexicalPosition, from old: LexicalPosition,
                      to new: LexicalPosition, delta: Int) -> LexicalPosition {
    let line = new.line + position.line - old.line
    let column = position.line == old.line
        ? new.column + position.column - old.column : position.column
    return LexicalPosition(offset: position.offset + delta, line: line, column: column)
}
