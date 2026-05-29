//
//  HeadingBoldFixTests.swift
//  MarkdownEngineTests
//
//  Targeted fix (live styler): bold runs inside a heading must keep the heading
//  size instead of shrinking to base size. Regression test for `# **n*o*des**`.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Targeted fix — bold inside a heading stays heading-size")
struct HeadingBoldFixTests {

    private func font(in attrs: [StyledRange], at pos: Int) -> NSFont? {
        var result: NSFont?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let f = a[.font] as? NSFont { result = f }
        }
        return result
    }

    @Test("# **n*o*des** — bold runs are heading-size and consistent")
    func boldInHeadingHeadingSize() {
        _ = NSApplication.shared
        let name = NSFont.systemFont(ofSize: 14).fontName
        let attrs = MarkdownStyler.styleAttributes(
            text: "# **n*o*des**", fontName: name, fontSize: 14,
            caretLocation: -1, activeTokenIndices: [], configuration: .default
        )
        // n=4 (bold), o=6 (bold+italic), d=8 (bold)
        let n = font(in: attrs, at: 4)
        let o = font(in: attrs, at: 6)
        let d = font(in: attrs, at: 8)
        #expect((n?.pointSize ?? 0) > 14)          // heading-size, not base 14
        #expect(n?.pointSize == o?.pointSize)       // the fix: all the same size
        #expect(n?.pointSize == d?.pointSize)
        #expect(n?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }
}
