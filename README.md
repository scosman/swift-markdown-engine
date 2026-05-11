# MarkdownEngine

[![Swift 5.9](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms macOS 14+](https://img.shields.io/badge/Platforms-macOS%2014+-lightgrey)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml)



<video src="https://github.com/user-attachments/assets/b61ed622-0e9a-4e91-9de5-9cd6c53752e5"
       autoplay loop muted playsinline
       width="100%">
</video>


A native AppKit Markdown editor for macOS, built on TextKit 2 and bridged to
SwiftUI. Live styling, wiki-link support, fenced code blocks with syntax
highlighting, LaTeX rendering, embedded images, and GitHub-style task
checkboxes.

## Motivation

When we started building **[Nodes](https://nodes-web.com/#/)** a minimal, beautiful, and fast writing app for macOS, we thought the editor would be the easy part. We were wrong. None of the existing open-source options fit what we needed: a native editor we could drop straight into a Mac app. So we built it on top of TextKit 2. It [wasn't easy](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/), but the result holds up in production. We're sharing it because we wished something like this had existed when we started.

## Features

- **Live Markdown styling** — bold, italic, headings, lists, code, links,
  task checkboxes, horizontal rules
- **Wiki-style linking** with two-form storage / display roundtripping
  (`[[Name|<id>]]` ↔ `[[Name]]`)
- **Image embeds** — `![[Name]]` syntax, embedder supplies the bytes
- **LaTeX** — both block (`$$ … $$`) and inline (`$…$`), embedder supplies
  the renderer
- **Code blocks** with embedder-supplied syntax highlighting and overlayable
  copy buttons
- **TextKit 2** layout for accurate, modern text rendering
- **Writing Tools** integration on macOS 15.1+
- **Comfortable bottom overscroll** so the caret never pins to the viewport
  edge while typing
- **Drag-select autoscroll boost** for long documents
- **Spelling & grammar** with code/LaTeX/wiki-link suppression

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/nodes-app/swift-markdown-engine", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
        ]
    )
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

The package ships two library products — add only what you need:

| Product | Use when |
|---|---|
| `MarkdownEngine` | You want the editor only. Zero external dependencies. |
| `MarkdownEngineHighlighter` | You want fenced-code syntax highlighting without writing your own bridge. Pulls in [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) transitively. See [Customization → Syntax Highlighting](#syntax-highlighting). |

## Quick Start

```swift
import SwiftUI
import MarkdownEngine

struct EditorScreen: View {
    @State private var text: String = "# Hello, *world*"

    var body: some View {
        NativeTextViewWrapper(text: $text)
    }
}
```

That's it. See [Customization](#customization) below for syntax
highlighting, themes, wiki-link state, and more.

> **Displaying multiple editors?** Pass a stable, unique
> `documentId: "your-doc-id"` so undo history and pending replacements
> stay scoped to each editor instance.

## Customization

### Service Protocols

The engine talks to your app through four service protocols, each with
a no-op default so you only implement what you actually need:

| Protocol | What you supply | Default | Ready-made bridge / suggested library |
|---|---|---|---|
| `WikiLinkResolver` | Resolve a `[[Name]]` to a stable opaque id | `NoOpWikiLinkResolver` | (your data model) |
| `EmbeddedImageProvider` | Look up an `NSImage` for `![[Name]]` | `NoOpEmbeddedImageProvider` | (your asset store) |
| `SyntaxHighlighter` | Highlight code blocks for a given language | `PlainTextSyntaxHighlighter` | **`HighlighterSwiftBridge`** ([recommended](#syntax-highlighting)), wrapping [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) |
| `LatexRenderer` | Render a LaTeX string to an `NSImage` | `NoOpLatexRenderer` | [SwiftMath](https://github.com/mgriebling/SwiftMath) (roll your own bridge) |

Implement what you need and pass it through `MarkdownEditorServices`:

```swift
struct MyResolver: WikiLinkResolver {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        myIndex[displayName].map { WikiLinkResolution(id: $0, exists: true) }
    }
}

configuration.services = MarkdownEditorServices(
    wikiLinks: MyResolver()
    // images, syntaxHighlighter, latex omitted → no-op defaults
)
```

Each protocol and its no-op default are documented in DocC.

### Syntax Highlighting

**Recommended path: depend on the `MarkdownEngineHighlighter` product
and use the bundled `HighlighterSwiftBridge`.** Implementing
`SyntaxHighlighter` from scratch has subtle footguns the bridge
already handles — line-height metrics across light/dark themes,
appearance-change observation, layout-pass timing, font name extraction
from the theme. Use the bundle unless you specifically need a
non-HighlighterSwift library.

```swift
import MarkdownEngineHighlighter

var configuration = MarkdownEditorConfiguration.default
configuration.services = MarkdownEditorServices(
    syntaxHighlighter: HighlighterSwiftBridge()
)
```

The bridge auto-switches between `atom-one-light` and `atom-one-dark`
with system appearance. Different theme names or a pinned single theme
are configurable via init params — see DocC.

Need a different highlighter library entirely? Implement
`SyntaxHighlighter` yourself (see [Service Protocols](#service-protocols)
above for the declaration) and reference the bundled bridge in
`Sources/MarkdownEngineHighlighter/` as a working example.

### Theming

Every color the editor puts on screen reads from `MarkdownEditorTheme`:

```swift
var theme = MarkdownEditorTheme.default
theme.bodyText = .labelColor
theme.findMatchHighlight = NSColor(named: "MyAccent")!

var configuration = MarkdownEditorConfiguration.default
configuration.theme = theme
```

Defaults map to `NSColor` dynamic system colors, so light/dark mode
keeps working without extra code.

### Tuning

`MarkdownEditorConfiguration` exposes every spacing / sizing / behavior
knob the engine has, grouped by concern:

```swift
var configuration = MarkdownEditorConfiguration.default
configuration.codeBlock.fontSizeScale = 0.9
configuration.headings.fontMultipliers = [2.4, 1.8, 1.4, 1.1, 0.9, 0.75]
configuration.overscroll.percent = 0.4
configuration.lists.helpersEnabled = false
```

### Wiki-Links & Replacement State

Two optional bindings on `NativeTextViewWrapper` let you observe
wiki-link state and push inline replacements programmatically. Pass
only what you need — each is independent and defaults to a no-op:

```swift
NativeTextViewWrapper(
    text: $text,
    isWikiLinkActive: $isWikiLinkActive,
    pendingInlineReplacement: $pendingReplacement
)
```

- `isWikiLinkActive` — the wrapper sets this to `true` while the caret
  sits inside a `[[Name]]` link, so you can present a contextual UI.
- `pendingInlineReplacement` — assign a non-nil value to push a
  replacement (e.g. an autocomplete result); the engine consumes it
  and clears the binding.

## Demo

A runnable SwiftUI demo lives in [`Demo/`](Demo/MarkdownEngineDemo.xcodeproj).
Open it in Xcode and hit **Run** — the demo references the package via
a local path, so any engine edit rebuilds into the demo on the next run.

> If you're seeing a "missing package product" error, it's almost always
> stale package cache. Use **File → Packages → Reset Package Caches**
> once and rebuild.

## Documentation

Full API documentation is available via DocC:

```bash
swift package generate-documentation --target MarkdownEngine
```

In Xcode: **Product → Build Documentation** (`⇧⌃⌘D`).

Once the package is hosted on Swift Package Index, the docs will live at
`https://swiftpackageindex.com/nodes-app/swift-markdown-engine/documentation`.

## Requirements & Status

- macOS 14 or later (15.1+ for Apple Writing Tools integration)
- Swift 5.9 / Xcode 15 or later

MarkdownEngine is currently **pre-1.0**. The public API may change between
minor releases as it stabilizes. Production use is fine — pin a specific
version (`0.x.y`) in your `Package.swift`.

## Contributing

Bug reports, ideas, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, coding
conventions, and PR process.

## License

MarkdownEngine is released under the MIT License. See [LICENSE](LICENSE)
for the full text.
