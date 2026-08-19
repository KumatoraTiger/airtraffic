import SwiftUI
import WebKit

/// Shows a self-contained HTML page. The report page carries its own styles
/// and no scripts or remote assets, so the view stays a plain renderer:
/// JavaScript is off and every navigation attempt is refused.
struct ReportWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The HTML currently loaded; reloading the same string would flicker.
        var loaded: String?

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The initial loadHTMLString is `.other`; anything else would be a
            // link, and this view is not a browser.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
