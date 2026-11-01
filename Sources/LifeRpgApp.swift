import SwiftUI
import UIKit
import UserNotifications

@MainActor
@main
struct LifeRpgApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PanelRootView()
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

struct PanelRootView: View {
    @StateObject private var model = PanelViewModel()

    private let background = Color(red: 0.027, green: 0.031, blue: 0.082) // #070815

    var body: some View {
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

            Text("Không tải được panel Skill Tree.\nKiểm tra mạng rồi thử lại nhé.")
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
