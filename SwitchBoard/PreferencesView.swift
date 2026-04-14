import SwiftUI
import ServiceManagement
import UserNotifications
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("settings.tab.general")
                }
            NotificationTab()
                .tabItem {
                    Image(systemName: "bell")
                    Text("settings.tab.notification")
                }
            AboutTab()
                .tabItem {
                    Image(systemName: "info.circle")
                    Text("settings.tab.about")
                }
        }
        .frame(width: 480, height: 520)
    }
}

// MARK: - 일반

private struct GeneralTab: View {
    @AppStorage("pollInterval") private var pollInterval = 3.0
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("menuBarBadge") private var menuBarBadge = "always"
    @AppStorage("hideCostEstimate") private var hideCostEstimate = false
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Picker("settings.poll_interval", selection: $pollInterval) {
                Text(String(format: NSLocalizedString("settings.seconds", comment: ""), 2)).tag(2.0)
                Text(String(format: NSLocalizedString("settings.seconds", comment: ""), 3)).tag(3.0)
                Text(String(format: NSLocalizedString("settings.seconds", comment: ""), 5)).tag(5.0)
                Text(String(format: NSLocalizedString("settings.seconds", comment: ""), 10)).tag(10.0)
            }
            .pickerStyle(.menu)

            Picker("settings.menubar_badge", selection: $menuBarBadge) {
                Text("settings.badge.always").tag("always")
                Text("settings.badge.active_only").tag("active")
                Text("settings.badge.icon_only").tag("none")
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("settings.show_cost_estimate", isOn: Binding(
                    get: { !hideCostEstimate },
                    set: { hideCostEstimate = !$0 }
                ))
                Text("settings.show_cost_estimate.desc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("settings.always_on_top", isOn: $alwaysOnTop)
            Toggle("settings.launch_at_login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(newValue)
                }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
    }
}

// MARK: - 알림

private struct NotificationTab: View {
    @AppStorage("notifyOnComplete") private var notifyOnComplete = true
    @AppStorage("notificationSound") private var notificationSound = "default"
    @AppStorage("notificationSoundNeedsInput") private var notificationSoundNeedsInput = "default"
    @AppStorage("notifyTextDone") private var notifyTextDone = ""
    @AppStorage("notifyTextNeedsInput") private var notifyTextNeedsInput = ""
    @State private var systemNotificationDenied = false
    @AppStorage("slackWebhookURL") private var slackWebhookURL = ""
    @AppStorage("slackEnabled") private var slackEnabled = false
    @AppStorage("discordWebhookURL") private var discordWebhookURL = ""
    @AppStorage("discordEnabled") private var discordEnabled = false
    @AppStorage("telegramBotToken") private var telegramBotToken = ""
    @AppStorage("telegramChatId") private var telegramChatId = ""
    @AppStorage("telegramEnabled") private var telegramEnabled = false

