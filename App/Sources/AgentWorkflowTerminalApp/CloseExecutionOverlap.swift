/// Close による削除途中の観測失敗を警告へ載せないために使う (Issue #383)。
struct CloseExecutionOverlap {
  struct Mark: Equatable {
    let generation: UInt64
    let isExecuting: Bool
  }

  private var generation: UInt64 = 0
  private var executionCount = 0

  mutating func beginExecution() {
    generation &+= 1
    executionCount += 1
  }

  mutating func finishExecution() {
    generation &+= 1
    executionCount = max(0, executionCount - 1)
  }

  /// スキャンの開始時に取る。
  func mark() -> Mark {
    Mark(generation: generation, isExecuting: executionCount > 0)
  }

  /// 判定時に実行が終わっていても、スキャン中の削除による観測失敗は除外する。
  func overlapped(since mark: Mark) -> Bool {
    mark.isExecuting || mark.generation != generation
  }
}
