//
//  BlockScopedTokenizer.swift
//  MarkdownEngine
//
//  The live tokenization pipeline. For each block from `BlockParser`:
//  block-level tokens (heading, blockquote, table, block LaTeX, code) still
//  come from the legacy `parseTokens` regexes, while ALL inline tokens come
//  from the AST (`InlineParser` → `InlineASTAdapter`). Results are offset back
//  into document coordinates. Fenced-code blocks emit only their code-block
//  token (no inline markup inside).
//

import Foundation

extension MarkdownTokenizer {

    /// Block-level token kinds still recognized by the legacy regexes; every
    /// inline kind is sourced from the AST instead.
    private static let blockLevelKinds: Set<MarkdownTokenKind> = [
        .heading, .blockquote, .table, .blockLatex, .codeBlock,
    ]

    /// The live tokenizer: legacy block-level tokens + inline AST tokens.
    /// Opaque fenced-code blocks emit only their code-block token (no inline
    /// markup inside — fixes the "inline parsed inside a code block" bug).
    static func parseTokensViaAST(in text: String) -> [MarkdownToken] {
        let ns = text as NSString
        var result: [MarkdownToken] = []
        for block in BlockParser.parse(text) {
            let sub = ns.substring(with: block.range)
            let delta = block.range.location
            let kept: [MarkdownToken]
            if block.kind == .fencedCode {
                kept = parseTokens(in: sub).filter { $0.kind == .codeBlock }
            } else {
                let blockLevel = parseTokens(in: sub).filter { blockLevelKinds.contains($0.kind) }
                let inline = InlineASTAdapter.tokens(from: InlineParser.parse(sub))
                kept = blockLevel + inline
            }
            result.append(contentsOf: kept.map { $0.shifted(by: delta) })
        }
        return result
    }
}

private extension MarkdownToken {
    /// Returns a copy with every range moved forward by `delta` UTF-16 units.
    func shifted(by delta: Int) -> MarkdownToken {
        func move(_ r: NSRange) -> NSRange {
            NSRange(location: r.location + delta, length: r.length)
        }
        return MarkdownToken(
            kind: kind,
            range: move(range),
            contentRange: move(contentRange),
            markerRanges: markerRanges.map(move)
        )
    }
}
