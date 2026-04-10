import Foundation
import SwiftUI

// MARK: - 상태 히스토리

struct StatusHistoryEntry: Codable, Identifiable {
    let id: UUID
    let sessionId: String
    let sessionName: String
    let fromStatus: String
    let toStatus: String
    let timestamp: Date

    init(sessionId: String, sessionName: String, from: SessionStatus, to: SessionStatus) {
        self.id = UUID()
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.fromStatus = from.rawValue
        self.toStatus = to.rawValue
        self.timestamp = Date()
    }
}

@MainActor
final class StatusHistory: ObservableObject {
    static let shared = StatusHistory()
    @Published var entries: [StatusHistoryEntry] = []
    private let maxEntries = 200
    private let storageKey = "statusHistory"

    private init() { load() }

    func record(sessionId: String, sessionName: String, from: SessionStatus, to: SessionStatus) {
        let entry = StatusHistoryEntry(sessionId: sessionId, sessionName: sessionName, from: from, to: to)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([StatusHistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

struct Session: Identifiable {
    let id: String
    let name: String
    let status: SessionStatus
    let task: String
    let updated: String
    let pid: Int
    let tty: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    var tokenSummary: String {
        if inputTokens == 0 && outputTokens == 0 { return "" }
        let total = inputTokens + outputTokens
        if total >= 1_000_000 { return String(format: "%.1fM", Double(total) / 1_000_000.0) }
        if total >= 1_000 { return String(format: "%.1fK", Double(total) / 1_000.0) }
        return "\(total)"
    }

    var memo: String {
        get { UserDefaults.standard.string(forKey: "memo_\(id)") ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "memo_\(id)") }
    }

    var updatedDate: Date? {
        ISO8601DateFormatter().date(from: updated)
    }

    var relativeTime: String {
        guard let date = updatedDate else { return "" }
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        if minutes < 1 { return NSLocalizedString("dashboard.just_now", comment: "") }
        if minutes < 60 { return String(format: NSLocalizedString("dashboard.minutes_ago", comment: ""), minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: NSLocalizedString("dashboard.hours_ago", comment: ""), hours) }
        return String(format: NSLocalizedString("dashboard.days_ago", comment: ""), hours / 24)
    }

    var elapsedTime: String {
        guard let date = updatedDate else { return "" }
        let totalSeconds = Int(-date.timeIntervalSinceNow)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, totalSeconds % 60)
        }
        return String(format: "%d:%02d", minutes, totalSeconds % 60)
    }
}

enum SessionStatus: String {
    case working
    case needs_input
    case done
    case idle

    var sortOrder: Int {
        switch self {
        case .needs_input: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        }
    }

    var label: String {
        NSLocalizedString("status.\(rawValue)", comment: "")
    }

    var icon: String {
        switch self {
        case .working: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        case .needs_input: return "keyboard"
        case .idle: return "moon.fill"
        }
    }

    var color: Color {
        switch self {
        case .working: return .blue
        case .done: return .green
        case .needs_input: return .orange
        case .idle: return .gray
        }
    }
}
