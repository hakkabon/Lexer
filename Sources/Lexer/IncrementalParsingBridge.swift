import IncrementalParsing

extension IncrementalLexerEdit {
    /// A restart-and-converge scan can consume one exact replacement. Atomic
    /// batches with multiple replacements intentionally return nil so the
    /// caller takes the coordinator's safe full-scan path.
    public init?(_ change: IncrementalParsing.SourceChange) {
        guard change.replacements.count == 1,
              let replacement = change.replacements.first else { return nil }
        self.init(
            baseRevision: change.before.revision.rawValue,
            replacedRange: replacement.range.lowerBound..<replacement.range.upperBound,
            replacementLength: replacement.replacementUTF16Count)
    }
}

extension RestartAndConvergeTokenizer {
    /// Shared revisioned-source entry point used by language kits and editor
    /// sessions. Inconsistent or multi-edit evidence falls back inside the
    /// tokenizer rather than being misreported as incremental work.
    public mutating func tokenize(
        snapshot: IncrementalParsing.SourceSnapshot,
        change: IncrementalParsing.SourceChange? = nil
    ) -> RestartAndConvergeResult<Token, Element, Diagnostic> {
        let edit: IncrementalLexerEdit?
        if let change,
           change.after == snapshot,
           let single = IncrementalLexerEdit(change) {
            edit = single
        } else {
            edit = nil
        }
        return tokenize(
            revision: snapshot.revision.rawValue,
            text: snapshot.text,
            edit: edit)
    }
}
