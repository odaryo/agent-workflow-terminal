import Testing

@testable import Adapters
@testable import TerminalCore

/// 検証内容が薄いのは、Phase 1 の `Adapters` に実装が無いため。
/// モジュール構成と依存方向の破壊をビルドで検出することだけが目的で、
/// 実装が入ったら本来のテストへ置き換える。
@Suite("Adapters ターゲットの足場")
struct AdaptersScaffoldTests {

  @Test("Adapters から TerminalCore の公開 API を参照できる")
  func canReferenceTerminalCore() {
    #expect(AgentState.unknown.worktreeCategory == .unknown)
  }
}
