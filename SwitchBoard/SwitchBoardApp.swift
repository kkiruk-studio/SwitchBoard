import SwiftUI

// 진입점은 main.swift에서 분기한 뒤 SwitchBoardApp.main()을 호출한다.
struct SwitchBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionManager = SessionManager()

    var body: some Scene {
        Window("SwitchBoard", id: "dashboard") {
            DashboardView(sessionManager: sessionManager)
                .frame(minWidth: 370, minHeight: 300)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                    sessionManager.startPolling()

                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 540, height: 500)
        .defaultPosition(.topTrailing)

        Settings {
            PreferencesView()
        }
    }

}
