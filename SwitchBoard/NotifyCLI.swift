import Foundation

enum NotifyCLI {
    static let notificationName = "com.kkiruk.SwitchBoard.hookEvent"

    /// stdin에 들어오는 Claude Code 훅 JSON에서 session_id / cwd 추출 후
    /// 이미 실행 중인 SwitchBoard 앱으로 분산 알림을 전송한다.
    /// 앱이 안 떠있으면 조용히 무시 (훅은 폴링과 독립적으로 베스트-에포트).
    static func run(kind: String) {
        var sessionId = ""
        var cwd = ""
        var message = ""

        // stdin을 EOF까지 전부 읽는다 — availableData는 현재 버퍼만 반환하므로
        // Claude Code가 JSON을 조각내어 플러시하면 파싱이 실패할 수 있다.
        // stdin이 터미널(=파이프 아님)이면 무한 대기를 피해 건너뛴다.
        if isatty(fileno(stdin)) == 0 {
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            if !stdinData.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
                sessionId = (json["session_id"] as? String) ?? ""
                cwd = (json["cwd"] as? String) ?? ""
                message = (json["message"] as? String) ?? ""
            }
        }

        if cwd.isEmpty {
            cwd = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] ?? ""
        }

        let payload: [String: String] = [
            "kind": kind,
            "session_id": sessionId,
            "cwd": cwd,
            "message": message,
        ]

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(notificationName),
            object: nil,
            userInfo: payload,
            deliverImmediately: true
        )
    }
}
