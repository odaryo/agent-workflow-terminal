import TerminalCore
import Testing

@Suite("Issue #879 重い判定をアプリ全体で1件ずつ回す", .timeLimit(.minutes(1)))
struct BranchMergeJudgementQueueTests {
  @Test("来た順に1件ずつ実行する")
  func runsOperationsOneAtATimeInArrivalOrder() async throws {
    let queue = BranchMergeJudgementQueue()
    let gate = QueueTestGate()
    let trace = QueueTestTrace()

    let first = Task {
      await queue.run {
        await trace.begin("first")
        await gate.wait()
        await trace.end()
        return 1
      }
    }
    try #require(await waitUntil { await trace.began == ["first"] })
    // queue は待っている呼び出しを外へ見せないので、到着の順は時間で作る。遅れても失敗するのは
    // 順の主張だけで、ハングはしない。
    let second = Task { await queue.run { await trace.runBriefly("second", returning: 2) } }
    try await Task.sleep(for: .milliseconds(100))
    let third = Task { await queue.run { await trace.runBriefly("third", returning: 3) } }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await trace.began == ["first"])

    await gate.open()

    #expect(await first.value == 1)
    #expect(await second.value == 2)
    #expect(await third.value == 3)
    #expect(await trace.began == ["first", "second", "third"])
    #expect(await trace.maximumRunning == 1)
  }

  @Test("順番待ちの間に取り消された Task の operation は実行せず nil を返し、後の呼び出しは動く")
  func cancelledWaiterReturnsNilWithoutRunning() async throws {
    let queue = BranchMergeJudgementQueue()
    let gate = QueueTestGate()
    let trace = QueueTestTrace()

    let first = Task {
      await queue.run {
        await trace.begin("first")
        await gate.wait()
        await trace.end()
        return 1
      }
    }
    try #require(await waitUntil { await trace.began == ["first"] })
    // 先頭が門で止まっている間は、取り消しが到着の前でも後でも順番は来ない。
    let cancelled = Task { await queue.run { await trace.runBriefly("cancelled", returning: 2) } }
    cancelled.cancel()
    let later = Task { await queue.run { await trace.runBriefly("later", returning: 3) } }

    await gate.open()

    #expect(await cancelled.value == nil)
    #expect(await first.value == 1)
    #expect(await later.value == 3)
    #expect(await trace.began == ["first", "later"])
  }

  /// 上のテストは取り消しの戻りを門を開けた後に読むので、取り消しを順番が来るまで持ち越す実装でも
  /// 通る。ここでは門を閉じたまま戻りを待つ。戻り値は別の Task で箱に入れて読み、壊れた実装でも
  /// テストをハングさせない。
  @Test("先頭が門で止まっている間に取り消された待ちの Task は、門が開く前に nil を返す")
  func cancelledWaiterReturnsWhileTheHeadIsStillRunning() async throws {
    let queue = BranchMergeJudgementQueue()
    let gate = QueueTestGate()
    let trace = QueueTestTrace()
    let outcome = QueueTestOutcome()

    let first = Task {
      await queue.run {
        await trace.begin("first")
        await gate.wait()
        await trace.end()
        return 1
      }
    }
    try #require(await waitUntil { await trace.began == ["first"] })
    let waiting = Task {
      await outcome.record(await queue.run { await trace.runBriefly("cancelled", returning: 2) })
    }
    // 列に入る前に取り消すと、順番待ちに入らずに返る経路を測ってしまう。列は外から見えないので、
    // 入ったことは時間で作る。
    try await Task.sleep(for: .milliseconds(100))
    waiting.cancel()
    let returnedWhileHeadRuns = await waitUntil { await outcome.hasReturned }
    let valueWhileHeadRuns = await outcome.value

    await gate.open()

    #expect(returnedWhileHeadRuns)
    #expect(valueWhileHeadRuns == nil)
    #expect(await first.value == 1)
    #expect(await trace.began == ["first"])
  }
}

private actor QueueTestOutcome {
  private(set) var hasReturned = false
  private(set) var value: Int?

  func record(_ value: Int?) {
    hasReturned = true
    self.value = value
  }
}

private actor QueueTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters = []
  }
}

private actor QueueTestTrace {
  private(set) var began: [String] = []
  private(set) var maximumRunning = 0
  private var running = 0

  func begin(_ name: String) {
    began.append(name)
    running += 1
    maximumRunning = max(maximumRunning, running)
  }

  func end() {
    running -= 1
  }

  func runBriefly(_ name: String, returning value: Int) async -> Int {
    begin(name)
    await Task.yield()
    end()
    return value
  }
}
