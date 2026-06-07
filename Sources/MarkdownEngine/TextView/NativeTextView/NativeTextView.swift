//
//  NativeTextView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//
//  AppKit `NSTextView` subclass used by the markdown editor. Stored state
//  lives here; behavior is split across `NativeTextView+<Feature>.swift`
//  files in this folder (frame & overscroll, caret workarounds, click remap,
//  paste handling, drag-select boost, task checkbox, spelling policy).
//
//  Bottom-overscroll math lives in `BottomOverscrollPolicy.swift`.
//  Pasteboard image inspection lives in `PasteboardImageReader.swift`.
//

import AppKit
import UniformTypeIdentifiers

final class NativeTextView: NSTextView {
    // MARK: Frame & overscroll state
    var baseContentHeight: CGFloat = 0
    var activeBottomOverscroll: CGFloat = 0
    var isApplyingManagedFrameSize = false
    /// Set on switch/resize to force full-layout height measurement until the cascade settles.
    var pendingFullLayoutMeasure = false
    var suppressAutoRevealOnce: Bool = false

    // MARK: Configuration
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            overscrollPercent = configuration.overscroll.percent
            maxOverscrollPoints = configuration.overscroll.maxPoints
            minOverscrollPoints = configuration.overscroll.minPoints
        }
    }
    var overscrollPercent: CGFloat = MarkdownEditorConfiguration.default.overscroll.percent
    var maxOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.maxPoints
    var minOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.minPoints

    // MARK: Top header reservation
    /// The measured text content height *excluding* the header reservation. Cached
    /// by `measuredBaseContentHeight` so that changing `topContentInset` is a cheap,
    /// consistent recompute (`baseContentHeight = textOnlyContentHeight + inset`)
    /// rather than a second, divergent accounting of the content height.
    var textOnlyContentHeight: CGFloat = 0

    /// Empty space reserved at the very top of the content for an embedder-supplied
    /// header view (see ``NativeTextViewWrapper`` `header:`). The text is shifted
    /// down by this amount via `textContainerOrigin` and the measured content height
    /// grows to match, so a header subview placed in `[0, topContentInset]` lives
    /// inside the text view's bounds — hit-tested normally — and scrolls with the
    /// body. Driven internally by the wrapper from the header's intrinsic height.
    var topContentInset: CGFloat = 0 {
        didSet {
            guard abs(topContentInset - oldValue) > 0.01 else { return }
            // Single source of truth, identical to `measuredBaseContentHeight`:
            // total content height = text height + reserved header. Cheap — no
            // TextKit re-measure — and never double-counts or fights the scroller.
            baseContentHeight = textOnlyContentHeight + topContentInset
            applyManagedFrameSize(width: frame.size.width)
            // Clamp only when the header isn't animating: clamping on every tick
            // re-anchors the scroller and can yank the body. The animation clamps
            // once at settle.
            if (delegate as? NativeTextViewCoordinator)?.headerAnimTimer == nil {
                (enclosingScrollView as? ClampedScrollView)?.clampToInsets()
            }
            needsDisplay = true
        }
    }

    /// Shift all text down by `topContentInset` so the reserved header region at the
    /// top stays empty. The engine already routes every click / cursor-rect
    /// conversion through `textContainerOrigin`, so this offset is honored
    /// consistently across drawing, hit-mapping, and caret math.
    override var textContainerOrigin: NSPoint {
        let base = super.textContainerOrigin
        return NSPoint(x: base.x, y: base.y + topContentInset)
    }

    // MARK: Editor wiring
    var onPasteImage: ((NSPasteboard) -> String?)?
    weak var layoutBridge: LayoutBridge?
    var baseFont: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    // MARK: Caret-workaround state
    var caretIndicatorObservation: NSKeyValueObservation?
    weak var observedCaretIndicator: NSView?
    var isApplyingCaretShift: Bool = false

    // MARK: Drag-select state
    var dragStartMouseScreenLoc: NSPoint?

    // MARK: Wide-table overlay state
    /// Live NSScrollView per wide table; keyed by source-ID hash.
    var wideTableOverlays: [Int: WideTableOverlay] = [:]
    /// Persisted horizontal scroll offset per wide table; survives restyles.
    var tableHorizontalScrollOffsets: [Int: CGFloat] = [:]

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Forward appearance changes to the embedder's highlighter via its registered notification.
        if let name = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            NotificationCenter.default.post(name: name, object: self)
        }
    }

    // setMarkedText skips textDidChange, so restyle the marked paragraph to apply markdown attrs.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        guard hasMarkedText(),
              let coord = delegate as? NativeTextViewCoordinator else { return }
        let marked = markedRange()
        guard marked.location != NSNotFound, marked.length > 0 else { return }
        let nsText = self.string as NSString
        let paragraph = nsText.paragraphRange(for: marked)
        coord.restyleParagraphs([paragraph], in: self)
    }

    deinit { caretIndicatorObservation?.invalidate() }
}
