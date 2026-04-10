import Foundation
import Combine
import SwiftUI
import UserNotifications

struct StatusCount: Identifiable {
    let status: SessionStatus
    let count: Int
    var id: String { status.rawValue }
}

@MainActor
final class SessionManager: ObservableObject {
    @AppStorage("pollInterval") var pollInterval = 3.0 {
        didSet { restartPolling() }
    }

    @AppStorage("sortMode") var sortMode = "status"  // "status" or "custom"
    @AppStorage("notifyOnComplete") var notifyOnComplete = true
    @AppStorage("notificationSound") var notificationSound = "default"
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
    private var previousStatuses: [String: SessionStatus] = [:] // 이전 상태 추적
    private var notifiedSessions: Set<String> = [] // 알림 중복 방지
    private var workingCount: [String: Int] = [:] // working 연속 횟수
    private var previousWorkingCount: [String: Int] = [:] // 직전 폴링까지의 working 횟수
    private var tokenAccumulator: [String: (input: Int, output: Int)] = [:] // 세션별 누적 토큰
    private var lastReadOffset: [String: UInt64] = [:] // 세션별 마지막 읽은 위치
    private var ttyCache: [Int: String] = [:] // PID별 TTY 캐시 (프로세스 재실행 전까지 불변)

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

    func restartPolling() {
        stopPolling()
        startPolling()
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

            let status: SessionStatus
            if !alive {
                status = .idle
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
            currentSessionIds.insert(info.sessionId)

            result.append(Session(
                id: "\(info.pid)",
                name: projectName,
                status: status,
                task: statusText,
                updated: ISO8601DateFormatter().string(from: startDate),
                pid: info.pid,
                tty: tty,
                inputTokens: tokens.input,
                outputTokens: tokens.output
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
        // 상태 전환 감지 → 히스토리 기록 + 알림
        for session in result {
            let prev = previousStatuses[session.id]
            if session.status == .working {
                workingCount[session.id, default: 0] += 1
            } else {
                workingCount[session.id] = 0
            }
            // idle → working 전환 시에만 알림 이력 리셋 (새 작업 시작)
            if prev == .idle && session.status == .working {
                notifiedSessions.remove(session.id)
            }
            if let prev = prev, prev != session.status {
                StatusHistory.shared.record(
                    sessionId: session.id,
                    sessionName: session.name,
                    from: prev,
                    to: session.status
                )
                // working이 3회 이상 연속 감지된 후 완료 전환 시에만 알림 (순간적 오감지 무시)
                let wasReallyWorking = workingCount[session.id, default: 0] == 0 &&
                    (previousWorkingCount[session.id, default: 0] >= 3)
                if notifyOnComplete &&
                    (prev == .working) &&
                    (session.status == .done || session.status == .needs_input) &&
                    wasReallyWorking &&
                    !notifiedSessions.contains(session.id) {
                    notifiedSessions.insert(session.id)
                    sendCompletionNotification(session: session)
                }
            }
            previousWorkingCount[session.id] = workingCount[session.id, default: 0]
        }
        previousStatuses = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.status) })

        // 사라진 세션의 캐시 정리 (메모리 누수 방지)
        let currentIds = Set(result.map { $0.id })
        let currentPids = Set(result.map { $0.pid })
        notifiedSessions = notifiedSessions.intersection(currentIds)
        workingCount = workingCount.filter { currentIds.contains($0.key) }
        previousWorkingCount = previousWorkingCount.filter { currentIds.contains($0.key) }
        previousStatuses = previousStatuses.filter { currentIds.contains($0.key) }
        tokenAccumulator = tokenAccumulator.filter { currentSessionIds.contains($0.key) }
        lastReadOffset = lastReadOffset.filter { currentSessionIds.contains($0.key) }
        ttyCache = ttyCache.filter { currentPids.contains($0.key) }

        sessions = result
    }

