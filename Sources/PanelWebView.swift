import SwiftUI
import WebKit

// Panel skill tree chạy OFFLINE trong app:
// - UI: Resources/index.html (từ repo EpicTalesCoder/skilltree) bundle sẵn trong IPA.
// - API: SkillTreeLocalServer (Swift) thay thế server.py — cùng endpoints, dữ liệu lưu SQLite trong app.
// - Remote URL chỉ dùng khi bật "Dùng bản web" trong menu app (sync với skilltree.risktherain.com).

let PANEL_URL = URL(string: "https://skilltree.risktherain.com")!

// MARK: - ViewModel

@MainActor
final class PanelViewModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case offline = "Trong app"
        case remote = "Bản web"
        var id: String { rawValue }
    }

    @Published var isLoading = true
    @Published var progress: Double = 0
    @Published var isOffline = false
    @Published var toast: String?
    @Published var source: Source = .offline
    @Published var showSourcePicker = false

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
        context.coordinator.observeSourceChange()

        webView.load(context.coordinator.request(for: model.source))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: PanelViewModel
        var webView: WKWebView?
        private var reloadObserver: NSObjectProtocol?
        private var sourceObserver: NSObjectProtocol?
        private var localServer: SkillTreeLocalServer?

        init(model: PanelViewModel) {
            self.model = model
        }

        func request(for source: PanelViewModel.Source) -> URLRequest {
            switch source {
            case .offline:
                let server = localServer ?? {
                    let s = SkillTreeLocalServer()
                    do { try s.start() } catch {
                        model.showToast("Không khởi động được server cục bộ: \(error.localizedDescription)")
                    }
                    localServer = s
                    return s
                }()
                return URLRequest(url: server.rootURL)
            case .remote:
                // Dừng server cục bộ khi chuyển sang bản web
                localServer?.stop()
                localServer = nil
                return URLRequest(url: PANEL_URL)
            }
        }

        func observeReload() {
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .panelReloadRequested, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let webView = self.webView else { return }
                webView.reload()
            }
        }

        func observeSourceChange() {
            sourceObserver = NotificationCenter.default.addObserver(
                forName: .panelSourceChanged, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let source = note.object as? PanelViewModel.Source,
                      source != self.model.source else { return }
                self.model.source = source
                self.webView?.load(self.request(for: source))
            }
        }

        deinit {
            if let reloadObserver { NotificationCenter.default.removeObserver(reloadObserver) }
            if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
            localServer?.stop()
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
            // Bản web lỗi mạng → đưa về bản trong app
            if model.source == .remote {
                model.showToast("Không kết nối được bản web, chuyển về bản trong app")
                NotificationCenter.default.post(name: .panelSourceChanged, object: PanelViewModel.Source.offline)
            } else {
                model.handleFailure(error.localizedDescription)
            }
        }
    }
}

extension Notification.Name {
    static let panelSourceChanged = Notification.Name("panelSourceChanged")
}
