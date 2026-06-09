//
//  NativeTextViewContainer.swift
//  MarkdownEngine
//
//  Document view of the editor's scroll view. Stacks the scroll-away header and the
//  `NativeTextView` as SIBLINGS with disjoint frames, so body text can never composite
//  over the header. The previous design hosted the header as a SUBVIEW of the text view
//  (reserving space via a `textContainerOrigin` shift); during a responsive-scroll blit
//  the cached body bitmap and the header's own `NSHostingView` layer advanced against
//  slightly different origins, so the body drifted up over the collapsed tags row. No
//  compositing fix could unify them (NSHostingView always forces its own layer), so the
//  header is now a sibling: the body and header occupy disjoint rectangles in this
//  container and overlap is geometrically impossible.
//

import AppKit

final class NativeTextViewContainer: NSView {
    /// The body. Sizes its OWN height (content + overscroll); the container only moves
    /// it below the header band and sizes itself to the sum.
    weak var textView: NativeTextView?

    /// Reserved header band height (mirrors the clip's resolved height). Sole driver of
    /// the vertical stack: the text view sits at `y = headerHeight`.
    var headerHeight: CGFloat = 0 {
        didSet {
            guard abs(headerHeight - oldValue) > 0.01 else { return }
            restack(propagateWidth: false)
        }
    }

    private var isRestacking = false

    /// Flipped (top-left origin) to match `NSTextView`, so `y = headerHeight` means
    /// "below the header" and the text view's local space is a pure translation of the
    /// container's. A non-flipped container would invert the stack and break every
    /// `convert(_:to:)`-based coordinate path.
    override var isFlipped: Bool { true }

    /// Real scrollable height = header band + the text view's real content (no
    /// min-viewport inflation), so the scroll view can't scroll past actual content.
    var scrollableContentHeight: CGFloat {
        headerHeight + (textView?.scrollableContentHeight ?? 0)
    }

    /// Single layout method. Moves the text view below the header (ORIGIN only — never
    /// `setFrameSize`, so the text view's self-measure isn't re-triggered) and sizes the
    /// container to `headerHeight + textViewHeight` (min the viewport). The header clip
    /// is positioned by its own Auto Layout against this container, so it isn't touched.
    func restack(propagateWidth: Bool) {
        guard !isRestacking, let textView else { return }
        isRestacking = true
        defer { isRestacking = false }

        let w = bounds.width
        // Width propagation happens ONLY from the scroll-view-driven path; a height-only
        // restack must never resize the text view (that would re-measure → loop).
        if propagateWidth, abs(textView.frame.width - w) > 0.5 {
            textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
        }
        if abs(textView.frame.origin.y - headerHeight) > 0.01 || abs(textView.frame.origin.x) > 0.01 {
            textView.setFrameOrigin(NSPoint(x: 0, y: headerHeight))
        }
        let viewportH = enclosingScrollView?.contentView.bounds.height ?? 0
        let totalH = max(headerHeight + textView.frame.height, viewportH)
        if abs(frame.height - totalH) > 0.5 {
            setFrameSize(NSSize(width: w, height: totalH))
        }
    }

    /// The text view calls this after it self-resizes its height.
    func textViewDidResize() {
        guard !isRestacking else { return }
        restack(propagateWidth: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width came from the scroll view's clip view (autoresizing); propagate it.
        restack(propagateWidth: true)
    }
}
