import SwiftUI

@main
struct SwitchBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionManager = SessionManager()

    var body: some Scene {
        Window("Switchboard", id: "dashboard") {
            DashboardView(sessionManager: sessionManager)
                .frame(minWidth: 370, minHeight: 300)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                    sessionManager.startPolling()

                    // 세션 수에 따라 초기 윈도우 크기 조정
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        adjustWindowSize()
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 500)
        .defaultPosition(.topTrailing)

        Settings {
            PreferencesView()
        }
    }

    private func adjustWindowSize() {
        guard let window = NSApp.windows.first(where: { $0.title == "Switchboard" }) else { return }
        let count = sessionManager.sessions.count
        // 카드 160pt + 간격 10pt + 패딩 24pt
        // 2열: 160*2 + 10 + 24 = 354 → 넉넉하게 380
        // 3열: 160*3 + 20 + 24 = 524 → 넉넉하게 540
        let width: CGFloat = count >= 5 ? 540 : 380
        let frame = window.frame
        let newFrame = NSRect(x: frame.origin.x, y: frame.origin.y + frame.height - 500, width: width, height: 500)
        window.setFrame(newFrame, display: true, animate: true)
    }
}
