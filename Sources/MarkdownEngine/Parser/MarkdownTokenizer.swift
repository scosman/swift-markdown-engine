//
//  MarkdownTokenizer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Reads plain Markdown text and breaks it into recognizable parts like
// headings, links, lists, code blocks, and LaTeX.
import Foundation

// MARK: - Static Regexes
private extension MarkdownTokenizer {
    static let headingRegex = try! NSRegularExpression(
        pattern: "^\\s*(#{1,6}) +(.*)$",
        options: [.anchorsMatchLines]
    )
    // One blockquote line: optional ≤3-space indent, a run of `>` markers
    // (each optionally followed by one space), then the quoted content.
    static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}((?:>[ \t]?)+)(.*)$"#,
        options: [.anchorsMatchLines]
    )
    static let taskListRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-•]|\d+\.)([ \t]+)(\[[ xX]\])(?=[ \t])"#,
        options: [.anchorsMatchLines]
    )
    static let codeBlockRegex = try! NSRegularExpression(
        pattern: #"^```[ \t]*([A-Za-z0-9_+#.-]*?)[ \t]*\r?\n((?:(?!^```[^\r\n]*$)[\s\S])*?)^(```)[^\r\n]*$"#,
        options: [.anchorsMatchLines]
    )
    static let blockLatexRegex = try! NSRegularExpression(
        pattern: #"(?s)(?<!\$)\$\$(.+?)\$\$"#,
        options: []
    )
    static let tableRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\|.+\|[ \t]*\r?\n[ \t]*\|[- \t:|]+\|[ \t]*(?:\r?\n[ \t]*\|.+\|[ \t]*)*"#,
        options: [.anchorsMatchLines]
    )
}

// MARK: - Tokenizer
enum MarkdownTokenizer {

    static func parseTokens(in text: String) -> [MarkdownToken] {
        var tokens: [MarkdownToken] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Inline emphasis (`*`/`_` bold·italic) and `~~`-strikethrough are no
        // longer tokenized here — `parseTokensViaAST` sources all inline tokens
        // from the AST (`InlineParser` → `InlineASTAdapter`). This pass now only
        // produces the remaining (block-level + link/image/code) token kinds.

        // Headings #... up to ######
        for match in headingRegex.matches(in: text, options: [], range: fullRange) {
            let fullMatchRange = match.range(at: 0)
            let hashes = match.range(at: 1)
            let content = match.range(at: 2)
            let leadingWsLength = hashes.location - fullMatchRange.location
            let tokenRange = NSRange(location: hashes.location, length: fullMatchRange.length - leadingWsLength)
            var markerRanges = [hashes]
            let hashEnd = hashes.location + hashes.length
            if hashEnd < nsText.length {
                let spaceRange = NSRange(location: hashEnd, length: 1)
                if nsText.substring(with: spaceRange) == " " {
                    markerRanges.append(spaceRange)
                }
            }
            tokens.append(MarkdownToken(kind: .heading,
                                        range: tokenRange,
                                        contentRange: content,
                                        markerRanges: markerRanges))
        }

        // Fenced code blocks ```lang\n...\n```
        for match in codeBlockRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let contentRange = match.range(at: 2)
            let closingFence = match.range(at: 3)
            let tokenEnd = closingFence.location + closingFence.length
            let tokenRange = NSRange(location: full.location, length: tokenEnd - full.location)
            let openingLength = max(3, min(contentRange.location - tokenRange.location, tokenRange.length))
            let openingMarker = NSRange(location: tokenRange.location, length: openingLength)
            _ = contentRange.location + contentRange.length
            let closingMarker = closingFence
            
            tokens.append(MarkdownToken(kind: .codeBlock,
                                        range: tokenRange,
                                        contentRange: contentRange,
                                        markerRanges: [openingMarker, closingMarker]))
        }
        
