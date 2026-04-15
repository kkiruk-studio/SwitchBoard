import Foundation
import Combine
import SwiftUI
import UserNotifications
import AppKit

struct StatusCount: Identifiable {
    let status: SessionStatus
    let count: Int
    var id: String { status.rawValue }
}

@MainActor
final class SessionManager: ObservableObject {
    // 폴링은 세션 발견/토큰/PID 죽음 감지용 — 사용자 체감엔 영향 없으니 고정.
    let pollInterval: Double = 3.0

    @AppStorage("sortMode") var sortMode = "status"  // "status" or "custom"
    @AppStorage("notifyOnComplete") var notifyOnComplete = true
    @AppStorage("notificationSound") var notificationSound = "default"
    @AppStorage("notificationSoundNeedsInput") var notificationSoundNeedsInput = "default"
    @AppStorage("notifyTextDone") var notifyTextDone = ""
    @AppStorage("notifyTextNeedsInput") var notifyTextNeedsInput = ""
    @AppStorage("slackWebhookURL") var slackWebhookURL = ""
    @AppStorage("slackEnabled") var slackEnabled = false
    @AppStorage("discordWebhookURL") var discordWebhookURL = ""
    @AppStorage("discordEnabled") var discordEnabled = false
    @AppStorage("telegramBotToken") var telegramBotToken = ""
    @AppStorage("telegramChatId") var telegramChatId = ""
    @AppStorage("telegramEnabled") var telegramEnabled = false
    @Published var sessions: [Session] = []
    private var customOrder: [String] = [] // 사용자 정렬 순서 (PID 목록)
    private var previousStatuses: [String: SessionStatus] = [:] // 상태 전환 감지(히스토리 기록용)
    private var tokenAccumulator: [String: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cost: Double)] = [:] // 세션별 누적 토큰 + 금액
    private var lastReadOffset: [String: UInt64] = [:] // 세션별 마지막 읽은 위치
    private var ttyCache: [Int: String] = [:] // PID별 TTY 캐시 (프로세스 재실행 전까지 불변)
    // 훅이 source of truth. 한 번이라도 훅 이벤트를 받은 세션은 polling이 상태를 안 바꾼다.
    // claudeSessionId → 마지막 훅 상태
    private var hookStatus: [String: SessionStatus] = [:]

    private var timer: AnyCancellable?
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser
    private var claudeSessionsDir: URL {
        homeDir.appendingPathComponent(".claude/sessions")
    }
    private var claudeProjectsDir: URL {
        homeDir.appendingPathComponent(".claude/projects")
    }

    @Published var notificationPermissionDenied = false

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        checkNotificationPermission()
    }

    func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.notificationPermissionDenied = settings.authorizationStatus == .denied
            }
        }
    }

    func startPolling() {
        requestNotificationPermission()
        scanSessions()
        timer = Timer.publish(every: pollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.scanSessions()
            }
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    private func scanSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: claudeSessionsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else {
            sessions = []
            return
        }

        var result: [Session] = []
        var currentSessionIds = Set<String>()

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let info = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data) else { continue }

            let alive = isProcessAlive(pid: info.pid)
            let projectName = URL(fileURLWithPath: info.cwd).lastPathComponent
            let startDate = Date(timeIntervalSince1970: Double(info.startedAt) / 1000)

            // 상태 결정 우선순위:
            // 1) 프로세스 죽으면 무조건 idle
            // 2) 훅이 한 번이라도 알려준 상태가 있으면 그 값 (훅이 source of truth)
            // 3) 아직 훅 못 받은 세션은 JSONL로 부트스트랩
            let status: SessionStatus
            if !alive {
                status = .idle
            } else if let hook = hookStatus[info.sessionId] {
                status = hook
            } else {
                status = detectStatus(pid: info.pid, sessionId: info.sessionId, cwd: info.cwd)
            }

            let statusText = statusDescription(status: status)
            let tty: String
            if alive {
                if let cached = ttyCache[info.pid] {
                    tty = cached
                } else {
                    tty = getTTY(pid: info.pid)
                    if !tty.isEmpty { ttyCache[info.pid] = tty }
                }
            } else {
                tty = ""
            }
            let tokens = readTokenUsage(sessionId: info.sessionId)
            let mcpServers = MCPDetector.detect(cwd: info.cwd)
            currentSessionIds.insert(info.sessionId)

            result.append(Session(
                id: "\(info.pid)",
                name: projectName,
                status: status,
                task: statusText,
                updated: ISO8601DateFormatter().string(from: startDate),
                pid: info.pid,
                tty: tty,
                cwd: info.cwd,
                claudeSessionId: info.sessionId,
                inputTokens: tokens.input,
                outputTokens: tokens.output,
                cacheReadTokens: tokens.cacheRead,
                cacheWriteTokens: tokens.cacheWrite,
                estimatedCost: tokens.cost,
                mcpServers: mcpServers
            ))
        }

        if sortMode == "custom" && !customOrder.isEmpty {
            // 사용자 순서 유지, 새 세션은 뒤에 추가
            let orderMap = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($1, $0) })
            result.sort { lhs, rhs in
                let li = orderMap[lhs.id] ?? Int.max
                let ri = orderMap[rhs.id] ?? Int.max
                return li < ri
            }
        } else {
            // 상태별 동적 정렬
            result.sort { lhs, rhs in
                if lhs.status.sortOrder != rhs.status.sortOrder {
                    return lhs.status.sortOrder < rhs.status.sortOrder
                }
                return (lhs.updatedDate ?? .distantPast) > (rhs.updatedDate ?? .distantPast)
            }
        }
        // 상태 전환 감지 → 히스토리 기록 (알림은 훅에서만 처리)
        for session in result {
            if let prev = previousStatuses[session.id], prev != session.status {
                StatusHistory.shared.record(
                    sessionId: session.id,
                    sessionName: session.name,
                    from: prev,
                    to: session.status
                )
            }
        }
        previousStatuses = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.status) })

        // 사라진 세션의 캐시 정리
        let currentPids = Set(result.map { $0.pid })
        // 토큰 누적/오프셋은 매 폴링마다 쳐내지 않는다.
        // 세션 JSON 파일이 순간적으로 decode 실패해도 currentSessionIds에서 빠지는데,
        // 그때 누적값을 날려버리면 다음 폴링에 JSONL을 처음부터 재누적하게 되고
        // pricing 캐시/dict 매칭 타이밍에 따라 총액이 미묘하게 달라져 비용이 "오락가락"한다.
        // 엔트리당 메모리 비용이 극히 작으므로 그대로 유지한다.
        ttyCache = ttyCache.filter { currentPids.contains($0.key) }
        hookStatus = hookStatus.filter { currentSessionIds.contains($0.key) }

        sessions = result
    }

    // MARK: - Hook 기반 알림

    private var lastHookNotification: [String: Date] = [:]  // 중복 억제

    /// Claude Code 훅 CLI로부터 전달된 이벤트.
    /// - working: UserPromptSubmit
    /// - done: Stop
    /// - needs_input: Notification (단, 단순 idle 리마인더는 무시)
    func handleHookEvent(kind: String, claudeSessionId: String, cwd: String, message: String = "") {
        // Notification 훅 중 "Claude is waiting for your input" 같은 idle 리마인더는
        // 사용자가 자리를 잠깐 비웠을 뿐 액션이 필요한 게 아니므로 무시.
        if kind == "needs_input" {
            let lower = message.lowercased()
            let isIdleReminder = lower.contains("waiting for your input") || lower.isEmpty
            let isPermission = lower.contains("permission") || lower.contains("approval")
            if isIdleReminder && !isPermission { return }
        }

        let targetStatus: SessionStatus
        switch kind {
        case "working": targetStatus = .working
        case "needs_input": targetStatus = .needs_input
        default: targetStatus = .done
        }

        // 훅 상태 영구 저장 — 이후 폴링은 이 값을 그대로 사용
        if !claudeSessionId.isEmpty {
            hookStatus[claudeSessionId] = targetStatus
        }

        // working 이벤트는 알림/웹훅 안 보냄 (대시보드만 갱신)
        if targetStatus == .working {
            updateSessionStatusInPlace(claudeSessionId: claudeSessionId, cwd: cwd, status: targetStatus)
            return
        }

        // 동일 세션에 대해 3초 내 중복 이벤트는 무시 (Stop + SubagentStop 중첩 대비)
        let dedupeKey = "\(claudeSessionId)|\(kind)"
        if let last = lastHookNotification[dedupeKey], Date().timeIntervalSince(last) < 3 {
            updateSessionStatusInPlace(claudeSessionId: claudeSessionId, cwd: cwd, status: targetStatus)
            return
        }
        lastHookNotification[dedupeKey] = Date()

        let sessionForNotification = updateSessionStatusInPlace(
            claudeSessionId: claudeSessionId, cwd: cwd, status: targetStatus
        ) ?? Session(
            id: claudeSessionId,
            name: cwd.isEmpty ? "Claude" : URL(fileURLWithPath: cwd).lastPathComponent,
            status: targetStatus,
            task: "",
            updated: ISO8601DateFormatter().string(from: Date()),
            pid: 0,
            tty: "",
            cwd: cwd,
            claudeSessionId: claudeSessionId
        )

        sendCompletionNotification(session: sessionForNotification)
    }

    /// 세션 배열에서 매칭되는 세션의 status만 갱신한다. 매칭 실패 시 nil.
    @discardableResult
    private func updateSessionStatusInPlace(
        claudeSessionId: String, cwd: String, status: SessionStatus
    ) -> Session? {
        let idx = sessions.firstIndex { $0.claudeSessionId == claudeSessionId }
            ?? sessions.firstIndex { !cwd.isEmpty && $0.cwd == cwd }
        guard let idx = idx else { return nil }
        let m = sessions[idx]
        sessions[idx] = Session(
            id: m.id, name: m.name, status: status, task: m.task, updated: m.updated,
            pid: m.pid, tty: m.tty, cwd: m.cwd, claudeSessionId: m.claudeSessionId,
            inputTokens: m.inputTokens, outputTokens: m.outputTokens,
            cacheReadTokens: m.cacheReadTokens, cacheWriteTokens: m.cacheWriteTokens,
            estimatedCost: m.estimatedCost, mcpServers: m.mcpServers
        )
        return sessions[idx]
    }

    private func sendCompletionNotification(session: Session) {
        // 알림 문구 생성 (macOS + 웹훅 공용)
        let defaultText: String
        switch session.status {
        case .done:
            defaultText = NSLocalizedString("notification.default.done", comment: "")
        case .needs_input:
            defaultText = NSLocalizedString("notification.default.needs_input", comment: "")
        default:
            defaultText = session.status.label
        }
        let bodyText: String = {
            switch session.status {
            case .done: return notifyTextDone.isEmpty ? defaultText : notifyTextDone
            case .needs_input: return notifyTextNeedsInput.isEmpty ? defaultText : notifyTextNeedsInput
            default: return defaultText
            }
        }()

        // macOS 로컬 알림
        if notifyOnComplete {
            let content = UNMutableNotificationContent()
            content.title = session.name
            content.body = bodyText
            let soundName = session.status == .needs_input ? notificationSoundNeedsInput : notificationSound
            if soundName == "default" {
                content.sound = .default
            } else {
                // UNNotificationSound가 앱 번들 내 커스텀 사운드를 못 찾고 기본 사운드로 폴백하는
                // 경우가 있어, 알림은 무음으로 보내고 NSSound로 직접 재생한다.
                content.sound = nil
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                }
            }
            let request = UNNotificationRequest(
                identifier: "session-\(session.id)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        // 웹훅 알림
        let webhookMessage = "[\(session.name)] \(bodyText)"
        if slackEnabled { sendSlackWebhook(message: webhookMessage) }
        if discordEnabled { sendDiscordWebhook(message: webhookMessage) }
        if telegramEnabled { sendTelegramMessage(message: webhookMessage) }
    }

    // MARK: - Webhooks

    private func sendSlackWebhook(message: String) {
        guard let url = URL(string: slackWebhookURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": "🔔 \(message)"])
        URLSession.shared.dataTask(with: request).resume()
    }

    private func sendDiscordWebhook(message: String) {
        guard let url = URL(string: discordWebhookURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": "🔔 \(message)"])
        URLSession.shared.dataTask(with: request).resume()
    }

    private func sendTelegramMessage(message: String) {
        guard !telegramBotToken.isEmpty, !telegramChatId.isEmpty,
              let url = URL(string: "https://api.telegram.org/bot\(telegramBotToken)/sendMessage") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": telegramChatId,
            "text": "🔔 \(message)"
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    private func detectStatus(pid: Int, sessionId: String, cwd: String) -> SessionStatus {
        let lastMessage = readLastMessages(sessionId: sessionId, cwd: cwd)

        // 명확한 신호는 즉시 결정 (질문 패턴 휴리스틱 없음 — needs_input은 훅에서만)
        switch lastMessage {
        case .turnEnd:
            return .done
        case .toolUse, .userMessage, .progress:
            return .working
        case .assistantText, .unknown:
            // 모호한 케이스 — mtime/CPU로 추가 판정 (아래로 fall-through)
            break
        }

        // JSONL mtime: 최근에 써졌으면 아직 작업 중
        var jsonlAge: TimeInterval = .infinity
        if let path = findJsonlFile(sessionId: sessionId),
           let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let mtime = attrs[.modificationDate] as? Date {
            jsonlAge = Date().timeIntervalSince(mtime)
        }
        if jsonlAge < pollInterval + 3 { return .working }
        if jsonlAge < 30, getCPUUsage(pid: pid) > 5 { return .working }

        // 파일이 6초 이상 조용하고 명시적 working 신호도 없음
        // → 사실상 종료된 턴 (turn_duration/away_summary가 64KB tail 너머에 있는 경우 포함)
        return .done
    }

    private enum LastMessageType {
        case assistantText(String) // 마지막 텍스트 내용
        case toolUse
        case turnEnd
        case userMessage
        case progress  // 작업 진행 중
        case unknown
    }

    private func readLastMessages(sessionId: String, cwd: String) -> LastMessageType {
        // Claude Code는 경로의 /, _, 공백 등을 모두 -로 변환
        guard let jsonlPath = findJsonlFile(sessionId: sessionId),
              let fileHandle = try? FileHandle(forReadingFrom: jsonlPath) else {
            return .unknown
        }
        defer { fileHandle.closeFile() }

        // 파일 끝에서 마지막 몇 줄 읽기
        let fileSize = fileHandle.seekToEndOfFile()
        // file-history-snapshot 이벤트는 파일 내용을 통째로 담아 수십 KB가 될 수 있어
        // 8KB로는 의미 있는 assistant/user/turn_duration 이벤트가 가려질 수 있다.
        let readSize: UInt64 = min(fileSize, 65536)
        fileHandle.seek(toFileOffset: fileSize - readSize)
        let data = fileHandle.availableData
        guard let text = String(data: data, encoding: .utf8) else { return .unknown }

        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        // 뒤에서부터 의미 있는 메시지 찾기
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            // 턴 종료 신호: turn_duration(정상 종료), stop_hook_summary(Stop 훅 발사),
            // away_summary(Claude 자리비움). 모두 "이 시점 이후 추가 작업 없음"을 의미.
            if type == "system",
               let subtype = json["subtype"] as? String,
               subtype == "turn_duration" || subtype == "stop_hook_summary" || subtype == "away_summary" {
                return .turnEnd
            }

            if type == "assistant" {
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    // 마지막 블록이 tool_use인지 확인
                    if let lastBlock = content.last,
                       let blockType = lastBlock["type"] as? String,
                       blockType == "tool_use" {
                        return .toolUse
                    }
                    // 모든 텍스트 블록을 합쳐서 반환
                    let fullText = content.compactMap { block -> String? in
                        if block["type"] as? String == "text" {
                            return block["text"] as? String
                        }
                        return nil
                    }.joined(separator: "\n")
                    return .assistantText(fullText)
                }
                return .assistantText("")
            }

            if type == "user" {
                return .userMessage
            }

            // progress = 확실히 작업 중
            if type == "progress" {
                return .progress
            }

            // file-history-snapshot 등은 건너뜀
            if type == "file-history-snapshot" {
                continue
            }
        }

        return .unknown
    }

    private func getCPUUsage(pid: Int) -> Double {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "%cpu="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let cpu = Double(str) {
                return cpu
            }
        } catch {}
        return 0
    }

    private func findJsonlFile(sessionId: String) -> URL? {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func getTTY(pid: Int) -> String {
        // claude의 부모(zsh)의 tty를 가져옴
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "ppid="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let ppidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let ppid = Int(ppidStr) else { return "" }

            let pipe2 = Pipe()
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/bin/ps")
            process2.arguments = ["-p", "\(ppid)", "-o", "tty="]
            process2.standardOutput = pipe2
            process2.standardError = FileHandle.nullDevice
            try process2.run()
            process2.waitUntilExit()
            let data2 = pipe2.fileHandleForReading.readDataToEndOfFile()
            if let tty = String(data: data2, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty {
                return "/dev/\(tty)"
            }
        } catch {}
        return ""
    }

    func terminateSession(_ session: Session) {
        guard session.status != .idle else { return }
        kill(pid_t(session.pid), SIGTERM)
        // 다음 폴링에서 상태 반영됨
    }

    func focusTerminal(session: Session) {
        guard !session.tty.isEmpty else { return }

        // 터미널 앱 감지: pid의 최상위 부모 프로세스 이름으로 판단
        let terminalApp = detectTerminalApp(pid: session.pid)

        switch terminalApp {
        case "iTerm2":
            runAppleScript("""
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is "\(session.tty)" then
                                select t
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        case "Warp":
            runAppleScript("""
            tell application "Warp" to activate
            """)
        case "VS Code":
            runAppleScript("""
            tell application "Visual Studio Code" to activate
            """)
        case "Cursor":
            runAppleScript("""
            tell application "Cursor" to activate
            """)
        case "JetBrains":
            // JetBrains IDE는 번들 이름이 다양하므로 프로세스 이름으로 활성화
            if let appName = detectJetBrainsAppName(pid: session.pid) {
                runAppleScript("""
                tell application "\(appName)" to activate
                """)
            }
        default:
            runAppleScript("""
            tell application "Terminal"
                set targetTTY to "\(session.tty)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is targetTTY then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)
        }
    }

    private func detectTerminalApp(pid: Int) -> String {
        // pid → ppid → ppid ... 최상위 앱 이름 찾기
        var currentPid = pid
        for _ in 0..<10 {
            let ppid = getParentPid(currentPid)
            if ppid <= 1 { break }
            let name = getProcessName(ppid)
            if name.contains("iTerm") { return "iTerm2" }
            if name.contains("Warp") { return "Warp" }
            if name.contains("Cursor") { return "Cursor" }
            if name.contains("Electron") || name.contains("Code") { return "VS Code" }
            if name.contains("idea") || name.contains("webstorm") || name.contains("pycharm") ||
               name.contains("goland") || name.contains("rider") || name.contains("clion") ||
               name.contains("phpstorm") || name.contains("rubymine") || name.contains("datagrip") {
                return "JetBrains"
            }
            if name.contains("Terminal") { return "Terminal" }
            currentPid = ppid
        }
        return "Terminal"
    }

    private func detectJetBrainsAppName(pid: Int) -> String? {
        var currentPid = pid
        for _ in 0..<10 {
            let ppid = getParentPid(currentPid)
            if ppid <= 1 { break }
            let name = getProcessName(ppid).lowercased()
            let mapping: [(String, String)] = [
                ("idea", "IntelliJ IDEA"), ("webstorm", "WebStorm"),
                ("pycharm", "PyCharm"), ("goland", "GoLand"),
                ("rider", "Rider"), ("clion", "CLion"),
                ("phpstorm", "PhpStorm"), ("rubymine", "RubyMine"),
                ("datagrip", "DataGrip"),
            ]
            for (key, appName) in mapping {
                if name.contains(key) { return appName }
            }
            currentPid = ppid
        }
        return nil
    }

    private func getParentPid(_ pid: Int) -> Int {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "ppid="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let ppid = Int(str) { return ppid }
        } catch {}
        return 0
    }

    private func getProcessName(_ pid: Int) -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {}
        return ""
    }

    private func readTokenUsage(sessionId: String) -> (input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cost: Double) {
        let empty: (Int, Int, Int, Int, Double) = (0, 0, 0, 0, 0)
        guard let jsonlPath = findJsonlFile(sessionId: sessionId),
              let fileHandle = try? FileHandle(forReadingFrom: jsonlPath) else {
            return tokenAccumulator[sessionId] ?? empty
        }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        let offset = lastReadOffset[sessionId] ?? 0

        if fileSize <= offset {
            return tokenAccumulator[sessionId] ?? empty
        }

        fileHandle.seek(toFileOffset: offset)
        let data = fileHandle.availableData
        guard let text = String(data: data, encoding: .utf8) else {
            return tokenAccumulator[sessionId] ?? empty
        }

        var accumulated = tokenAccumulator[sessionId] ?? empty
        let lines = text.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let model = message["model"] as? String
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0

            accumulated.0 += input
            accumulated.1 += output
            accumulated.2 += cacheRead
            accumulated.3 += cacheWrite
            accumulated.4 += PricingTable.cost(
                model: model,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite
            )
        }

        tokenAccumulator[sessionId] = accumulated
        lastReadOffset[sessionId] = fileSize
        return accumulated
    }

    private func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func isProcessAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }

    private func statusDescription(status: SessionStatus) -> String {
        switch status {
        case .working: return NSLocalizedString("status.desc.working", comment: "")
        case .needs_input: return NSLocalizedString("status.desc.needs_input", comment: "")
        case .done: return NSLocalizedString("status.desc.done", comment: "")
        case .idle: return NSLocalizedString("status.desc.idle", comment: "")
        }
    }

    func saveCustomOrder() {
        customOrder = sessions.map { $0.id }
    }

    var hasNeedsInput: Bool {
        sessions.contains { $0.status == .needs_input }
    }

    var hasWorking: Bool {
        sessions.contains { $0.status == .working }
    }

    var allDoneOrIdle: Bool {
        !sessions.isEmpty && sessions.allSatisfy { $0.status == .done || $0.status == .idle }
    }

    func statusCounts() -> [StatusCount] {
        let grouped = Dictionary(grouping: sessions, by: { $0.status })
        return grouped.map { StatusCount(status: $0.key, count: $0.value.count) }
            .sorted { $0.status.sortOrder < $1.status.sortOrder }
    }
}

private struct ClaudeSessionFile: Codable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Int
}
