# Architecture

## Source layout

```bash
Sources/
├── MarkdownEngine/                          # core target — zero deps
│   ├── Configuration/                       # MarkdownEditorConfiguration + MarkdownEditorTheme
│   ├── Services/                            # 4 protocols, no-op defaults, WikiLinkService
│   ├── Parser/                              # MarkdownTokenizer.swift + emphasis stack parser
│   ├── Styling/                             # MarkdownStyler.swift + one extension per token class
│   ├── Renderer/                            # LayoutBridge, MarkdownTextLayoutFragment, EmbeddedImageCache
│   ├── Input/                               # MarkdownInputHandler + MarkdownListHandler
│   ├── TextView/
│   │   ├── NativeTextViewWrapper.swift      # SwiftUI entry point (NSViewRepresentable)
│   │   ├── NativeTextView/                  # AppKit subclass + UX extensions (paste, drag-select, …)
│   │   └── Coordinator/                     # NSTextViewDelegate split by concern (restyling, find, …)
│   └── MarkdownEngine.docc/                 # DocC catalog
├── MarkdownEngineCodeBlocks/                # opt-in SPM product — pulls in HighlighterSwift
│   └── HighlighterSwiftBridge.swift         # SyntaxHighlighter conformance
└── MarkdownEngineLatex/                     # opt-in SPM product — pulls in SwiftMath
    └── SwiftMathBridge.swift                # LatexRenderer conformance
```

The rest of this file is a per-directory tour, in the order text flows
through the engine.

## [`Parser/`](Sources/MarkdownEngine/Parser): what is a token?

Regex-driven tokenizer. Emphasis (`*`, `**`, `***`) runs through a
separate stack parser in `MarkdownTokenizer+Emphasis.swift` to handle
nesting. Each `MarkdownToken` has a `kind`, a `range`, a `contentRange`,
and `markerRanges` (for `**bold**`, the two `**`).

Token kinds: `italic`, `bold`, `boldItalic`, `link`, `wikiLink`,
`heading`, `codeBlock`, `inlineCode`, `blockLatex`, `inlineLatex`,
`imageEmbed`.

**Invariant:** Tokenization is pure, allocation-light, and cheap enough
to re-run on every keystroke. Tokens are not cached outside
`NativeTextViewCoordinator`, and never mutated after a styling pass.

## [`Services/`](Sources/MarkdownEngine/Services): how does the engine talk to your app?

`MarkdownEditorServices.swift` declares the four service protocols.
Internally each is called synchronously from a specific styling pass:
`WikiLinkResolver` from `styleWikiLinks`, `EmbeddedImageProvider` from
`styleImageEmbeds`, `SyntaxHighlighter` from `styleCodeBlocks` /
`styleInlineCode`, `LatexRenderer` from `styleBlockLatex` /
`styleInlineLatex`.

`WikiLinkService.swift` handles the dual-form storage / display
transform — storage is `[[Name|<id>]]`, display is `[[Name]]`. The
coordinator runs it both ways every time `rebuildTextStorageAndStyle()`
fires.

**Invariant:** Service callbacks are synchronous. If an embedder's
implementation is slow, it caches (both bundled bridges do); the engine
never async-renders.

**Invariant:** Wiki-link storage and display are different strings.
Display IDs never leak into the binding.

## [`Styling/`](Sources/MarkdownEngine/Styling): how do tokens become attributes?

`MarkdownStyler.styleAttributes()` (`MarkdownStyler.swift:78`) runs an
ordered pipeline of styling passes — headings, emphasis, auto-links,
wiki-links, image embeds, markdown links, code blocks, inline code,
block / inline LaTeX, horizontal rules, incomplete brackets, task
checkboxes, marker-shrinking — each returning `[(range, attributes)]`.
Passes are linear and additive; later passes intentionally clobber
earlier ones (which is why `shrinkInactiveMarkers` runs last).

If the coordinator passes `scopedRanges`, range-based scans only touch
those paragraphs — the optimization that keeps per-keystroke restyling
cheap.

**Invariant:** Markers shrink, they don't disappear. Inactive markers
render at `hiddenMarkerFontSize`; they're never removed from text
storage. Every selection / copy / find / undo bug downstream traces back
to violating this.

## [`Renderer/`](Sources/MarkdownEngine/Renderer): TextKit 2 layout

Thin wrappers around `NSTextLayoutManager` (`LayoutBridge.swift`), a
custom `MarkdownTextLayoutFragment` for precise positioning, and
`EmbeddedImageCache` keyed by an embedder-supplied fingerprint so images
and LaTeX results invalidate when the embedder says so.

## [`Input/`](Sources/MarkdownEngine/Input): typing-time helpers

`MarkdownInputHandler.swift` handles auto-wrap for `$…$` / `$$…$$` /
`![[…]]`. `MarkdownListHandler.swift` handles list continuation,
indent / outdent, and task-checkbox toggling on Enter / Tab / Backspace.
Both run synchronously inside the text-view delegate.

## [`TextView/`](Sources/MarkdownEngine/TextView): NSTextView + SwiftUI bridge

The entry point is `NativeTextViewWrapper.swift` — an
`NSViewRepresentable` that owns the coordinator and the configured text
view. Two sub-folders matter:

- `NativeTextView/` — extensions on the AppKit subclass (paste,
  drag-select boost, spell policy, caret workarounds)
- `Coordinator/` — `NSTextViewDelegate` glue, split by concern
  (restyling, writing-tools, find, code-blocks, inline selection,
  autocorrect)

Application of `[StyledRange]` to text storage happens in
`Coordinator/NativeTextViewCoordinator+Restyling.swift` →
`rebuildTextStorageAndStyle()`.

## [`Configuration/`](Sources/MarkdownEngine/Configuration): the tunables

`MarkdownEditorConfiguration` is a struct of structs — one nested group
per concern (headings, codeBlock, blockLatex, overscroll, markers,
lists, …) — passed by reference into every styling pass via the
`StylingContext`. `MarkdownEditorTheme` is its colour sub-field.