        // Blockquote lines. After fenced code so a `>` inside a code block
        // stays literal. One token per line; the styler stitches the bar.
        for match in blockquoteRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let marker = match.range(at: 1)
            let content = match.range(at: 2)
            let inCode = tokens.contains {
                ($0.kind == .codeBlock || $0.kind == .blockLatex)
                && NSIntersectionRange($0.range, full).length > 0
            }
            if inCode { continue }
            tokens.append(MarkdownToken(kind: .blockquote,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [marker]))
        }

        // GFM tables. Parsed after code blocks so we can skip table-shaped
        // lines inside fenced code; sits before block-latex/inline-latex
        // because we don't want `$$...$$` rules trying to claim ranges that
        // belong to a table cell.
        for match in tableRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let inCode = tokens.contains { $0.kind == .codeBlock && NSIntersectionRange($0.range, full).length > 0 }
            if inCode { continue }
            tokens.append(MarkdownToken(kind: .table,
                                        range: full,
                                        contentRange: full,
                                        markerRanges: []))
        }

        // Block LaTeX $$...$$ (multiline)
        for match in blockLatexRegex.matches(in: text, options: [], range: fullRange) {
            let full = match.range(at: 0)
            let inCode = tokens.contains { $0.kind == .codeBlock && NSIntersectionRange($0.range, full).length > 0 }
            if inCode { continue }
            
            let content = match.range(at: 1)
            let openMarker = NSRange(location: full.location, length: 2)
            let closeMarker = NSRange(location: full.location + full.length - 2, length: 2)
            tokens.append(MarkdownToken(kind: .blockLatex,
                                        range: full,
                                        contentRange: content,
                                        markerRanges: [openMarker, closeMarker]))
        }

        // MARK: Backslash escapes (CommonMark §2.4)
        //
        // A backslash before any ASCII punctuation character makes that
        // character literal — it loses its Markdown meaning. We scan left
        // to right so that `\\` consumes itself (the even/odd-backslash
        // rule): the char after an escaping backslash can never itself
        // start a new escape. Escapes do not apply inside fenced code or
        // block LaTeX, where a backslash is already literal.
        let asciiPunctuation: Set<unichar> = {
            let chars = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
            return Set(chars.utf16)
        }()
        let escapeFreeRanges: [NSRange] = tokens
            .filter { $0.kind == .codeBlock || $0.kind == .blockLatex }
            .map { $0.range }
        func isEscapeFree(_ loc: Int) -> Bool {
            for r in escapeFreeRanges where loc >= r.location && loc < NSMaxRange(r) {
                return true
            }
            return false
        }

        var escapedCharOffsets: Set<Int> = []
        var escapeTokens: [MarkdownToken] = []
        var i = 0
        let textLength = nsText.length
        while i < textLength - 1 {
            if nsText.character(at: i) == 0x5C /* backslash */, !isEscapeFree(i) {
                let next = nsText.character(at: i + 1)
                if asciiPunctuation.contains(next) {
                    escapedCharOffsets.insert(i + 1)
                    escapeTokens.append(MarkdownToken(
                        kind: .backslashEscape,
                        range: NSRange(location: i, length: 2),
                        contentRange: NSRange(location: i + 1, length: 1),
                        markerRanges: [NSRange(location: i, length: 1)]
                    ))
                    i += 2   // the escaped char cannot start another escape
                    continue
                }
            }
            i += 1
        }

        if !escapedCharOffsets.isEmpty {
            // An inline span whose opening or closing delimiter sits on an
            // escaped (now-literal) character is not a real span — drop it
            // so `\*not italic\*` / `` \` not code \` `` stay literal.
            let escapableKinds: Set<MarkdownTokenKind> = [
                .italic, .bold, .boldItalic, .strikethrough,
                .inlineCode, .inlineLatex, .blockLatex,
                .link, .wikiLink, .imageLink, .imageEmbed
            ]
            tokens.removeAll { token in
                guard escapableKinds.contains(token.kind) else { return false }
                return token.markerRanges.contains { escapedCharOffsets.contains($0.location) }
            }
        }
        tokens.append(contentsOf: escapeTokens)

        return tokens
    }

    // MARK: - Code Block Helpers

    static func extractLanguage(from token: MarkdownToken, in text: String) -> String? {
        guard token.kind == .codeBlock,
              let openingMarker = token.markerRanges.first,
              openingMarker.length > 4 else { return nil }
        
        let nsText = text as NSString
        let langRange = NSRange(location: openingMarker.location + 3, length: openingMarker.length - 4)
        
        guard langRange.location + langRange.length <= nsText.length else { return nil }
        
        let langString = nsText.substring(with: langRange).trimmingCharacters(in: .whitespacesAndNewlines)
        return langString.isEmpty ? nil : langString
    }
}
