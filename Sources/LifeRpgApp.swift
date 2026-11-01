import SwiftUI

@main
struct LifeRpgApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var clickCount = 0
    @State private var isShowingAlert = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Xin chào mq!!!")
                .font(.largeTitle.bold())

            Button("Click!") {
                clickCount += 1
                isShowingAlert = true
            }
            .font(.title2)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .alert("Thông báo", isPresented: $isShowingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Bạn đã click \(clickCount) lần")
        }
    }
}
