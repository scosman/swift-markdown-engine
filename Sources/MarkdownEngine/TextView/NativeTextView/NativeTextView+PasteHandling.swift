//
//  NativeTextView+PasteHandling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//

import AppKit

extension NativeTextView {
    private static let pastableTextExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text"
    ]

    override func paste(_ sender: Any?) {
        guard isEditable else {
            super.paste(sender)
            return
        }

        let pasteboard = NSPasteboard.general

        if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
            insertBlockEmbed(imageEmbed)
            return
        }

        // Recover HTML tables only when plain text lacks table delimiters —
        // otherwise the source already provided a usable text representation.
        let plain = pasteboard.string(forType: .string)
        let plainHasTableSep = plain.map { $0.contains("|") || $0.contains("\t") } ?? false

        if !plainHasTableSep,
           let html = pasteboard.string(forType: .html),
           html.range(of: "<table", options: .caseInsensitive) != nil,
           let markdownTable = Self.htmlTableToMarkdown(html) {
            insertText(markdownTable, replacementRange: selectedRange())
            return
        }

        if let pasted = plain {
            let sanitized = sanitizePastedText(pasted)
            if !sanitized.isEmpty {
                insertPreservingBlockquote(sanitized)
                return
            }
        }

        if let fileText = textFromPastedFileURL(pasteboard: pasteboard) {
            let sanitized = sanitizePastedText(fileText)
            if !sanitized.isEmpty {
                insertPreservingBlockquote(sanitized)
                return
            }
        }

        pasteAsPlainText(sender)
    }

    /// Insert pasted text, extending the `>` prefix to every line when the
    /// caret sits on a blockquote line — so a multi-line paste stays quoted
    /// instead of only its first line landing after the existing marker.
    private func insertPreservingBlockquote(_ text: String) {
        let sel = selectedRange()
        let prepared = MarkdownLists.blockquoteContinuedPaste(text, at: sel.location, in: string)
        insertText(prepared, replacementRange: sel)
    }

    private func insertBlockEmbed(_ embed: String) {
        let sel = selectedRange()
        let nsText = string as NSString
        var prefix = ""
        var suffix = ""
        if sel.location > 0, nsText.character(at: sel.location - 1) != 0x0A {
            prefix = "\n"
        }
        let afterLocation = sel.location + sel.length
        if afterLocation < nsText.length, nsText.character(at: afterLocation) != 0x0A {
            suffix = "\n"
        }
        insertText(prefix + embed + suffix, replacementRange: sel)
    }

    /// Reads the textual content of a pasted markdown/text file URL — the
    /// fallback that makes iOS Universal Clipboard pastes useful.
    private func textFromPastedFileURL(pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for url in urls where url.isFileURL {
            guard Self.pastableTextExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            if let s = try? String(contentsOf: url) { return s }
        }
        return nil
    }

    private func sanitizePastedText(_ s: String) -> String {
        var out = s
        // Normalize pasted bullet glyphs (• ‣ ◦ ·) at line start to Markdown '- ' lists.
        if let bulletRegex = try? NSRegularExpression(pattern: #"^([ \t]*)[•‣◦·][ \t]+"#, options: [.anchorsMatchLines]) {
            let nsRange = NSRange(location: 0, length: (out as NSString).length)
            out = bulletRegex.stringByReplacingMatches(in: out, range: nsRange, withTemplate: "$1- ")
        }
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}") {
            let nsRange = NSRange(location: 0, length: (out as NSString).length)
            out = regex.stringByReplacingMatches(in: out, range: nsRange, withTemplate: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pasteboard = NSPasteboard.general
            if PasteboardImageReader.canPasteImage(from: pasteboard) { return true }
            if textFromPastedFileURL(pasteboard: pasteboard) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - HTML table → Markdown table

    private static let trRegex = try! NSRegularExpression(
        pattern: #"<tr\b[^>]*>(.*?)</tr>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let cellRegex = try! NSRegularExpression(
        pattern: #"<t[hd]\b[^>]*>(.*?)</t[hd]>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let tagStripRegex = try! NSRegularExpression(
        pattern: #"<[^>]+>"#
    )

    /// First `<table>` in `html` → CommonMark pipe-table; nil if no table.
    static func htmlTableToMarkdown(_ html: String) -> String? {
        guard html.range(of: "<table", options: .caseInsensitive) != nil else { return nil }
        let nsHtml = html as NSString
        let trMatches = trRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
        guard !trMatches.isEmpty else { return nil }

        var rows: [[String]] = []
        for trMatch in trMatches {
            let trContent = nsHtml.substring(with: trMatch.range(at: 1))
            let nsTr = trContent as NSString
            let cellMatches = cellRegex.matches(in: trContent, range: NSRange(location: 0, length: nsTr.length))
            var cells: [String] = []
            for cellMatch in cellMatches {
                let raw = nsTr.substring(with: cellMatch.range(at: 1))
                let nsRaw = raw as NSString
                let stripped = tagStripRegex.stringByReplacingMatches(
                    in: raw, range: NSRange(location: 0, length: nsRaw.length), withTemplate: ""
                )
                let decoded = decodeHTMLEntities(stripped)
                    .replacingOccurrences(of: "|", with: #"\|"#)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(decoded)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return nil }

        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return nil }
        func pad(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }

        var lines: [String] = []
        lines.append("| " + pad(rows[0]).joined(separator: " | ") + " |")
        lines.append("|" + Array(repeating: "---", count: columnCount).joined(separator: "|") + "|")
        for row in rows.dropFirst() {
            lines.append("| " + pad(row).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
