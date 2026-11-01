import SwiftUI

@main
struct LifeRpgApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                PanelScreen(site: PANEL_SITES[0])
                    .tabItem { Label(PANEL_SITES[0].title, systemImage: PANEL_SITES[0].systemImage) }
                PanelScreen(site: PANEL_SITES[1])
                    .tabItem { Label(PANEL_SITES[1].title, systemImage: PANEL_SITES[1].systemImage) }
                PanelScreen(site: PANEL_SITES[2])
                    .tabItem { Label(PANEL_SITES[2].title, systemImage: PANEL_SITES[2].systemImage) }
            }
            .preferredColorScheme(.dark)
        }
    }
}

struct PanelScreen: View {
    let site: PanelSite
    @StateObject private var model = PanelViewModel()
    private let background = Color(red: 0.027, green: 0.031, blue: 0.082) // #070815

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            PanelWebView(model: model, site: site)

            // Thanh tiến trình mảnh ở mép trên khi đang tải
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

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 56) // nổi phía trên tab bar
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.2), value: model.toast)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isOffline)
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
