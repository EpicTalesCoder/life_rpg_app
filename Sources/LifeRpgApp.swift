import SwiftUI

@main
struct LifeRpgApp: App {
    var body: some Scene {
        WindowGroup {
            PanelRootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct PanelRootView: View {
    @StateObject private var model = PanelViewModel()

    private let background = Color(red: 0.027, green: 0.031, blue: 0.082) // #070815

    var body: some View {
        NavigationStack {
            ZStack {
                background.ignoresSafeArea()

                PanelWebView(model: model)
                    .ignoresSafeArea(.all)

                // Thanh tiến trình mảnh dưới status bar khi đang tải
                VStack(spacing: 0) {
                    if model.isLoading && !model.isOffline {
                        ProgressView(value: model.progress)
                            .tint(Color.accentColor)
                            .animation(.easeInOut(duration: 0.25), value: model.progress)
                    }
                    Spacer()
                }

                if model.isOffline {
                    OfflineOverlay {
                        model.reload()
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.isOffline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        model.showSourcePicker = true
                    } label: {
                        Image(systemName: model.source == .offline ? "internaldrive" : "cloud")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Chọn nguồn panel")
                }
            }
            .navigationTitle(model.source.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Chọn nguồn panel",
                isPresented: $model.showSourcePicker,
                titleVisibility: .visible
            ) {
                ForEach(PanelViewModel.Source.allCases) { src in
                    Button(src == model.source ? "✓ " + src.rawValue : src.rawValue) {
                        NotificationCenter.default.post(name: .panelSourceChanged, object: src)
                    }
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("""
                «Trong app» chạy hoàn toàn offline, dữ liệu lưu riêng trên máy này.
                «Bản web» tải skilltree.risktherain.com — dùng chung dữ liệu với server.
                «Agent Panel» và «Dell Agent» mở dashboard Hermes tại agent.risktherain.com và dell-agent.risktherain.com (cần đăng nhập lần đầu).
                """)
            }
        }
    }
}

struct OfflineOverlay: View {
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.85))

            Text("Mất kết nối")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("Không tải được panel.\nKiểm tra mạng rồi thử lại nhé.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)

            Button(action: retry) {
                Label("Thử lại", systemImage: "arrow.clockwise")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.top, 6)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.027, green: 0.031, blue: 0.082).ignoresSafeArea())
    }
}
