//
//  LexerError.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/06.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

/// Reasons a lexer may stop producing tokens.
public enum LexerError: Error, Equatable {
    /// The scanner reached a character it cannot extend any accepting path
    /// from, before reaching the next accepting state. `offset` is the
    /// scalar offset of the offending character.
    case unexpectedCharacter(offset: Int)
    /// The source is non-empty but no rule accepts even a single character.
    case noMatch(offset: Int)
}
