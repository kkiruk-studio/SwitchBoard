import SwiftUI

enum ViewMode: String {
    case grid, list
}

struct DashboardView: View {
    @ObservedObject var sessionManager: SessionManager
    @AppStorage("viewMode") private var viewMode: String = ViewMode.grid.rawValue
    @State private var currentTime = Date()
    @State private var draggingId: String?
    @State private var searchText = ""
    @State private var showHistory = false

    private var filteredSessions: [Session] {
        if searchText.isEmpty { return sessionManager.sessions }
        return sessionManager.sessions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.memo.localizedCaseInsensitiveContains(searchText)
        }
    }

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: .infinity), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if sessionManager.sessions.count >= 4 {
                searchBar
            }
            Divider()
            content
            Divider()
            footer
        }
        .onReceive(clockTimer) { currentTime = $0 }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("SwitchBoard")
                .font(.headline)
                .fixedSize()

            // 정렬 토글
            Button {
                sessionManager.sortMode = sessionManager.sortMode == "status" ? "custom" : "status"
                if sessionManager.sortMode == "custom" {
                    sessionManager.saveCustomOrder()
                }
            } label: {
                let isCustom = sessionManager.sortMode == "custom"
                HStack(spacing: 3) {
                    Image(systemName: isCustom ? "hand.draw" : "arrow.up.arrow.down")
                        .font(.caption2)
                    Text(isCustom
                         ? NSLocalizedString("sort.custom", comment: "")
                         : NSLocalizedString("sort.status", comment: ""))
                        .font(.caption2)
                }
                .foregroundStyle(isCustom ? .blue : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isCustom ? Color.blue.opacity(0.1) : Color.clear)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("dashboard.history")

            Picker("", selection: Binding(
                get: { viewMode },
                set: { viewMode = $0 }
            )) {
                Image(systemName: "circle.grid.2x2")
                    .tag(ViewMode.grid.rawValue)
                Image(systemName: "list.bullet")
                    .tag(ViewMode.list.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 70)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("dashboard.search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if filteredSessions.isEmpty {
            emptyView
        } else if viewMode == ViewMode.grid.rawValue {
            gridView
        } else {
            listView
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("dashboard.empty")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Grid

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(filteredSessions) { session in
                    SessionTileView(session: session, onTerminate: { sessionManager.terminateSession(session) })
                        .onTapGesture { sessionManager.focusTerminal(session: session) }
                        .opacity(draggingId == session.id ? 0.4 : 1)
                        .onDrag {
                            draggingId = session.id
                            sessionManager.sortMode = "custom"
                            return NSItemProvider(object: session.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: TileDropDelegate(
                            targetId: session.id,
                            draggingId: $draggingId,
                            sessions: $sessionManager.sessions,
                            onReorder: { sessionManager.saveCustomOrder() }
                        ))
                }
            }
            .padding(12)
        }
    }

    // MARK: - List

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filteredSessions) { session in
                    SessionRowView(session: session, onTerminate: { sessionManager.terminateSession(session) })
                        .onTapGesture { sessionManager.focusTerminal(session: session) }
                        .opacity(draggingId == session.id ? 0.4 : 1)
                        .onDrag {
                            draggingId = session.id
                            sessionManager.sortMode = "custom"
                            return NSItemProvider(object: session.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: TileDropDelegate(
                            targetId: session.id,
                            draggingId: $draggingId,
                            sessions: $sessionManager.sessions,
                            onReorder: { sessionManager.saveCustomOrder() }
                        ))
                }
            }
            .padding(12)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            let active = sessionManager.sessions.filter { $0.status == .working }.count
            let total = sessionManager.sessions.count
            Text(String(format: NSLocalizedString("dashboard.active_count", comment: ""), active, total))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(currentTime, format: .dateTime.hour().minute().second())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            if #available(macOS 14.0, *) {
                SettingsLink {
                    Image(systemName: "gear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Grid Tile

struct SessionTileView: View {
    let session: Session
    var onTerminate: (() -> Void)?
    @State private var isEditingMemo = false
    @State private var memoText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 상태 아이콘 + 라벨
            HStack(spacing: 4) {
                Image(systemName: session.status.icon)
                    .font(.caption2)
                    .foregroundStyle(session.status.color)
                Text(session.status.label)
                    .font(.caption2)
                    .foregroundStyle(session.status.color)
                Spacer()
            }

            // 프로젝트 이름
            Text(session.name)
                .font(.system(.subheadline, weight: .bold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // 메모
            if isEditingMemo {
                TextField("session.memo_placeholder", text: $memoText, onCommit: {
                    session.memo = memoText
                    isEditingMemo = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
                .onExitCommand { isEditingMemo = false }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: session.memo.isEmpty ? "plus.bubble" : "note.text")
                        .font(.caption2)
                        .foregroundStyle(session.memo.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                    Text(session.memo.isEmpty
                         ? NSLocalizedString("session.memo_placeholder", comment: "")
                         : session.memo)
                        .font(.caption2)
                        .foregroundStyle(session.memo.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                        .lineLimit(1)
                }
                .onTapGesture {
                    memoText = session.memo
                    isEditingMemo = true
                }
            }

            Spacer(minLength: 0)

            // 토큰
            if !session.tokenSummary.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "flame")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(session.tokenSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // 시간
            HStack {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(session.elapsedTime)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(session.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear { memoText = session.memo }
        .contextMenu {
            Button(session.memo.isEmpty ? "session.add_memo" : "session.edit_memo") {
                memoText = session.memo
                isEditingMemo = true
            }
            if !session.memo.isEmpty {
                Button("session.delete_memo", role: .destructive) {
                    session.memo = ""
                    memoText = ""
                }
            }
            if session.status != .idle, let onTerminate {
                Divider()
                Button("session.terminate", role: .destructive) {
                    onTerminate()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 85, alignment: .topLeading)
        .background(tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tileBorderColor, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }

    private var tileBackground: some View {
        Group {
            switch session.status {
            case .working: Color.blue.opacity(0.08)
            case .needs_input: Color.orange.opacity(0.08)
            case .done: Color.green.opacity(0.06)
            case .idle: Color.primary.opacity(0.03)
            }
        }
    }

    private var tileBorderColor: Color {
        switch session.status {
        case .working: return .blue.opacity(0.3)
        case .needs_input: return .orange.opacity(0.3)
        case .done: return .green.opacity(0.2)
        case .idle: return .clear
        }
    }
}

// MARK: - List Row

struct SessionRowView: View {
    let session: Session
    var onTerminate: (() -> Void)?
    @State private var isEditingMemo = false
    @State private var memoText = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.status.icon)
                .font(.caption)
                .foregroundStyle(session.status.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                if isEditingMemo {
                    TextField("session.memo_placeholder", text: $memoText, onCommit: {
                        session.memo = memoText
                        isEditingMemo = false
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .onExitCommand { isEditingMemo = false }
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: session.memo.isEmpty ? "plus.bubble" : "note.text")
                            .font(.caption2)
                            .foregroundStyle(session.memo.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                        Text(session.memo.isEmpty
                             ? NSLocalizedString("session.memo_placeholder", comment: "")
                             : session.memo)
                            .font(.caption2)
                            .foregroundStyle(session.memo.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                            .lineLimit(1)
                    }
                    .onTapGesture {
                        memoText = session.memo
                        isEditingMemo = true
                    }
                }
            }

            Spacer()

            if !session.tokenSummary.isEmpty {
                Text(session.tokenSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            Text(session.status.label)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(session.status.color.opacity(0.15))
                .clipShape(Capsule())

            Text(session.elapsedTime)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { memoText = session.memo }
        .contextMenu {
            Button(session.memo.isEmpty ? "session.add_memo" : "session.edit_memo") {
                memoText = session.memo
                isEditingMemo = true
            }
            if !session.memo.isEmpty {
                Button("session.delete_memo", role: .destructive) {
                    session.memo = ""
                    memoText = ""
                }
            }
            if session.status != .idle, let onTerminate {
                Divider()
                Button("session.terminate", role: .destructive) {
                    onTerminate()
                }
            }
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject private var history = StatusHistory.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("dashboard.history")
                    .font(.headline)
                Spacer()
                if !history.entries.isEmpty {
                    Button("dashboard.history_clear", role: .destructive) {
                        history.clear()
                    }
                    .font(.caption)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if history.entries.isEmpty {
                Text("dashboard.history_empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.entries) { entry in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.sessionName)
                                .font(.caption.bold())
                            HStack(spacing: 4) {
                                Text(NSLocalizedString("status.\(entry.fromStatus)", comment: ""))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(NSLocalizedString("status.\(entry.toStatus)", comment: ""))
                                    .font(.caption2)
                                    .foregroundStyle(statusColor(entry.toStatus))
                            }
                        }
                        Spacer()
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(width: 360, height: 400)
    }

    private func statusColor(_ rawValue: String) -> Color {
        switch rawValue {
        case "working": return .blue
        case "done": return .green
        case "needs_input": return .orange
        case "idle": return .gray
        default: return .primary
        }
    }
}

// MARK: - Drag & Drop

struct TileDropDelegate: DropDelegate {
    let targetId: String
    @Binding var draggingId: String?
    @Binding var sessions: [Session]
    var onReorder: (() -> Void)?

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        onReorder?()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragId = draggingId, dragId != targetId,
              let fromIndex = sessions.firstIndex(where: { $0.id == dragId }),
              let toIndex = sessions.firstIndex(where: { $0.id == targetId }) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            sessions.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
