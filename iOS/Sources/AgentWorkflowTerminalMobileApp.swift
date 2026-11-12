// UI 実装前に依存のリンクをビルドで確認するため、未使用のモジュールも import する。
import NIOPosix
import NIOSSH
import SwiftTerm
import SwiftUI

@main
@MainActor
struct AgentWorkflowTerminalMobileApp: App {
  var body: some Scene {
    WindowGroup {
      Text("接続先は未設定です")
        .padding()
    }
  }
}
