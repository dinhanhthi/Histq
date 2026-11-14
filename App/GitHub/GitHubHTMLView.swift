// GitHub's sanitized HTML (`body_html`) in a WKWebView, locked down like a read-only page: no JavaScript from the page
// (`allowsContentJavaScript` false), a non-persistent data store (no cookies, no cache on disk), no base URL (the page
// is `about:blank`, so nothing resolves to a file:// URL), and a Content-Security-Policy that allows no remote load at
// all: images, styles, fonts, frames and media stay blocked (a GitHub image shows as its alt text). WKWebView loads
// through its own network stack, outside the stub `URLSession`, so allowing GitHub's image CDN would let a stub run
// reach the network; showing images is a follow-up. A click on an http(s) link opens the default browser; every other
// navigation (other schemes, forms, refreshes, frames, fragment jumps) is cancelled. Colors come from `Palette`.
import AppKit
import SwiftUI
import WebKit

/// A page of GitHub HTML that fills its frame and scrolls on its own. `html` goes into the page's body: GitHub's
/// `body_html` as GitHub sanitized it, and markup Histq built around it with every other value passed through
/// `GitHubHTML.escape`.
struct GitHubHTMLView: NSViewRepresentable {
    let html: String
    /// Called once the page has been laid out (the timing log's content line).
    var onLoad: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.allowsLinkPreview = false
        view.underPageBackgroundColor = GitHubHTML.background
        // Hidden until the first page is laid out: no white frame before the dark stylesheet applies.
        view.alphaValue = 0
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onLoad = onLoad
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.expectsLoad = true
        view.loadHTMLString(GitHubHTML.document(body: html), baseURL: nil)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        /// Set by `loadHTMLString`: the one main-frame load of `about:blank` the page may make.
        var expectsLoad = false
        var onLoad: @MainActor () -> Void = {}

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated {
                GitHubLinks.open(action.request.url)
                return decisionHandler(.cancel)
            }
            let isOwnLoad = expectsLoad && action.navigationType == .other && action.targetFrame?.isMainFrame == true
                && action.request.url?.absoluteString == "about:blank"
            if isOwnLoad { expectsLoad = false }
            decisionHandler(isOwnLoad ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.alphaValue = 1
            onLoad()
        }

        /// `target="_blank"` links: the link click already went to the browser; no window is ever made.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

/// Opens GitHub links in the default browser: http and https only, never another scheme a page could name.
enum GitHubLinks {
    static func open(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    static func open(_ string: String?) {
        open(string.flatMap(URL.init(string:)))
    }
}

/// The page around GitHub's HTML: the policy, the stylesheet from `Palette`, and the escaping of Histq's own values.
enum GitHubHTML {
    /// Escapes text for an HTML text node or a quoted attribute value.
    nonisolated static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// The card's fill: the page is drawn on it.
    static var background: NSColor { NSColor(Palette.surface) }

    /// `body` in a full document whose first element is the policy, before anything the body could add.
    static func document(body: String) -> String {
        """
        <!DOCTYPE html><html><head>\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">\
        <meta charset="utf-8"><style>\(stylesheet)</style></head><body>\(body)</body></html>
        """
    }

    /// Built once, from the dark appearance's values of the palette and the system's semantic colors.
    private static let stylesheet: String = {
        var css = ""
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            let text = rgba(Palette.diffText)
            let secondary = rgba(.secondaryLabelColor)
            let border = rgba(NSColor(Palette.surfaceBorder))
            let header = rgba(NSColor(Palette.tabFill))
            let code = rgba(NSColor(Palette.inputSurface))
            let link = rgba(NSColor(Color.accentColor))
            let added = rgba(Palette.diffAddedSign)
            let removed = rgba(Palette.diffRemovedSign)
            css = """
                html, body { margin: 0; padding: 0; background: \(rgba(background)); color: \(text);
                  font: 13px/1.5 -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
                body { padding: 2px 0 10px; overflow-wrap: anywhere; }
                a { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
                p, ul, ol, pre, blockquote, table { margin: 0 0 8px; } .body > :last-child { margin-bottom: 0; }
                h1, h2, h3, h4 { margin: 12px 0 6px; line-height: 1.25; } h1 { font-size: 1.4em; } h2 { font-size: 1.25em; }
                code, pre { font: 12px ui-monospace, "SF Mono", Menlo, monospace; background: \(code); border-radius: 6px; }
                code { padding: 1px 4px; } pre { padding: 8px 10px; overflow-x: auto; } pre code { padding: 0; background: none; }
                blockquote { margin-left: 0; padding-left: 10px; border-left: 3px solid \(border); color: \(secondary); }
                table { border-collapse: collapse; } td, th { border: 1px solid \(border); padding: 4px 8px; }
                img { max-width: 100%; } hr { border: 0; border-top: 1px solid \(border); }
                .item { border: 1px solid \(border); border-radius: 10px; margin: 0 0 10px; overflow: hidden; }
                .head { background: \(header); padding: 6px 10px; color: \(secondary); display: flex; gap: 6px;
                  align-items: baseline; flex-wrap: wrap; }
                .head b { color: \(text); font-weight: 600; } .head .date { margin-left: auto; }
                .body { padding: 8px 10px; } .empty { color: \(secondary); font-style: italic; } .plain { white-space: pre-wrap; }
                .badge { font-weight: 600; } .approved { color: \(added); } .changes { color: \(removed); }
                """
        }
        return css
    }()

    /// `rgba(r, g, b, a)` of a color in sRGB.
    private static func rgba(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return "rgba(\(byte(srgb.redComponent)), \(byte(srgb.greenComponent)), \(byte(srgb.blueComponent)), "
            + String(format: "%.3f", srgb.alphaComponent) + ")"
    }
}
