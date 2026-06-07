//
//  NativeTextViewWrapper.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Brings the editor into SwiftUI and wires up the text view with the
// right setup, styling, and callbacks.
//
// Public selection / replacement value types live in
// `NativeTextViewSelectionTypes.swift`.
import SwiftUI
import AppKit

/// SwiftUI bridge for MarkdownEngine's AppKit-backed editor.
///
/// Wraps a TextKit 2 `NSTextView` inside an `NSScrollView` and exposes a
/// SwiftUI-friendly API of bindings (text, link state, replacement requests)
/// and callback closures (link clicks, caret movement, inline-selection and
/// code-block change notifications). All visual styling and external
/// dependencies are routed through ``MarkdownEditorConfiguration``.
public struct NativeTextViewWrapper: NSViewRepresentable {
    public typealias Coordinator = NativeTextViewCoordinator
    public typealias NSViewType = NSScrollView

    /// Two-way binding to the document text in storage form
    /// (`[[Name|<id>]]` for wiki-links). The engine keeps display and
    /// storage forms in sync internally.
    @Binding public var text: String
    /// Becomes `true` while the caret is inside a `[[Name]]` link's content
    /// range, so embedders can show a contextual UI (e.g. a popover).
    @Binding public var isWikiLinkActive: Bool
    /// Push a replacement into the editor by setting this to a non-nil value;
    /// the engine applies it on the next update and then clears the binding.
    @Binding public var pendingInlineReplacement: InlineReplacementRequest?
    /// The full editor configuration (theme + services + style toggles). Engine
    /// embedders construct this themselves and pass it in; the wrapper does
    /// not read UserDefaults or know about app-specific colors/services.
    public var configuration: MarkdownEditorConfiguration
    /// PostScript name of the base font used for body text.
    public var fontName: String
    /// Base font size in points. Headings, code blocks, and LaTeX are scaled
    /// off this value via ``MarkdownEditorConfiguration``.
    public var fontSize: CGFloat
    /// Opaque document identifier. Changing this invalidates undo history
    /// and resets per-document editor state. Set a stable, unique value
    /// per document when displaying multiple editors so pending
    /// replacements and undo stay scoped to each editor.
    public var documentId: String
    /// When `false` the editor renders read-only with no caret.
    public var isEditable: Bool
    /// Optional paste hook. Return a Markdown image-embed string (e.g.
    /// `"![[my-image]]"`) to insert at the caret, or `nil` to fall through
    /// to the system's default plain-text paste.
    public var onPasteImage: ((NSPasteboard) -> String?)?

    /// Fires when the user clicks a `[[Name]]` link. The argument is the
    /// resolved opaque identifier (or the display name when no resolver
    /// was supplied).
    public var onLinkClick: ((String) -> Void)?
    /// Fires whenever the caret rect inside an active wiki-link changes,
    /// so embedders can position a follow-the-caret UI.
    public var onCaretRectChange: ((CGRect) -> Void)?
    /// Fires when the caret enters or leaves a `[[Name]]` or `![[…]]`
    /// token. `nil` means the caret is no longer inside such a token.
    public var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    /// Fires when the set of visible code blocks changes, so embedders can
    /// overlay copy buttons (see ``CodeBlockButton``).
    public var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    /// Fires after the user toggles any of the three spell/grammar/auto-correction
    /// menu items. Embedders persist the policy and pass it back via
    /// ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    public var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    /// SwiftUI header hosted above the body and scrolling with it. The engine owns
    /// an `NSHostingView`, reserves its (intrinsic) height at the top of the text
    /// content, and refreshes its `rootView` when `documentId` changes. Because the
    /// header lives inside the text view's bounds, it is fully interactive. Inject
    /// any required SwiftUI environment into this content before passing it in.
    public var header: AnyView?
    /// Core (AppKit) alternative to ``header``: a raw NSView hosted in the same
    /// reserved region for non-SwiftUI embedders. The engine sizes/places it but
    /// does not manage its content. Ignored when ``header`` is non-nil.
    public var headerView: NSView?
    /// Visible header height when collapsed — typically just the heading. Content
    /// below this is clipped. The embedder measures and supplies it so the heading
    /// stays fully visible while the lower content reveals/hides.
    public var headerCollapsedHeight: CGFloat
    /// Whether the header is expanded to its full content height or collapsed to
    /// ``headerCollapsedHeight``. Toggling animates the reveal.
    public var headerExpanded: Bool

