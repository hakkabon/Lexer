//
//  LexerVocabulary.swift
//  Lexer
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/06.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation
import Grammar

/// Automatic Rule Generation (The Bridge)
/// You can now write a bridge that takes any GrammarVocabulary, transforms it
/// into the LexerRules your NFA/DFA builder expects, and completely automates
/// the priority problem (where if might conflict with an identifier).

public extension LexerBuilder {
    
    /// Bootstraps the Lexer Automata directly from a Grammar Vocabulary
    func loadVocabulary(_ vocabulary: GrammarVocabulary) {
        
        // 1. Keywords (Highest Priority: 0)
        for (keyword, tokenType) in vocabulary.keywords {
            // Keywords usually require word boundaries so "if" doesn't match the start of "iffy"
            // Depending on your Regex engine syntax, this might be \b or similar.
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
            
//            self.addRule(LexerRule(
//                pattern: pattern,
//                tokenType: tokenType,
//                priority: 0,
//                isSkipped: vocabulary.skippedTypes.contains(tokenType)
//            ))
        }
        
        // 2. Symbols (Priority: 1)
        for (symbol, tokenType) in vocabulary.symbols {
            // Symbols MUST be regex-escaped (e.g., "+" becomes "\+", "[" becomes "\[")
            let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
            
//            self.addRule(LexerRule(
//                pattern: escapedSymbol,
//                tokenType: tokenType,
//                priority: 1,
//                isSkipped: vocabulary.skippedTypes.contains(tokenType)
//            ))
        }
        
        // 3. Patterns / Regex (Lowest Priority: 2)
        // This ensures exact strings like "while" or "==" beat general rules like [a-z]+
        for (pattern, tokenType) in vocabulary.patterns {
//            self.addRule(LexerRule(
//                pattern: pattern, // Passed directly, not escaped!
//                tokenType: tokenType,
//                priority: 2,
//                isSkipped: vocabulary.skippedTypes.contains(tokenType)
//            ))
        }
    }
}
