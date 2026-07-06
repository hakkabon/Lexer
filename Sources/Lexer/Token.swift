//
//  Token.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/06.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import LexerFSA

/// Token Tracking for Lexer Output
///
/// A token emitted by `Lexer`: the token class plus the slice of the source
/// string it consumed and the source position at which it began.
public struct Token: Equatable {
    /// The resolved token class (lowest-priority-integer accepting state).
    public let tokenClass: TokenClass
    /// The lexeme text matched by the token.
    public let lexeme: Substring
    /// Scalar offset of the first character of `lexeme` in the source string.
    public let startOffset: Int
    /// Scalar offset one past the last character of `lexeme`.
    public let endOffset: Int

    public init(tokenClass: TokenClass, lexeme: Substring, startOffset: Int, endOffset: Int) {
        self.tokenClass = tokenClass
        self.lexeme = lexeme
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}
