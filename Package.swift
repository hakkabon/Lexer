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
        .package(url: "https://github.com/hakkabon/Lexer-FSA.git", revision: "5289a38e507bbf63863699a1eb9ac7a4d19aafba"),
        .package(url: "https://github.com/hakkabon/Grammar.git", revision: "69f85d7a493e1862412c34493e3656e94331df06"),
        .package(url: "https://github.com/hakkabon/GrammarTokenizer.git", revision: "880af85a1f5809866f9656405c801fd04bcb4df9"),
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
