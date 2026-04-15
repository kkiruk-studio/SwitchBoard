import Foundation

/// ~/.claude/settings.json 의 Stop/Notification 훅에 SwitchBoard 엔트리를 안전하게 머지한다.
/// - 기존 사용자 훅은 절대 삭제하지 않는다.
/// - 본 앱이 이미 설치한 엔트리는 현재 실행 중인 바이너리 경로로 갱신한다.
enum HookInstaller {
    private static let marker = "__switchboard__"

    static func installOrUpdate() {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard let executablePath = Bundle.main.executablePath else { return }

        let stopCommand = "\(shellQuote(executablePath)) --notify done"
        let notificationCommand = "\(shellQuote(executablePath)) --notify needs_input"
        let promptCommand = "\(shellQuote(executablePath)) --notify working"

        // 기존 파일 읽기 (없으면 빈 dict 시작)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = decoded
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        hooks["Stop"] = mergeEvent(hooks["Stop"], command: stopCommand)
        hooks["Notification"] = mergeEvent(hooks["Notification"], command: notificationCommand)
        hooks["UserPromptSubmit"] = mergeEvent(hooks["UserPromptSubmit"], command: promptCommand)
        root["hooks"] = hooks

        // 디렉토리 보장
        let dir = settingsURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 원자적 쓰기
        guard let outData = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let tmpURL = settingsURL.appendingPathExtension("switchboard.tmp")
        try? outData.write(to: tmpURL, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(settingsURL, withItemAt: tmpURL)
    }

    /// 이벤트 배열에서 SwitchBoard 표식이 붙은 훅을 찾아 갱신/삽입.
    /// 없으면 새로 추가. 사용자의 다른 훅은 그대로 둔다.
    private static func mergeEvent(_ existing: Any?, command: String) -> [[String: Any]] {
        var eventArray = (existing as? [[String: Any]]) ?? []

        let ourHook: [String: Any] = [
            "type": "command",
            "command": command,
            "_source": marker,
        ]

        // 기존 SwitchBoard 엔트리를 찾아 업데이트
        for i in 0..<eventArray.count {
            var matcher = eventArray[i]
            if var innerHooks = matcher["hooks"] as? [[String: Any]] {
                var replaced = false
                for j in 0..<innerHooks.count {
                    if isOurs(innerHooks[j]) {
                        innerHooks[j] = ourHook
                        replaced = true
                    }
                }
                if replaced {
                    matcher["hooks"] = innerHooks
                    eventArray[i] = matcher
                    return eventArray
                }
            }
        }

        // 기존에 없으면 독립 엔트리로 추가
        eventArray.append([
            "hooks": [ourHook],
        ])
        return eventArray
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        if (hook["_source"] as? String) == marker { return true }
        // 과거 설치판이 _source 없이 들어갔을 수 있으니 command 패턴으로도 식별
        if let cmd = hook["command"] as? String,
           cmd.contains("--notify"),
           cmd.contains("SwitchBoard") {
            return true
        }
        return false
    }

    private static func shellQuote(_ path: String) -> String {
        // 공백 포함 경로 대응 — 작은따옴표로 감싸고 내부 ' 는 이스케이프
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
