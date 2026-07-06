//
//  TokenStream.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/06.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

/// To decouple your Parser from the underlying Lexer implementation (whether it's your DFA-based
/// engine or a handwritten tokenizer) and to generate tokens lazily "while reading the
/// input", you should apply the Dependency Inversion Principle.
///
/// The "glue-code" will consist of three parts:
/// 1. A Protocol defining how a Parser pulls tokens.
/// 2. Adapters that conform to this protocol (one for the DFA, one for the alternative Tokenizer).
/// 3. The Parser that only knows about the protocol.
/// Here is how you can design this architecture in Swift.

/// 1. The Protocol (The Glue)
/// Parsers typically need to do two things: look at the upcoming token without consuming
/// it (peek), and consume the token (next).

/// Defines the abstract interface for any token provider.
public protocol TokenStream: AnyObject {
    /// Returns the next token without advancing the stream.
    func peek() throws -> Token?
    
    /// Returns the next token and advances the stream.
    func next() throws -> Token?
    
    /// Optional: Context for errors
    var currentLocation: String.Index { get }
}

/// Note: We make this an AnyObject (class-bound) protocol because a stream maintains
/// internal cursor state that the parser will mutate as it consumes tokens).


