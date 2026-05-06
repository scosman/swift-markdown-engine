//
//  MarkdownTextLayoutFragment.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.04.26.
//
//  TextKit 2 replacement for CodeBlockLayoutManager.
//  Draws code-block backgrounds, LaTeX images, and task checkboxes
//  via NSTextLayoutFragment instead of NSLayoutManager glyph overrides.

import AppKit

// MARK: - Custom attribute keys for rendering overlays

extension NSAttributedString.Key {
    static let latexImage = NSAttributedString.Key("LatexRenderedImage")
    static let latexBounds = NSAttributedString.Key("LatexImageBounds")
    static let latexIsBlock = NSAttributedString.Key("LatexIsBlock")
    static let latexBlockOffsetY = NSAttributedString.Key("LatexBlockOffsetY")
}

final class MarkdownTextLayoutFragment: NSTextLayoutFragment {

    // MARK: - Rendering surface

    /// Extend rendering bounds for code-block backgrounds (full container width)
    /// and block images drawn below text via paragraphSpacing.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if hasCodeBlockBackground {
            let containerWidth = textLayoutManager?.textContainer?.size.width ?? bounds.width
            // Extend left to container edge
            bounds.origin.x = -layoutFragmentFrame.origin.x
            bounds.size.width = containerWidth
        }
        // Extend bounds to cover block images that render below the text line
        // (visibleSource mode uses paragraphSpacing to create space for the image).
        for rect in blockImageRects(at: .zero) {
            bounds = bounds.union(rect)
        }
        return bounds
    }

    // MARK: - Drawing

    override func draw(at point: CGPoint, in context: CGContext) {
        // 1. Code-block backgrounds (behind text)
        drawCodeBlockBackground(at: point, in: context)

        // 2. LaTeX images (behind text — hidden markers are invisible anyway)
        drawLatexImages(at: point, in: context)

        // 3. Normal text
        super.draw(at: point, in: context)

        // 4. Task checkboxes (on top of hidden [ ]/[x] markers)
        drawTaskCheckboxes(at: point, in: context)
    }

    // MARK: - Helpers

    /// NSRange in the document for this fragment's content.
    private var fragmentNSRange: NSRange? {
        guard let tcs = textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        let start = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.endLocation)
        guard start != NSNotFound, end != NSNotFound, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private var textStorage: NSTextStorage? {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    /// Returns the drawing position for a character at `docIndex` (document-level NSRange location).
    /// `point` is the draw origin passed to `draw(at:in:)`.
    private func drawPosition(forDocumentCharAt docIndex: Int, point: CGPoint) -> (x: CGFloat, baselineY: CGFloat, lineHeight: CGFloat)? {
        guard let fragRange = fragmentNSRange else { return nil }
        let localIndex = docIndex - fragRange.location
        guard localIndex >= 0 else { return nil }

        var lineY: CGFloat = 0
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            if localIndex >= lr.location && localIndex < lr.location + lr.length {
                let charPos = lineFragment.locationForCharacter(at: localIndex)
                let tb = lineFragment.typographicBounds
                return (
                    x: point.x + tb.origin.x + charPos.x,
                    baselineY: point.y + lineY + charPos.y,
                    lineHeight: tb.height
                )
            }
            lineY += lineFragment.typographicBounds.height
        }
        return nil
    }

    /// Typographic bounds of the line fragment containing `localIndex`
    /// (index relative to the fragment, not the document).
    private func lineBounds(forLocalIndex localIndex: Int, point: CGPoint) -> CGRect? {
        var lineY: CGFloat = 0
        for lineFragment in textLineFragments {
            let lr = lineFragment.characterRange
            if localIndex >= lr.location && localIndex < lr.location + lr.length {
                let tb = lineFragment.typographicBounds
                return CGRect(x: point.x + lineFragment.glyphOrigin.x + tb.origin.x,
                              y: point.y + lineY + tb.origin.y,
                              width: tb.width,
                              height: tb.height)
            }
            lineY += lineFragment.typographicBounds.height
        }
        return nil
    }

    // MARK: - Code Block Background

    private var hasCodeBlockBackground: Bool {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return false }
        let bgColor = ts.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        guard let bgColor else { return false }
        return isCodeBlockBackgroundColor(bgColor)
    }

    private func drawCodeBlockBackground(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }

        // Only fill the full-width band when the FIRST char of the fragment
        // already carries the code background. A previous version scanned
        // the whole fragment for any matching char, which incorrectly fired
        // on regular paragraphs that just happen to contain inline `code`
        // (the styler reuses the same background colour for both fenced
        // blocks and inline code spans).
        guard let firstColor = ts.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor,
              isCodeBlockBackgroundColor(firstColor) else { return }
        let color = firstColor

        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width

        var effectiveHeight = layoutFragmentFrame.height
        if textLineFragments.count > 1,
           let lastLF = textLineFragments.last,
           lastLF.characterRange.length == 0 {
            effectiveHeight -= lastLF.typographicBounds.height
        }

        let scale = textLayoutManager?.textContainer?.textView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let rawY = point.y
        let rawMaxY = point.y + effectiveHeight
        let snappedY = floor(rawY * scale) / scale
        let snappedMaxY = ceil(rawMaxY * scale) / scale

        // Draw full-width background
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        color.setFill()
        let bgRect = CGRect(
            x: point.x - layoutFragmentFrame.origin.x,
            y: snappedY,
            width: containerWidth,
            height: snappedMaxY - snappedY
        )
        NSBezierPath(rect: bgRect).fill()
    }

    private func isCodeBlockBackgroundColor(_ color: NSColor) -> Bool {
        let highlighter = (textLayoutManager?.textContainer?.textView as? NativeTextView)?
            .configuration.services.syntaxHighlighter
            ?? PlainTextSyntaxHighlighter()
        let currentBg = highlighter.backgroundColor()
        guard let colorRGB = color.usingColorSpace(.deviceRGB),
              let currentBgRGB = currentBg.usingColorSpace(.deviceRGB) else { return false }
        let tolerance: CGFloat = 0.03
        return abs(colorRGB.redComponent - currentBgRGB.redComponent) < tolerance &&
               abs(colorRGB.greenComponent - currentBgRGB.greenComponent) < tolerance &&
               abs(colorRGB.blueComponent - currentBgRGB.blueComponent) < tolerance
    }

    // MARK: - LaTeX / Block Image Helpers

    /// Compute the draw rect for a block image at `attrRange` using `point` as
    /// the draw origin.  Shared by `drawLatexImages` and `blockImageRects` so
    /// bounds and rendering stay in sync.
    private func blockImageDrawRect(
        attrRange: NSRange,
        imageBounds: CGRect,
        blockOffsetY: CGFloat?,
        point: CGPoint
    ) -> CGRect? {
        guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return nil }
        let fragLocation = fragmentNSRange?.location ?? 0
        let localStart = attrRange.location - fragLocation
        let localLast = max(localStart, localStart + attrRange.length - 1)
        let firstLb = lineBounds(forLocalIndex: localStart, point: point)
        // For a wrapped source span (e.g. a long `![alt](url)` that wraps in
        // a narrow window), anchor to the LAST line's maxY so the image
        // doesn't paint over subsequent wrapped lines of its own source.
        let lastLb = lineBounds(forLocalIndex: localLast, point: point) ?? firstLb
        let lineHeight = firstLb?.height ?? pos.lineHeight
        let firstLineMinY = firstLb?.origin.y ?? (pos.baselineY - lineHeight)
        let lastLineMaxY = (lastLb?.origin.y ?? firstLineMinY) + (lastLb?.height ?? lineHeight)

        let yPosition: CGFloat
        if let blockOffsetY {
            // Backward-compatible interpretation: `blockOffsetY` is the gap
            // from the FIRST line's top to the image's top (= baseLineHeight
            // + imageGap on a single-line source). Re-anchor to the last
            // line by subtracting one line height, leaving the same single-
            // line geometry intact while pushing the image down by one
            // extra line per wrap.
            yPosition = lastLineMaxY + blockOffsetY - lineHeight
        } else {
            yPosition = firstLineMinY + (lineHeight - imageBounds.height) / 2
        }
        return CGRect(x: pos.x, y: yPosition,
                       width: imageBounds.width, height: imageBounds.height)
    }

    /// Returns the rects of all block images in this fragment, relative to
    /// `point`.  Used by `renderingSurfaceBounds` (with `.zero`) to extend
    /// the surface so images drawn in paragraphSpacing aren't clipped.
    private func blockImageRects(at point: CGPoint) -> [CGRect] {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return [] }
        var rects: [CGRect] = []
        ts.enumerateAttribute(.latexImage, in: range, options: []) { value, attrRange, _ in
            guard value is NSImage else { return }
            let isBlock = ts.attribute(.latexIsBlock, at: attrRange.location, effectiveRange: nil) as? Bool ?? false
            guard isBlock else { return }
            let boundsVal = ts.attribute(.latexBounds, at: attrRange.location, effectiveRange: nil) as? NSValue
            let imageBounds = boundsVal?.rectValue ?? .zero
            let blockOffsetY = ts.attribute(.latexBlockOffsetY, at: attrRange.location, effectiveRange: nil) as? CGFloat
            if let rect = blockImageDrawRect(attrRange: attrRange, imageBounds: imageBounds, blockOffsetY: blockOffsetY, point: point) {
                rects.append(rect)
            }
        }
        return rects
    }

    // MARK: - LaTeX Images

    private func drawLatexImages(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        ts.enumerateAttribute(.latexImage, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, let image = value as? NSImage else { return }

            let boundsVal = ts.attribute(.latexBounds, at: attrRange.location, effectiveRange: nil) as? NSValue
            let imageBounds = boundsVal?.rectValue ?? CGRect(origin: .zero, size: image.size)
            let isBlock = ts.attribute(.latexIsBlock, at: attrRange.location, effectiveRange: nil) as? Bool ?? false
            let blockOffsetY = ts.attribute(.latexBlockOffsetY, at: attrRange.location, effectiveRange: nil) as? CGFloat

            guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let drawRect: CGRect
            if isBlock {
                guard let rect = blockImageDrawRect(attrRange: attrRange, imageBounds: imageBounds, blockOffsetY: blockOffsetY, point: point) else { return }
                drawRect = rect
            } else {
                let descent = imageBounds.origin.y
                drawRect = CGRect(x: pos.x,
                                  y: pos.baselineY + descent - imageBounds.height,
                                  width: imageBounds.width, height: imageBounds.height)
            }
            image.draw(in: drawRect)
        }
    }

    // MARK: - Task List Checkboxes

    private func drawTaskCheckboxes(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        let selectionRanges: [NSRange] = {
            guard let tv = textLayoutManager?.textContainer?.textView else { return [] }
            return tv.selectedRanges.map { $0.rangeValue }.filter { $0.length > 0 }
        }()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext

        ts.enumerateAttribute(.taskCheckbox, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, value != nil else { return }
            if selectionRanges.contains(where: { NSIntersectionRange($0, attrRange).length > 0 }) { return }

            let isChecked = (value as? Bool) ?? false
            guard let pos = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }

            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? NSFont)
                ?? (textLayoutManager?.textContainer?.textView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            let ascent = max(0, font.ascender)
            let descent = max(0, -font.descender)
            let fontHeight = max(1, ceil(ascent + descent))
            let markerWidth = ("[ ]" as NSString).size(withAttributes: [.font: font]).width
            let size = max(1.0, min(floor(fontHeight * 1.2), floor(markerWidth * 1.2)))
            let boxX = pos.x + max(0, (markerWidth - size) / 2)
            let centerY = pos.baselineY + (descent - ascent) / 2
            let boxY = centerY - size / 2

            let scale = textLayoutManager?.textContainer?.textView?.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            func alignToPixel(_ value: CGFloat) -> CGFloat {
                (value * scale).rounded(.toNearestOrAwayFromZero) / scale
            }
            let boxRect = CGRect(x: alignToPixel(boxX), y: alignToPixel(boxY), width: size, height: size)
            guard !boxRect.isEmpty, !boxRect.isNull else { return }

            let iconInset = max(0.0, size * 0.01)
            let iconRect = boxRect.insetBy(dx: iconInset, dy: iconInset)
            let symbolName = isChecked ? "checkmark.square.fill" : "square"
            if let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let sizeConfig = NSImage.SymbolConfiguration(pointSize: iconRect.height, weight: .regular)
                let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?.configuration.theme ?? .default
                let tint = isChecked ? theme.bodyText : theme.mutedText
                let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: tint)
                let symbolConfig = sizeConfig.applying(colorConfig)
                let symbol = baseSymbol.withSymbolConfiguration(symbolConfig) ?? baseSymbol
                symbol.draw(in: iconRect)
            }
        }
    }
}

// MARK: - Layout Manager Delegate

final class MarkdownLayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        MarkdownTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
