import SwiftUI
import ServiceManagement

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
        .frame(width: 400, height: 340)
    }
}

// MARK: - 일반

private struct GeneralTab: View {
    @AppStorage("pollInterval") private var pollInterval = 3.0
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
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
    @AppStorage("slackWebhookURL") private var slackWebhookURL = ""
    @AppStorage("slackEnabled") private var slackEnabled = false
    @AppStorage("discordWebhookURL") private var discordWebhookURL = ""
    @AppStorage("discordEnabled") private var discordEnabled = false
    @AppStorage("telegramBotToken") private var telegramBotToken = ""
    @AppStorage("telegramChatId") private var telegramChatId = ""
    @AppStorage("telegramEnabled") private var telegramEnabled = false

    var body: some View {
        Form {
            Toggle("settings.notify_on_complete", isOn: $notifyOnComplete)


            DisclosureGroup("Slack") {
                Toggle("settings.slack_toggle", isOn: $slackEnabled)
                TextField("settings.slack_url_placeholder", text: $slackWebhookURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(!slackEnabled)
                Text("settings.slack_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Discord") {
                Toggle("settings.discord_toggle", isOn: $discordEnabled)
                TextField("settings.discord_url_placeholder", text: $discordWebhookURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(!discordEnabled)
                Text("settings.discord_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Telegram") {
                Toggle("settings.telegram_toggle", isOn: $telegramEnabled)
                TextField("settings.telegram_bot_token", text: $telegramBotToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(!telegramEnabled)
                TextField("settings.telegram_chat_id", text: $telegramChatId)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(!telegramEnabled)
                Text("settings.telegram_help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
            Text("Switchboard")
                .font(.title2.bold())
            Text("credit.version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("credit.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("credit.author")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
