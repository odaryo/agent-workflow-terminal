// swift-tools-version: 6.0

import PackageDescription

/// scripts/lib.sh の `awt_tmux_session_name` を、製品と同じ `TmuxSessionName` の答えと
/// 突き合わせるためだけの入れ物 (Issue #343)。実行は scripts/check-session-name-parity.sh。
///
/// 独立したパッケージにしているのは、突き合わせに使う実装が**製品そのもの**でなければ
/// 意味が無い一方、そのための executable target を AgentWorkflowTerminal 側へ足すと、
/// 製品の依存関係図に検査専用のターゲットが混ざるため。
let package = Package(
  name: "SessionNameParity",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../../AgentWorkflowTerminal")],
  targets: [
    .executableTarget(
      name: "SessionNameParity",
      dependencies: [.product(name: "TerminalCore", package: "AgentWorkflowTerminal")]
    )
  ]
)
