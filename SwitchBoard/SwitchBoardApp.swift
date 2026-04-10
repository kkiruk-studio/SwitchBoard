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
