//
//  MarkdownStyler+TextStyling.swift
//  MarkdownEngine
//
//  Heading and emphasis (bold / italic / bold+italic) attribute generation.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Headings

    static func styleHeadings(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let headingTokens = ctx.tokens.filter { $0.kind == .heading }
        for token in headingTokens {
            let level = token.markerRanges.first?.length ?? 1
            let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
            let fontSize = ctx.baseFont.pointSize * multiplier
            let headingBase = NSFont(name: ctx.fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            let headingFont = NSFontManager.shared.convert(headingBase, toHaveTrait: .boldFontMask)

            let paraRange = ctx.nsText.paragraphRange(for: token.range)
            let headingLineHeight = ceil(layoutBridgeDefaultLineHeight(for: headingFont, using: ctx.layoutBridge)) + 1
            let headingPara = NSMutableParagraphStyle()
            headingPara.minimumLineHeight = headingLineHeight
            headingPara.maximumLineHeight = headingLineHeight
            let beforeEm = ctx.configuration.headings.topSpacingEm(for: level)
            headingPara.paragraphSpacingBefore = headingFont.pointSize * beforeEm
            headingPara.paragraphSpacing = ctx.baseParagraphSpacing
            attrs.append((paraRange, [.paragraphStyle: headingPara]))

            for markerRange in token.markerRanges {
                attrs.append((markerRange, [
                    .font: headingFont,
                    .foregroundColor: ctx.configuration.theme.headingMarker
                ]))
            }
            attrs.append((token.contentRange, [.font: headingFont]))
        }
        return attrs
    }

    // MARK: Setext Headings

    static func styleSetextHeadings(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .setextHeading {
            guard let underline = token.markerRanges.first else { continue }
            // `=` underline → level 1, `-` underline → level 2.
            let firstChar = ctx.nsText.substring(with: NSRange(location: underline.location, length: 1))
            let level = firstChar == "=" ? 1 : 2

            let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
            let fontSize = ctx.baseFont.pointSize * multiplier
            let headingBase = NSFont(name: ctx.fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            let headingFont = NSFontManager.shared.convert(headingBase, toHaveTrait: .boldFontMask)

            // Heading look on the text line.
            let textParaRange = ctx.nsText.paragraphRange(for: token.contentRange)
            let headingLineHeight = ceil(layoutBridgeDefaultLineHeight(for: headingFont, using: ctx.layoutBridge)) + 1
            let headingPara = NSMutableParagraphStyle()
            headingPara.minimumLineHeight = headingLineHeight
            headingPara.maximumLineHeight = headingLineHeight
            headingPara.paragraphSpacingBefore = headingFont.pointSize * ctx.configuration.headings.topSpacingEm(for: level)
            headingPara.paragraphSpacing = 0
            attrs.append((textParaRange, [.paragraphStyle: headingPara]))
            attrs.append((token.contentRange, [.font: headingFont]))

            // The underline line: revealed (muted) while editing, otherwise
            // collapsed to a near-invisible sliver so it reads as one
            // heading. shrinkInactiveMarkers also shrinks the marker run.
            let isActive = ctx.activeTokenIndices.contains(idx)
            let underlineParaRange = ctx.nsText.paragraphRange(for: underline)
            if isActive {
                attrs.append((underlineParaRange, [.foregroundColor: ctx.configuration.theme.headingMarker]))
            } else {
                let collapsed = NSMutableParagraphStyle()
                collapsed.minimumLineHeight = 1
                collapsed.maximumLineHeight = 1
                collapsed.paragraphSpacing = 0
                collapsed.paragraphSpacingBefore = 0
                attrs.append((underlineParaRange, [
                    .foregroundColor: NSColor.clear,
                    .font: ctx.inlineMarkerFont,
                    .paragraphStyle: collapsed
                ]))
            }
        }
        return attrs
    }

    // MARK: Bold / Italic / Bold+Italic

    static func styleEmphasis(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []

        // We want emphasis to apply when a span CONTAINS inline code
        // (e.g. `~~strike with `code`~~`), so the legacy "overlap with any
        // code/inline-code token" suppression is too aggressive. Skip a
        // span only when it's fully contained inside a code token —
        // i.e. fenced code blocks or `…` spans whose range completely
        // encloses the emphasis.
        func isFullyInsideAnyCode(_ range: NSRange) -> Bool {
            for codeToken in ctx.codeTokens {
                if range.location >= codeToken.range.location
                    && NSMaxRange(range) <= NSMaxRange(codeToken.range) {
                    return true
                }
            }
            return false
        }

        // True iff `inner` is fully contained in some bold/boldItalic span.
        // Used to compose italic-inside-bold into a bold-italic glyph
        // rather than letting italic clobber the bold trait.
        func isInsideBoldSpan(_ inner: NSRange) -> Bool {
            for token in ctx.tokens where token.kind == .bold || token.kind == .boldItalic {
                if inner.location >= token.range.location
                    && NSMaxRange(inner) <= NSMaxRange(token.range) {
                    return true
                }
            }
            return false
        }

        // Bold+Italic
        for token in ctx.tokens where token.kind == .boldItalic {
            if isFullyInsideAnyCode(token.range) { continue }
            let biDescriptor = ctx.baseDescriptor.withSymbolicTraits([.bold, .italic])
            let biFont = NSFont(descriptor: biDescriptor, size: ctx.baseFont.pointSize)
                ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: [.boldFontMask, .italicFontMask])
            attrs.append((token.contentRange, [.font: biFont]))
        }

        // Bold
        for token in ctx.tokens where token.kind == .bold {
            if isFullyInsideAnyCode(token.range) { continue }
            let boldDesc = ctx.baseDescriptor.withSymbolicTraits(.bold)
            let boldFont = NSFont(descriptor: boldDesc, size: ctx.baseFont.pointSize)
                ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .boldFontMask)
            attrs.append((token.contentRange, [.font: boldFont]))
        }

        // Strikethrough ~~text~~
        for token in ctx.tokens where token.kind == .strikethrough {
            if isFullyInsideAnyCode(token.range) { continue }
            attrs.append((token.contentRange, [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: ctx.configuration.theme.strikethroughColor
            ]))
        }

        // Italic
        for token in ctx.tokens where token.kind == .italic {
            if isFullyInsideAnyCode(token.range) { continue }
            let composeWithBold = isInsideBoldSpan(token.range)
            if let headingToken = ctx.tokens.first(where: { $0.kind == .heading && NSLocationInRange(token.contentRange.location, $0.contentRange) }) {
                let level = headingToken.markerRanges.first?.length ?? 1
                let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
                let headingBase = NSFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
                    ?? NSFont.systemFont(ofSize: ctx.baseFont.pointSize * multiplier)
                let traits: NSFontDescriptor.SymbolicTraits = [.bold, .italic]
                let descriptor = headingBase.fontDescriptor.withSymbolicTraits(traits)
                let fontIt = NSFont(descriptor: descriptor, size: headingBase.pointSize)
                    ?? NSFontManager.shared.convert(headingBase, toHaveTrait: [.boldFontMask, .italicFontMask])
                attrs.append((token.contentRange, [.font: fontIt]))
            } else if composeWithBold {
                let descriptor = ctx.baseDescriptor.withSymbolicTraits([.bold, .italic])
                let font = NSFont(descriptor: descriptor, size: ctx.baseFont.pointSize)
                    ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: [.boldFontMask, .italicFontMask])
                attrs.append((token.contentRange, [.font: font]))
            } else {
                let italicDesc = ctx.baseDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: ctx.baseFont.pointSize)
                    ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .italicFontMask)
                attrs.append((token.contentRange, [.font: italicFont]))
            }
        }

        return attrs
    }
}
