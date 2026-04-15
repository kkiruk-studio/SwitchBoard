import Foundation

// --notify 모드: Claude Code 훅에서 호출됨. 즉시 분산 알림만 쏘고 종료.
let args = CommandLine.arguments
if args.count >= 2 && args[1] == "--notify" {
    NotifyCLI.run(kind: args.count >= 3 ? args[2] : "done")
    exit(0)
}

// 일반 모드: SwiftUI 앱 부팅.
SwitchBoardApp.main()
