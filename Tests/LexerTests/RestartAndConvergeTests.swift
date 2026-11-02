import XCTest
import IncrementalParsing
@testable import Lexer

final class RestartAndConvergeTests: XCTestCase {
    func testReusesStablePrefixAndConvergedSuffix() {
        var tokenizer = RestartAndConvergeTokenizer(scanner: WordScanner())
        let first = tokenizer.tokenize(revision: 1, text: "one two three")
        let second = tokenizer.tokenize(
            revision: 2,
            text: "one too three",
            edit: IncrementalLexerEdit(
                baseRevision: 1, replacedRange: 4..<7, replacementLength: 3))

        XCTAssertFalse(first.metrics.incremental)
        XCTAssertTrue(second.metrics.incremental)
        XCTAssertTrue(second.metrics.converged)
        XCTAssertEqual(second.metrics.reusedPrefixTokenCount, 1)
        XCTAssertEqual(second.metrics.reusedSuffixTokenCount, 2)
        XCTAssertEqual(second.output.tokens.map(\.text), ["one", "too", "three", ""])
        XCTAssertEqual(second.output.tokens[2].id, first.output.tokens[2].id)
    }

    func testInconsistentAndSkippedEditsFallBackToFullScan() {
        var tokenizer = RestartAndConvergeTokenizer(scanner: WordScanner())
        _ = tokenizer.tokenize(revision: 4, text: "one two")
        let result = tokenizer.tokenize(
            revision: 6, text: "one three",
            edit: IncrementalLexerEdit(
                baseRevision: 5, replacedRange: 4..<7, replacementLength: 5))

        XCTAssertFalse(result.metrics.incremental)
        XCTAssertEqual(result.metrics.scannedUTF16Length, 9)
    }

    func testSharedSourceTransitionDrivesIncrementalScanAndBatchFallsBack() throws {
        var tokenizer = RestartAndConvergeTokenizer(scanner: WordScanner())
        let first = IncrementalParsing.SourceSnapshot(
            text: "one two", revision: .init(1))
        _ = tokenizer.tokenize(snapshot: first)

        let single = try IncrementalParsing.SourceEdit(
            baseRevision: .init(1), range: SourceRange(4, 7),
            replacement: "too").applying(to: first)
        let incremented = tokenizer.tokenize(
            snapshot: single.after, change: single)
        XCTAssertTrue(incremented.metrics.incremental)

        let batch = try SourceEditBatch(
            baseRevision: .init(2),
            replacements: [
                .init(range: SourceRange(0, 1), replacement: "O"),
                .init(range: SourceRange(5, 6), replacement: "O"),
            ]).applying(to: single.after)
        let rescanned = tokenizer.tokenize(snapshot: batch.after, change: batch)
        XCTAssertFalse(rescanned.metrics.incremental)
    }
}

private struct WordToken: IncrementalLexicalToken, IncrementalLexicalElement {
    let id: String
    let text: String
    let range: Range<Int>
    let position: LexicalPosition
    let eof: Bool

    var incrementalID: String { id }
    var incrementalTokenID: String? { id }
    var incrementalKind: String { eof ? "eof" : "word" }
    var incrementalLexeme: String { text }
    var incrementalRange: Range<Int> { range }
    var incrementalPosition: LexicalPosition { position }
    var incrementalEndPosition: LexicalPosition {
        LexicalPosition(offset: range.upperBound, line: position.line,
                        column: position.column + range.count)
    }
    var incrementalIsEndOfInput: Bool { eof }

    func relocated(by delta: Int, from oldAnchor: WordToken,
                   to newAnchor: WordToken) -> WordToken {
        WordToken(
            id: id, text: text,
            range: (range.lowerBound + delta)..<(range.upperBound + delta),
            position: LexicalPosition(
                offset: position.offset + delta,
                line: newAnchor.position.line,
                column: newAnchor.position.column
                    + position.column - oldAnchor.position.column),
            eof: eof)
    }

    func relocated(by delta: Int, from oldAnchor: LexicalPosition,
                   to newAnchor: LexicalPosition) -> WordToken {
        WordToken(
            id: id, text: text,
            range: (range.lowerBound + delta)..<(range.upperBound + delta),
            position: LexicalPosition(
                offset: position.offset + delta,
                line: newAnchor.line,
                column: newAnchor.column + position.column - oldAnchor.column),
            eof: eof)
    }
}

private struct WordDiagnostic: IncrementalLexicalDiagnostic {
    let incrementalRange: Range<Int>

    func relocated(by delta: Int) -> WordDiagnostic {
        WordDiagnostic(incrementalRange:
            (incrementalRange.lowerBound + delta)..<(incrementalRange.upperBound + delta))
    }
}

private struct WordScanner: RestartableLexer {
    func scan(text: String, from position: LexicalPosition, revision: UInt64,
              shouldStopBefore: ((WordToken) -> Bool)?)
        -> RestartableLexicalScan<WordToken, WordToken, WordDiagnostic> {
        let source = text as NSString
        var offset = position.offset
        var tokens: [WordToken] = []
        while offset < source.length {
            while offset < source.length && source.character(at: offset) == 32 {
                offset += 1
            }
            guard offset < source.length else { break }
            let start = offset
            while offset < source.length && source.character(at: offset) != 32 {
                offset += 1
            }
            let token = WordToken(
                id: "r\(revision):\(start)",
                text: source.substring(with: NSRange(location: start, length: offset - start)),
                range: start..<offset,
                position: LexicalPosition(offset: start, line: 1, column: start + 1),
                eof: false)
            if shouldStopBefore?(token) == true {
                return RestartableLexicalScan(
                    tokens: tokens, elements: tokens, diagnostics: [],
                    scannedEnd: start, stoppedForConvergence: true)
            }
            tokens.append(token)
        }
        let eof = WordToken(
            id: "r\(revision):\(offset):eof", text: "", range: offset..<offset,
            position: LexicalPosition(offset: offset, line: 1, column: offset + 1),
            eof: true)
        if shouldStopBefore?(eof) == true {
            return RestartableLexicalScan(
                tokens: tokens, elements: tokens, diagnostics: [],
                scannedEnd: offset, stoppedForConvergence: true)
        }
        tokens.append(eof)
        return RestartableLexicalScan(
            tokens: tokens, elements: tokens, diagnostics: [],
            scannedEnd: offset, stoppedForConvergence: false)
    }
}
