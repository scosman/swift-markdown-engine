//
//  HighlighterSwiftBridge.swift
//  MarkdownEngineCodeBlocks
//
//  Ready-made SyntaxHighlighter conformance backed by HighlighterSwift.
//

import AppKit
import Foundation
import Highlighter
import MarkdownEngine

extension Notification.Name {
    /// Posted by ``HighlighterSwiftBridge`` after the macOS appearance flips
    /// and the bridge has re-applied its light/dark theme. The engine
    /// subscribes to this through ``SyntaxHighlighter/appearanceDidChangeNotification``
    /// so it can invalidate cached code-block attributes.
    public static let markdownEngineHighlighterDidChangeAppearance =
        Notification.Name("MarkdownEngineHighlighterDidChangeAppearance")
}

/// A drop-in ``SyntaxHighlighter`` backed by HighlighterSwift.
///
/// Delegates the editor's code-block background color and code font to
/// HighlighterSwift's loaded theme, so changing the theme name updates
/// the entire code-block look in one place.
///
/// When `autoSwitchAppearance` is `true` (the default), the bridge
/// observes `AppleInterfaceThemeChangedNotification` and re-applies
/// `darkTheme` / `lightTheme` accordingly, then posts
/// ``Notification/Name/markdownEngineHighlighterDidChangeAppearance`` so
/// the engine re-renders affected code blocks.
public final class HighlighterSwiftBridge: SyntaxHighlighter, @unchecked Sendable {
    private let highlighter: Highlighter?
    private let lightTheme: String
    private let darkTheme: String
    private let autoSwitchAppearance: Bool
    private var currentTheme: String = ""

    /// - Parameters:
    ///   - lightTheme: HighlighterSwift theme name applied in light mode.
    ///   - darkTheme: HighlighterSwift theme name applied in dark mode.
    ///   - autoSwitchAppearance: When `true`, observes the system
    ///     appearance and swaps themes automatically. Set to `false` to
    ///     pin the bridge to `lightTheme` regardless of mode.
    public init(
        lightTheme: String = "atom-one-light",
        darkTheme: String = "atom-one-dark",
        autoSwitchAppearance: Bool = true
    ) {
        self.highlighter = Highlighter()
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.autoSwitchAppearance = autoSwitchAppearance
        applyAppearanceTheme()

        if autoSwitchAppearance {
            DistributedNotificationCenter.default.addObserver(
                forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.applyAppearanceTheme()
                NotificationCenter.default.post(
                    name: .markdownEngineHighlighterDidChangeAppearance,
                    object: nil
                )
            }
        }
    }

    private func applyAppearanceTheme() {
        guard let highlighter else { return }
        let isDark = autoSwitchAppearance &&
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? darkTheme : lightTheme
        if currentTheme != theme {
            currentTheme = theme
            highlighter.setTheme(theme)
        }
    }

    // MARK: - SyntaxHighlighter

    public var appearanceDidChangeNotification: Notification.Name? {
        autoSwitchAppearance ? .markdownEngineHighlighterDidChangeAppearance : nil
    }

    public func codeFont(size: CGFloat) -> NSFont {
        if let themeFont = highlighter?.theme.codeFont {
            return NSFont(name: themeFont.fontName, size: size) ?? themeFont
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> NSColor {
        highlighter?.theme.themeBackgroundColour ?? .clear
    }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        applyAppearanceTheme()
        guard let highlighter else { return nil }
        let normalized = language?.lowercased().trimmingCharacters(in: .whitespaces)
        if let lang = normalized, !lang.isEmpty {
            return highlighter.highlight(code, as: lang)
        }
        return highlighter.highlight(code, as: nil)
    }
}
