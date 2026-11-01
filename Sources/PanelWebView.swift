import SwiftUI
import WebKit

// Panel gốc: skilltree.risktherain.com — trang skill tree riêng của mq.
let PANEL_URL = URL(string: "https://skilltree.risktherain.com")!

// MARK: - ViewModel

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var progress: Double = 0
    @Published var isOffline = false
    @Published var toast: String?

    private(set) var lastError: String?

    func reload() {
        isOffline = false
        lastError = nil
        NotificationCenter.default.post(name: .panelReloadRequested, object: nil)
    }

    func handleFailure(_ message: String) {
        lastError = message
        isOffline = true
    }

    func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == message { toast = nil }
        }
    }
}

extension Notification.Name {
    static let panelReloadRequested = Notification.Name("panelReloadRequested")
}

// MARK: - WebView

struct PanelWebView: UIViewRepresentable {
    @ObservedObject var model: PanelViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let prefs = WKPreferences()
        prefs.javaScriptEnabled = true
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = true
        webView.backgroundColor = UIColor(red: 0.027, green: 0.031, blue: 0.082, alpha: 1)
        webView.isOpaque = false
        webView.allowsBackForwardNavigationGestures = true
        webView.isAccessibilityElement = true
        webView.accessibilityLabel = "Panel Skill Tree"

        context.coordinator.webView = webView
        context.coordinator.observeReload()

        webView.load(URLRequest(url: PANEL_URL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: PanelViewModel
        var webView: WKWebView?
        private var reloadObserver: NSObjectProtocol?

        init(model: PanelViewModel) {
            self.model = model
        }

        func observeReload() {
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .panelReloadRequested, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let webView = self.webView else { return }
                webView.reload()
            }
        }

        deinit {
            if let reloadObserver { NotificationCenter.default.removeObserver(reloadObserver) }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.isLoading = true
            model.progress = 0.05
            model.isOffline = false
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.progress = 0.5
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.isLoading = false
            model.progress = 1
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
            model.handleFailure(error.localizedDescription)
            model.showToast("Lỗi tải trang: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            model.isLoading = false
            model.handleFailure(error.localizedDescription)
        }
    }
}
