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
    @AppStorage("slackWebhookURL") var slackWebhookURL = ""
    @AppStorage("slackEnabled") var slackEnabled = false
    @AppStorage("discordWebhookURL") var discordWebhookURL = ""
    @AppStorage("discordEnabled") var discordEnabled = false
    @AppStorage("telegramBotToken") var telegramBotToken = ""
    @AppStorage("telegramChatId") var telegramChatId = ""
    @AppStorage("telegramEnabled") var telegramEnabled = false
    @Published var sessions: [Session] = []
    @Published var isConnected = true
    private var customOrder: [String] = [] // 사용자 정렬 순서 (PID 목록)
    private var previousStatuses: [String: SessionStatus] = [:] // 이전 상태 추적
    private var tokenAccumulator: [String: (input: Int, output: Int)] = [:] // 세션별 누적 토큰
    private var lastReadOffset: [String: UInt64] = [:] // 세션별 마지막 읽은 위치

    private var timer: AnyCancellable?
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser
    private var claudeSessionsDir: URL {
        homeDir.appendingPathComponent(".claude/sessions")
    }
    private var claudeProjectsDir: URL {
        homeDir.appendingPathComponent(".claude/projects")
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
            let tty = alive ? getTTY(pid: info.pid) : ""
            let tokens = readTokenUsage(sessionId: info.sessionId)

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
            if let prev = previousStatuses[session.id], prev != session.status {
                StatusHistory.shared.record(
                    sessionId: session.id,
                    sessionName: session.name,
                    from: prev,
                    to: session.status
                )
                if notifyOnComplete && prev == .working &&
                    (session.status == .done || session.status == .needs_input || session.status == .needs_confirm) {
                    sendCompletionNotification(session: session)
                }
            }
        }
        previousStatuses = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.status) })


        sessions = result
    }

    private func sendCompletionNotification(session: Session) {
        // macOS 로컬 알림
        let content = UNMutableNotificationContent()
        content.title = session.name
        content.body = session.task
        content.sound = .default
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
        // 1) JSONL에서 마지막 메시지 타입 확인
        let lastMessage = readLastMessages(sessionId: sessionId, cwd: cwd)

        // 2) CPU 사용량 확인
        let cpuUsage = getCPUUsage(pid: pid)

        // CPU가 높으면 작업 중
        if cpuUsage > 10 {
            return .working
        }

        // JSONL 기반 판단
        switch lastMessage {
        case .toolUse:
            return .needs_confirm  // 도구 승인 대기
        case .assistantText:
            return .needs_input    // 응답 완료, 사용자 입력 대기
        case .turnEnd:
            return .done           // 턴 완료
        case .userMessage:
            return .working        // 사용자 메시지 후 처리 중
        case .unknown:
            return .needs_input
        }
    }

    private enum LastMessageType {
        case assistantText
        case toolUse
        case turnEnd
        case userMessage
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
                   let content = message["content"] as? [[String: Any]],
                   let lastBlock = content.last,
                   let blockType = lastBlock["type"] as? String {
                    if blockType == "tool_use" {
                        return .toolUse
                    }
                    return .assistantText
                }
                return .assistantText
            }

            if type == "user" {
                return .userMessage
            }

            // progress, file-history-snapshot 등은 건너뜀
            if type == "progress" || type == "file-history-snapshot" {
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
            // Warp는 AppleScript 미지원 — 앱 활성화만
            runAppleScript("""
            tell application "Warp" to activate
            """)
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
        for _ in 0..<5 {
            let ppid = getParentPid(currentPid)
            if ppid <= 1 { break }
            let name = getProcessName(ppid)
            if name.contains("iTerm") { return "iTerm2" }
            if name.contains("Warp") { return "Warp" }
            if name.contains("Terminal") { return "Terminal" }
            currentPid = ppid
        }
        return "Terminal"
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
        case .needs_confirm: return NSLocalizedString("status.desc.needs_confirm", comment: "")
        case .done: return NSLocalizedString("status.desc.done", comment: "")
        case .idle: return NSLocalizedString("status.desc.idle", comment: "")
        }
    }

    func saveCustomOrder() {
        customOrder = sessions.map { $0.id }
    }

    var hasNeedsInput: Bool {
        sessions.contains { $0.status == .needs_input || $0.status == .needs_confirm }
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