    public init(
        text: Binding<String>,
        isWikiLinkActive: Binding<Bool> = .constant(false),
        pendingInlineReplacement: Binding<InlineReplacementRequest?> = .constant(nil),
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16,
        documentId: String = "default",
        isEditable: Bool = true,
        onPasteImage: ((NSPasteboard) -> String?)? = nil,
        onLinkClick: ((String) -> Void)? = nil,
        onCaretRectChange: ((CGRect) -> Void)? = nil,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)? = nil,
        onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)? = nil,
        onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)? = nil,
        header: AnyView? = nil,
        headerView: NSView? = nil,
        headerCollapsedHeight: CGFloat = 0,
        headerExpanded: Bool = true
    ) {
        self._text = text
        self._isWikiLinkActive = isWikiLinkActive
        self._pendingInlineReplacement = pendingInlineReplacement
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.onPasteImage = onPasteImage
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = onCaretRectChange
        self.onInlineSelectionChange = onInlineSelectionChange
        self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        self.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        self.header = header
        self.headerView = headerView
        self.headerCollapsedHeight = headerCollapsedHeight
        self.headerExpanded = headerExpanded
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClampedScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = configuration.scrollers.hasVerticalScroller
        scrollView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        scrollView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: configuration.safeAreaInsets.top,
            left: configuration.safeAreaInsets.leading,
            bottom: configuration.safeAreaInsets.bottom,
            right: configuration.safeAreaInsets.trailing
        )

        // Let NSTextView auto-initialize its own TextKit 2 stack via init(frame:).
        let textView = NativeTextView(frame: .zero)

        // Configure the auto-created text container.
        guard let textContainer = textView.textContainer,
              let textLayoutManager = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textView.textContainerInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        textContainer.heightTracksTextView = false

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        context.coordinator.layoutDelegate = layoutDelegate
        textLayoutManager.delegate = layoutDelegate
        textView.configuration = configuration
        textView.overscrollPercent = configuration.overscroll.percent
        textView.maxOverscrollPoints = configuration.overscroll.maxPoints
        textView.minOverscrollPoints = configuration.overscroll.minPoints
        context.coordinator.configuration = configuration
        textView.insertionPointColor = configuration.theme.bodyText
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = true
        let initialState = WikiLinkService.makeDisplayState(from: text)
        textView.string = initialState.display
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = configuration.spellChecking.automaticSpellingCorrection
        textView.isContinuousSpellCheckingEnabled = configuration.spellChecking.continuousSpellChecking
        textView.isGrammarCheckingEnabled = configuration.spellChecking.grammarChecking
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onPasteImage = onPasteImage
        if #available(macOS 15.1, *) {
            textView.writingToolsBehavior = .complete
        }
        // Create TextKit 2 layout bridge
        let bridge = LayoutBridge(textLayoutManager)
        context.coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        scrollView.documentView = textView
        // Force full-document layout at init so paragraph heights are known
        // upfront; otherwise TextKit 2 viewport layout causes scroll drift.
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.clampToInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)

        context.coordinator.textView = textView
        context.coordinator.wikiLinkMetadata = initialState.metadata
        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange

        textView.recalcOverscroll(for: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        var lastObservedViewportWidth = scrollView.contentView.bounds.width
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            // Refresh code-block overlays only on real viewport width changes, not on TextKit height-only echoes during typing.
            let newWidth = scrollView.contentView.bounds.width
            if abs(newWidth - lastObservedViewportWidth) > 0.5 {
                lastObservedViewportWidth = newWidth
                context.coordinator.didEnsureLayoutForCurrentDocument = false
                context.coordinator.updateCodeBlockSelection(textView: textView)
            }
            // Only react with overscroll recalc when the viewport itself resizes
            // (window resize). Without this guard, TextKit-induced textView frame
            // changes echo back here and re-trigger recalcOverscroll, causing a
            // 149pt height oscillation after clicks.
            guard abs(textView.frame.height - scrollView.contentView.bounds.height) > 1 else { return }
            textView.recalcOverscroll(for: scrollView)
            scrollView.clampToInsets()
        }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            (textView as? NativeTextView)?.ensureVisibleLayout()
            if context.coordinator.isWritingToolsActive {
                context.coordinator.fixWritingToolsChildWindowIfNeeded(textView: textView)
            }
            scrollView.clampToInsets()
            context.coordinator.refreshActiveLinkCaretRect()
            context.coordinator.updateCodeBlockSelection(textView: textView)
        }
        reconcileHeader(textView: textView, context: context)
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        reconcileHeader(textView: textView, context: context)

        let isNodeSwitch = context.coordinator.documentId != documentId
        let wtActive: Bool = {
            if #available(macOS 15.0, *), textView.isWritingToolsActive { return true }
            return context.coordinator.isWritingToolsActive
        }()

        if wtActive && isNodeSwitch {
            // User switched files while Writing Tools was active — discard the
            // WT session so it doesn't overwrite the wrong node.
            // Keep wtStartDocumentId so textViewWritingToolsDidEnd can detect the
            // node mismatch and discard the results.
            context.coordinator.isWritingToolsActive = false
        } else if wtActive {
            // WT active on the same node — don't interfere with the session.
            return
        }

        if let bottomTextView = nsView.documentView as? NativeTextView {
            bottomTextView.onPasteImage = onPasteImage
        }
        if nsView.hasVerticalScroller != configuration.scrollers.hasVerticalScroller {
            nsView.hasVerticalScroller = configuration.scrollers.hasVerticalScroller
        }
        if nsView.hasHorizontalScroller != configuration.scrollers.hasHorizontalScroller {
            nsView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        }
        if nsView.autohidesScrollers != configuration.scrollers.autohidesScrollers {
            nsView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        }
        let desiredTextInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        if textView.textContainerInset != desiredTextInset {
            textView.textContainerInset = desiredTextInset
        }
        // Refresh services/theme when the embedder hands us a new configuration
        // (e.g. when the available wiki-link targets change). Cheap pointer-/
        // value-based comparison; full equality isn't required because the
        // embedder is the source of truth.
        let newImageFingerprint = configuration.services.images.fingerprint()
        let newWikiFingerprint = configuration.services.wikiLinks.fingerprint()
        let imageChanged = newImageFingerprint != context.coordinator.lastImageFingerprint
        let wikiChanged = newWikiFingerprint != context.coordinator.lastWikiFingerprint
        if imageChanged || wikiChanged {
            context.coordinator.lastImageFingerprint = newImageFingerprint
            context.coordinator.lastWikiFingerprint = newWikiFingerprint
            context.coordinator.configuration.services = configuration.services
            (nsView.documentView as? NativeTextView)?.configuration.services = configuration.services
            // Only an image change needs a layout re-measure; a wiki-link rename is style-only.
            if imageChanged, let tlm = textView.textLayoutManager {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            // Restyle live tv content — full rebuild would clobber paste-fresh embeds when `text` binding hasn't caught up.
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if fullRange.length > 0 {
                context.coordinator.restyleParagraphs([fullRange], in: textView)
            }
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.insertionPointColor = isEditable ? context.coordinator.configuration.theme.bodyText : .clear
        let fontChanged = (context.coordinator.fontName != fontName) || (context.coordinator.fontSize != fontSize)
        if let pendingInlineReplacement {
            if pendingInlineReplacement.documentId == documentId,
               context.coordinator.lastAppliedInlineReplacementID != pendingInlineReplacement.id {
                context.coordinator.applyInlineReplacement(pendingInlineReplacement, to: textView)
            }
            DispatchQueue.main.async {
                if self.pendingInlineReplacement?.id == pendingInlineReplacement.id {
                    self.pendingInlineReplacement = nil
                }
            }
            return
        }
        if context.coordinator.didInitialFormatting
            && context.coordinator.lastSyncedText == text
            && !fontChanged {
            return
        }
        if fontChanged {
            context.coordinator.didInitialFormatting = false
        }
        if isNodeSwitch {
            context.coordinator.documentId = documentId
            textView.undoManager?.removeAllActions()
            context.coordinator.didInitialFormatting = false
            context.coordinator.didEnsureLayoutForCurrentDocument = false
            context.coordinator.resetImageEmbedState()
            // Drop old document's wide-table overlays synchronously.
            (textView as? NativeTextView)?.removeAllWideTableOverlays()
            // Reset scroll to top of content so the previous file's scrollY
            // doesn't leak into a (potentially shorter) new file.
            nsView.contentView.scroll(to: NSPoint(x: 0, y: -nsView.contentInsets.top))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        if let tv = nsView.documentView as? NativeTextView {
            tv.baseFont = font
            tv.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        // Sync coordinator's font fields BEFORE the rebuild so the helper
        // reads the current values from the View struct.
        context.coordinator.fontName = fontName
        context.coordinator.fontSize = fontSize
        context.coordinator.rebuildTextStorageAndStyle(
            textView,
            from: text,
            invalidateLayout: isNodeSwitch
        )
        if let tv = nsView.documentView as? NativeTextView {
            tv.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }
        DispatchQueue.main.async {
            if let tv = nsView.documentView as? NativeTextView {
                context.coordinator.updateCodeBlockSelection(textView: tv)
            }
        }

        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        context.coordinator.didInitialFormatting = true
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = NativeTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize,
            isWikiLinkActive: $isWikiLinkActive,
            onLinkClick: onLinkClick,
            onInlineSelectionChange: onInlineSelectionChange
        )
        coordinator.documentId = documentId
        coordinator.configuration = configuration
        coordinator.lastImageFingerprint = configuration.services.images.fingerprint()
        coordinator.lastWikiFingerprint = configuration.services.wikiLinks.fingerprint()
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        coordinator.userPrefersContinuousSpellChecking = configuration.spellChecking.continuousSpellChecking
        coordinator.userPrefersGrammarChecking = configuration.spellChecking.grammarChecking
        coordinator.userPrefersAutomaticSpellingCorrection = configuration.spellChecking.automaticSpellingCorrection
        coordinator.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        return coordinator
    }
}

// MARK: - Scrolling header view

private extension NativeTextViewWrapper {
    /// Host the header inside a clip container at the top of the content. The clip
    /// height is the reserved top inset; collapsing animates it between
    /// `headerCollapsedHeight` and the full content height, so the heading stays
    /// fixed while the lower content reveals/hides.
    func reconcileHeader(textView: NSTextView, context: Context) {
        let coord = context.coordinator
        guard let native = textView as? NativeTextView else { return }

        guard header != nil || headerView != nil else {
            if coord.headerClipView != nil { removeHeader(coord: coord, native: native) }
            return
        }

        if coord.headerClipView == nil {
            buildHeader(textView: textView, native: native, coord: coord)
        } else if coord.headerDocumentId != documentId,
                  let h = header,
                  let hv = coord.headerHostingView as? NSHostingView<AnyView> {
            hv.rootView = h
            coord.headerDocumentId = documentId
        }

        applyExpansion(textView: textView, native: native, coord: coord)
    }

    func buildHeader(textView: NSTextView, native: NativeTextView, coord: NativeTextViewCoordinator) {
        let host: NSView
        if let header {
            let h = NSHostingView(rootView: header)
            if #available(macOS 13.0, *) { h.sizingOptions = [.intrinsicContentSize] }
            host = h
        } else if let headerView {
            host = headerView
        } else { return }

        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.clipsToBounds = true
        clip.postsFrameChangedNotifications = true
        textView.addSubview(clip)

        host.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(host)

        // Two height options for the clip; exactly one is active at a time.
        //  • equality: clip.height == host.height  → expanded, tracks content live.
        //  • constant: clip.height == <value>      → collapsed, or animating.
        let equalityC = clip.heightAnchor.constraint(equalTo: host.heightAnchor)
        let constantC = clip.heightAnchor.constraint(equalToConstant: max(0, headerCollapsedHeight))
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: textView.topAnchor),
            clip.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            // Host is full-height (top-pinned); overflow below the clip is hidden.
            host.topAnchor.constraint(equalTo: clip.topAnchor),
            host.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor)
        ])
        if headerExpanded { equalityC.isActive = true } else { constantC.isActive = true }

        coord.headerHostingView = host
        coord.headerClipView = clip
        coord.headerEqualityConstraint = equalityC
        coord.headerConstantConstraint = constantC
        coord.headerDocumentId = documentId
        coord.lastHeaderExpanded = headerExpanded

        // SOLE writer of topContentInset: the clip's height drives the reserved
        // region. Synchronous (queue nil) so the body tracks the header with no lag.
        coord.headerContentObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: nil
        ) { [weak clip, weak native] _ in
            guard let clip, let native else { return }
            let h = clip.frame.height
            guard abs(native.topContentInset - h) > 0.5 else { return }
            native.topContentInset = h
        }

        textView.layoutSubtreeIfNeeded()
        native.topContentInset = clip.frame.height
    }

    func applyExpansion(textView: NSTextView, native: NativeTextView, coord: NativeTextViewCoordinator) {
        guard let equalityC = coord.headerEqualityConstraint,
              let constantC = coord.headerConstantConstraint,
              let clip = coord.headerClipView,
              let host = coord.headerHostingView else { return }
        let collapsed = max(0, headerCollapsedHeight)

        if coord.lastHeaderExpanded != headerExpanded {
            coord.lastHeaderExpanded = headerExpanded
            // Hand the clip height to the animatable constant constraint.
            let start = clip.frame.height
            equalityC.isActive = false
            constantC.constant = start
            constantC.isActive = true
            let target: CGFloat
            if headerExpanded {
                host.invalidateIntrinsicContentSize()
                host.layoutSubtreeIfNeeded()
                target = max(collapsed, host.fittingSize.height)
            } else {
                target = collapsed
            }
            animateHeader(to: target, expandedAfter: headerExpanded,
                          textView: textView, native: native, coord: coord)
        } else if !headerExpanded, coord.headerAnimTimer == nil, constantC.isActive,
                  abs(constantC.constant - collapsed) > 0.5 {
            // Collapsed steady: keep the constant in sync with the heading height.
            constantC.constant = collapsed
            textView.layoutSubtreeIfNeeded()
        }
        // Expanded steady: the equality constraint already tracks the content.
    }

    func animateHeader(to target: CGFloat, expandedAfter: Bool,
                       textView: NSTextView, native: NativeTextView, coord: NativeTextViewCoordinator) {
        guard let constantC = coord.headerConstantConstraint else { return }
        coord.headerAnimTimer?.invalidate()
        let start = constantC.constant

        func settle() {
            coord.headerAnimTimer = nil
            if expandedAfter, let equalityC = coord.headerEqualityConstraint {
                // Hand back to the live-tracking equality constraint.
                constantC.isActive = false
                equalityC.isActive = true
                textView.layoutSubtreeIfNeeded()
            }
            // One clamp once the height has settled (skipped during the animation).
            (textView.enclosingScrollView as? ClampedScrollView)?.clampToInsets()
        }

        guard abs(target - start) > 0.5 else {
            constantC.constant = target
            textView.layoutSubtreeIfNeeded()
            settle()
            return
        }
        let duration: CGFloat = 0.32
        var progress: CGFloat = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak textView, weak coord] t in
            guard let textView, let coord, let constantC = coord.headerConstantConstraint else {
                t.invalidate(); return
            }
            progress = min(1, progress + (1.0 / 60.0) / duration)
            let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
            constantC.constant = start + (target - start) * eased
            textView.layoutSubtreeIfNeeded()   // → clip frame change → clip observer → topContentInset
            if progress >= 1 {
                t.invalidate()
                settle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        coord.headerAnimTimer = timer
    }

    func removeHeader(coord: NativeTextViewCoordinator, native: NativeTextView) {
        coord.headerAnimTimer?.invalidate(); coord.headerAnimTimer = nil
        if let o = coord.headerContentObserver {
            NotificationCenter.default.removeObserver(o); coord.headerContentObserver = nil
        }
        coord.headerClipView?.removeFromSuperview()
        coord.headerClipView = nil
        coord.headerHostingView = nil
        coord.headerEqualityConstraint = nil
        coord.headerConstantConstraint = nil
        coord.headerDocumentId = nil
        coord.lastHeaderExpanded = nil
        native.topContentInset = 0
    }
}