    var body: some View {
        Form {
            Section("settings.custom_notification_text") {
                HStack {
                    Text("settings.notify_text_done")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    TextField(NSLocalizedString("notification.default.done", comment: ""), text: $notifyTextDone)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .labelsHidden()
                }
                HStack {
                    Text("settings.notify_text_needs_input")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    TextField(NSLocalizedString("notification.default.needs_input", comment: ""), text: $notifyTextNeedsInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .labelsHidden()
                }
                Text("settings.custom_notification_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("macOS") {
                Toggle("settings.notify_on_complete", isOn: $notifyOnComplete)
                if notifyOnComplete && systemNotificationDenied {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text("settings.notification_denied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("settings.open_system_settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings")!)
                        }
                        .font(.caption)
                    }
                }
                SoundPicker(label: "settings.sound_done", selection: $notificationSound)
                    .disabled(!notifyOnComplete)
                SoundPicker(label: "settings.sound_needs_input", selection: $notificationSoundNeedsInput)
                    .disabled(!notifyOnComplete)
                Text("settings.custom_sound_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Slack") {
                Toggle("settings.slack_toggle", isOn: $slackEnabled)
                HStack {
                    Text("Webhook URL")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    TextField("settings.slack_url_placeholder", text: $slackWebhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .labelsHidden()
                        .disabled(!slackEnabled)
                }
                Text("settings.slack_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Discord") {
                Toggle("settings.discord_toggle", isOn: $discordEnabled)
                HStack {
                    Text("Webhook URL")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    TextField("settings.discord_url_placeholder", text: $discordWebhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .labelsHidden()
                        .disabled(!discordEnabled)
                }
                Text("settings.discord_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Telegram") {
                Toggle("settings.telegram_toggle", isOn: $telegramEnabled)
                HStack {
                    Text("Bot Token")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    TextField("settings.telegram_bot_token", text: $telegramBotToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .labelsHidden()
                        .disabled(!telegramEnabled)
                }
                HStack {
                    Text("Chat ID")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    TextField("settings.telegram_chat_id", text: $telegramChatId)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .labelsHidden()
                        .disabled(!telegramEnabled)
                }
                Text("settings.telegram_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { checkPermission() }
        .onChange(of: notifyOnComplete) { _ in checkPermission() }
    }

    private func checkPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                systemNotificationDenied = settings.authorizationStatus == .denied
            }
        }
    }
}

// MARK: - 정보

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("SwitchBoard")
                .font(.title2.bold())
            Text("credit.version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("credit.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Text("credit.supported_terminals")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Terminal · iTerm2 · Warp · VS Code · Cursor · JetBrains")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("credit.author")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            #if canImport(Sparkle)
            Divider().padding(.horizontal, 40)
            CheckForUpdatesView()
            #endif

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#if canImport(Sparkle)
private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updaterController.updater)

    var body: some View {
        Button("settings.check_for_updates") {
            updaterController.checkForUpdates(nil)
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init(updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }
}
#endif

// MARK: - 알림 사운드

private struct SoundPicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String

    var body: some View {
        Picker(label, selection: $selection) {
            Text(NSLocalizedString("settings.sound_default", comment: "")).tag("default")
            Divider()
            ForEach(NotificationSounds.system, id: \.self) { sound in
                Text(sound).tag(sound)
            }
            if !NotificationSounds.bundled.isEmpty {
                Divider()
                ForEach(NotificationSounds.bundled, id: \.self) { sound in
                    Text("★ \(NotificationSounds.displayName(sound))").tag(sound)
                }
            }
            if !NotificationSounds.custom.isEmpty {
                Divider()
                ForEach(NotificationSounds.custom, id: \.self) { sound in
                    Text("♪ \(sound)").tag(sound)
                }
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selection) { newValue in
            NotificationSounds.preview(newValue)
        }
    }
}

enum NotificationSounds {
    static let system = [
        "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Ping", "Pop",
        "Purr", "Sosumi", "Submarine", "Tink"
    ]

    static let bundled = [
        "SB_finish", "SB_dingdong", "SB_magnificent", "SB_brilliant",
        "SB_heyhey", "SB_excuseme", "SB_attention", "SB_eora"
    ]

    static var custom: [String] {
        let soundsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: soundsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { ["aiff", "wav", "caf", "mp3", "m4a"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static var all: [String] {
        var result = system + bundled
        let userSounds = custom
        if !userSounds.isEmpty { result += userSounds }
        return result
    }

    static let displayNames: [String: String] = [
        "SB_finish": "Finish!",
        "SB_dingdong": "Ding Dong",
        "SB_magnificent": "Magnificent",
        "SB_brilliant": "Brilliant",
        "SB_heyhey": "Hey Hey Hey",
        "SB_excuseme": "Excuse Me Human",
        "SB_eora": "Eora?!",
        "SB_attention": "Attention Please",
    ]

    static func displayName(_ key: String) -> String {
        displayNames[key] ?? key.replacingOccurrences(of: "SB_", with: "")
    }

    static func preview(_ name: String) {
        if name == "default" {
            NSSound.beep()
        } else if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        }
    }
}
