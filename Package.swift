// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Lexer",
    platforms: [.macOS(.v11),.iOS(.v12)],
    products: [
        .library(name: "Lexer", targets: ["Lexer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/hakkabon/Lexer-FSA.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/hakkabon/Grammar.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/hakkabon/GrammarTokenizer.git", .upToNextMinor(from: "0.1.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Lexer",
            dependencies: [
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "LexerFSA", package: "lexer-fsa"),
                .product(name: "Tokenizer", package: "GrammarTokenizer"),
            ]
        ),
        .testTarget(
            name: "LexerTests",
            dependencies: [
                "Lexer",
                .product(name: "LexerFSA", package: "lexer-fsa"),
            ]
        ),
    ]
)
