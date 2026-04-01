import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    var sessionManager: SessionManager?
    private var cancellables = Set<AnyCancellable>()
    private var popover: NSPopover?
    private var hotKeyRef: EventHotKeyRef?
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "SwitchBoard")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.observeSessionManager()
        }

        registerGlobalHotKey()

        // alwaysOnTop 변경 감지
        UserDefaults.standard.publisher(for: \.alwaysOnTop)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAlwaysOnTop() }
            .store(in: &cancellables)
    }

    private func observeSessionManager() {
        guard let sm = sessionManager else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.observeSessionManager()
            }
            return
        }

        sm.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: [Session]) in self?.updateIcon() }
            .store(in: &cancellables)

        sm.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: Bool) in self?.updateIcon() }
            .store(in: &cancellables)

        // 초기 적용
        applyAlwaysOnTop()
    }

    private func applyAlwaysOnTop() {
        guard let window = NSApp.windows.first(where: { $0.title == "Switchboard" }) else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }

    private func updateIcon() {
        guard let sm = sessionManager else { return }
        let symbolName: String
        if sm.hasNeedsInput {
            symbolName = "exclamationmark.triangle.fill"
        } else if sm.hasWorking {
            symbolName = "circle.dotted"
        } else if sm.allDoneOrIdle {
            symbolName = "checkmark.circle"
        } else {
            symbolName = "square.grid.2x2"
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SwitchBoard")
            button.contentTintColor = tintColor(sm)
        }
    }

    private func tintColor(_ sm: SessionManager) -> NSColor? {
        if sm.hasNeedsInput { return .systemYellow }
        if sm.hasWorking { return .systemBlue }
        if sm.allDoneOrIdle { return .systemGreen }
        return nil
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showDashboard()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let sm = sessionManager, let button = statusItem.button else { return }
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 320, height: 400)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: PopoverView(sessionManager: sm, onOpenDashboard: { [weak self] in
                pop.performClose(nil)
                self?.showDashboard()
            })
        )
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = pop
    }

    // 앱이 포그라운드여도 알림 표시
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func registerGlobalHotKey() {
        // Cmd+Shift+S 로 팝오버 토글
        let hotKeyID = EventHotKeyID(signature: OSType(0x5342_4F52), id: 1) // "SBOR"
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRef = ref

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            Task { @MainActor in
                guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
                appDelegate.togglePopover()
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    private func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Switchboard" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// UserDefaults KVO 지원
extension UserDefaults {
    @objc dynamic var alwaysOnTop: Bool {
        bool(forKey: "alwaysOnTop")
    }
}
