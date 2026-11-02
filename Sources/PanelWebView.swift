import SwiftUI
import WebKit

// Toàn bộ panel chạy dạng WEB (điện thoại luôn có 4G, không còn bản offline):
//   - Skill Tree : skilltree.risktherain.com
//   - Agent      : agent.risktherain.com (Hermes dashboard)
//   - Dell Agent : dell-agent.risktherain.com (Hermes dashboard)
// Mỗi tab là một WKWebView riêng, giữ nguyên phiên đăng nhập khi chuyển qua lại.

struct PanelSite: Identifiable {
    let title: String
    let systemImage: String
    let url: URL
    var id: String { title }
}

let PANEL_SITES: [PanelSite] = [
    PanelSite(title: "Skill Tree", systemImage: "tree", url: URL(string: "https://skilltree.risktherain.com")!),
    PanelSite(title: "Agent", systemImage: "cpu", url: URL(string: "https://agent.risktherain.com")!),
    PanelSite(title: "Dell Agent", systemImage: "desktopcomputer", url: URL(string: "https://dell-agent.risktherain.com")!),
]

// MARK: - ViewModel

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var progress: Double = 0
    @Published var isOffline = false
    @Published var toast: String?

    func reload() {
        isOffline = false
        NotificationCenter.default.post(name: .panelReloadRequested, object: nil)
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

// Tiện ích nhỏ: encode chuỗi an toàn để nhúng vào JS (dùng cho CSS injection)
extension String {
    var jsonEncoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

// MARK: - WebView

struct PanelWebView: UIViewRepresentable {
    @ObservedObject var model: PanelViewModel
    let site: PanelSite

    // Dashboard agent/dell-agent hiển thị nav mục nhỏ (38pt, font 13px) và nút
    // hamburger 41pt — quá nhỏ để bấm trên điện thoại. CSS dưới đây phóng to
    // mục nav lên ≥56pt + font 17px, hamburger 48pt (đúng chuẩn touch Apple).
    // Chỉ tác động vào sidebar/header của dashboard Hermes; trang khác giữ nguyên.
    private static let navFixCSS = """
    aside nav a[href] {
      min-height: 56px !important;
      padding-top: 16px !important;
      padding-bottom: 16px !important;
      font-size: 17px !important;
    }
    aside nav a[href] svg { width: 22px !important; height: 22px !important; }
    header button[aria-label*="navigation"] { width: 48px !important; height: 48px !important; }
    """

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let prefs = WKPreferences()
        prefs.javaScriptEnabled = true
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs

        // Phóng to nav dashboard agent (chạy trước khi trang render)
        let navFix = WKUserScript(
            source: """
            (function(){
              var s = document.createElement('style');
              s.id = 'mq-nav-fix';
              s.textContent = \(Self.navFixCSS.jsonEncoded);
              document.head.appendChild(s);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(navFix)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = true
        webView.backgroundColor = UIColor(red: 0.027, green: 0.031, blue: 0.082, alpha: 1)
        webView.isOpaque = false
        webView.allowsBackForwardNavigationGestures = true
        webView.isAccessibilityElement = true
        webView.accessibilityLabel = "Panel \(site.title)"

        // Kéo xuống để tải lại — thao tác quen thuộc trên điện thoại
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullToRefresh), for: .valueChanged)
        webView.scrollView.addSubview(refresh)
        context.coordinator.refreshControl = refresh
        context.coordinator.webView = webView

        webView.load(URLRequest(url: site.url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: PanelViewModel
        weak var webView: WKWebView?
        weak var refreshControl: UIRefreshControl?
        private var reloadObserver: NSObjectProtocol?

        init(model: PanelViewModel) {
            self.model = model
            super.init()
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .panelReloadRequested, object: nil, queue: .main
            ) { [weak self] _ in
                self?.webView?.reload()
            }
        }

        deinit {
            if let reloadObserver { NotificationCenter.default.removeObserver(reloadObserver) }
        }

        @objc func pullToRefresh() {
            webView?.reload()
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
            refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            refreshControl?.endRefreshing()
            handleLoadFailure()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            refreshControl?.endRefreshing()
            handleLoadFailure()
        }

        private func handleLoadFailure() {
            model.isLoading = false
            // Link con lỗi → lùi lại trang trước thay vì chết cả tab;
            // trang chủ lỗi hẳn → hiện overlay thử lại.
            if let webView, webView.canGoBack {
                webView.goBack()
                model.showToast("Không tải được trang, đã quay lại")
            } else {
                model.isOffline = true
            }
        }
    }
}
