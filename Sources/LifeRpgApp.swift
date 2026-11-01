import SwiftUI
import UIKit
import UserNotifications

@MainActor
@main
struct LifeRpgApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
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

struct ContentView: View {
    @State private var clickCount = 0
    @State private var isShowingError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("Xin chào mq!!!")
                .font(.largeTitle.bold())

            Button("Click!") {
                clickCount += 1
                let currentClickCount = clickCount
                Task {
                    await sendNotification(for: currentClickCount)
                }
            }
            .font(.title2)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .alert("Không thể gửi thông báo", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @MainActor
    private func sendNotification(for count: Int) async {
        let notificationCenter = UNUserNotificationCenter.current()

        do {
            let isAuthorized = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            guard isAuthorized else {
                errorMessage = "Vui lòng bật quyền thông báo cho ứng dụng trong Cài đặt để nhận thông báo trên màn hình khóa."
                isShowingError = true
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Xin chào mq!!!"
            content.body = "Bạn đã click \(count) lần"
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: trigger
            )
            try await notificationCenter.add(request)
        } catch {
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }
}
