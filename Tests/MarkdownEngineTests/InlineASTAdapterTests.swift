//
//  InlineASTAdapterTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5 — verifies the inline-AST → token adapter: the intended
//  divergences from the (now-removed) legacy inline tokenizer, i.e. the bug fixes.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5 — inline AST → token adapter")
struct InlineASTAdapterTests {

    // MARK: - Intended divergences (bug fixes)

    @Test("bug 4: link URL with balanced parens is one whole link token")
    func bug4LinkParens() {
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse("[a](b(c))"))
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .link)
        #expect(tokens.first?.range == NSRange(location: 0, length: 9))
    }

    @Test("bug 3: a $…$ that would cross a code span produces no latex token")
    func bug3NoCrossCodeLatex() {
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse("$x `c` y$"))
        #expect(!tokens.contains { $0.kind == .inlineLatex })
        #expect(tokens.contains { $0.kind == .inlineCode })
    }
}