    private func sendCompletionNotification(session: Session) {
        // macOS 로컬 알림
        let content = UNMutableNotificationContent()
        content.title = session.name
        let defaultText: String
        switch session.status {
        case .done:
            defaultText = NSLocalizedString("notification.default.done", comment: "")
        case .needs_input:
            defaultText = NSLocalizedString("notification.default.needs_input", comment: "")
        default:
            defaultText = session.status.label
        }
        content.body = {
            switch session.status {
            case .done: return notifyTextDone.isEmpty ? defaultText : notifyTextDone
            case .needs_input: return notifyTextNeedsInput.isEmpty ? defaultText : notifyTextNeedsInput
            default: return defaultText
            }
        }()
        if notificationSound == "default" {
            content.sound = .default
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("\(notificationSound).aiff"))
        }
        let request = UNNotificationRequest(
            identifier: "session-\(session.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)

        // 웹훅 알림
        let message = "[\(session.name)] \(session.task)"
        if slackEnabled { sendSlackWebhook(message: message) }
        if discordEnabled { sendDiscordWebhook(message: message) }
        if telegramEnabled { sendTelegramMessage(message: message) }
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
        // 1) JSONL 파일 수정시간 확인
        var jsonlAge: TimeInterval = .infinity
        if let jsonlPath = findJsonlFile(sessionId: sessionId),
           let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath.path),
           let modDate = attrs[.modificationDate] as? Date {
            jsonlAge = Date().timeIntervalSince(modDate)
            if jsonlAge < pollInterval + 3 {
                return .working
            }
        }

        // 2) CPU 체크는 파일이 최근(30초 이내)이면서 working 의심될 때만
        // (오래 조용한 세션은 CPU 체크 스킵 → Process spawn 비용 절약)
        if jsonlAge < 30, getCPUUsage(pid: pid) > 5 {
            return .working
        }

        // 3) JSONL 마지막 메시지로 최종 상태 판단
        let lastMessage = readLastMessages(sessionId: sessionId, cwd: cwd)
        switch lastMessage {
        case .progress, .toolUse, .userMessage:
            return .working
        case .assistantText(let text):
            return looksLikeWaitingForInput(text) ? .needs_input : .done
        case .turnEnd:
            return .done
        case .unknown:
            return .done
        }
    }

    private func looksLikeWaitingForInput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 물음표로 끝나면 입력 대기
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return true }
        // 번호 옵션 패턴 (1. 또는 1) 등)
        let lines = trimmed.components(separatedBy: "\n").suffix(6)
        var numberedCount = 0
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(l.startIndex..., in: l)
            if Self.numberedOptionRegex.firstMatch(in: l, range: range) != nil {
                numberedCount += 1
            }
        }
        if numberedCount >= 2 { return true }
        return false
    }

    private static let numberedOptionRegex = try! NSRegularExpression(pattern: #"^\d+[\.\)]\s"#)

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
        let readSize: UInt64 = min(fileSize, 8192)
        fileHandle.seek(toFileOffset: fileSize - readSize)
        guard let data = try? fileHandle.availableData,
              let text = String(data: data, encoding: .utf8) else {
            return .unknown
        }

        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        // 뒤에서부터 의미 있는 메시지 찾기
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "system", let subtype = json["subtype"] as? String, subtype == "turn_duration" {
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

    private func readTokenUsage(sessionId: String) -> (input: Int, output: Int) {
        guard let jsonlPath = findJsonlFile(sessionId: sessionId),
              let fileHandle = try? FileHandle(forReadingFrom: jsonlPath) else {
            return tokenAccumulator[sessionId] ?? (0, 0)
        }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        let offset = lastReadOffset[sessionId] ?? 0

        // 새로 추가된 내용이 없으면 기존 누적값 반환
        if fileSize <= offset {
            return tokenAccumulator[sessionId] ?? (0, 0)
        }

        // 마지막 읽은 위치부터 새 줄만 읽기
        fileHandle.seek(toFileOffset: offset)
        guard let data = try? fileHandle.availableData,
              let text = String(data: data, encoding: .utf8) else {
            return tokenAccumulator[sessionId] ?? (0, 0)
        }

        var accumulated = tokenAccumulator[sessionId] ?? (0, 0)
        let lines = text.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                if let input = usage["input_tokens"] as? Int { accumulated.input += input }
                if let output = usage["output_tokens"] as? Int { accumulated.output += output }
            }
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
