import SwiftUI

struct PopoverView: View {
    @ObservedObject var sessionManager: SessionManager
    var onOpenDashboard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                Text("Switchboard")
                    .font(.headline)
                Spacer()
                Button {
                    onOpenDashboard()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("popover.open_dashboard")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 세션 목록
            if sessionManager.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("dashboard.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sessionManager.sessions) { session in
                            PopoverSessionRow(session: session)
                                .onTapGesture {
                                    sessionManager.focusTerminal(session: session)
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Divider()

            // 푸터
            HStack {
                let active = sessionManager.sessions.filter { $0.status == .working }.count
                let total = sessionManager.sessions.count
                Text(String(format: NSLocalizedString("dashboard.active_count", comment: ""), active, total))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 팝오버 세션 행

private struct PopoverSessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.status.color)
                .frame(width: 8, height: 8)

            Text(session.name)
                .font(.system(.caption, weight: .medium))
                .lineLimit(1)

            Spacer()

            Text(session.status.label)
                .font(.caption2)
                .foregroundStyle(session.status.color)

            Text(session.elapsedTime)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}
