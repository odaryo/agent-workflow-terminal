import TerminalCore
import Testing

/// 同期は全て `AsyncStream` の受信で取り、`Task.sleep` を同期点にしない。時間で待つと、
/// 遅いマシンで偽陽性 (止まっていないのに止まったと読む) になる。
@MainActor
@Suite("view より長く生きるループの起動 (Issue #238)")
struct DetachedOnceTaskTests {

  /// 本丸。構造化された子として走っていれば、キャンセル後の 1 件は永久に届かない。
  @Test("呼び出し元 Task をキャンセルしても本体は動き続ける")
  func bodyOutlivesCallerCancellation() async {
    let (inputs, input) = AsyncStream.makeStream(of: Int.self)
    let (observed, observation) = AsyncStream.makeStream(of: Int.self)
    var iterator = observed.makeAsyncIterator()
    let subject = DetachedOnceTask()

    let caller = Task { @MainActor in
      subject.start {
        for await value in inputs { observation.yield(value) }
      }
      // view が生きている間 `.task` の本体が返らないのに相当する。キャンセルで即座に返る。
      try? await Task.sleep(for: .seconds(3600))
    }

    input.yield(1)
    #expect(await iterator.next() == 1)

    caller.cancel()
    await caller.value

    input.yield(2)
    #expect(await iterator.next() == 2)

    input.finish()
    observation.finish()
  }

  /// 上のテストが「キャンセルされても届く」ことを主張できるのは、同じ書き方を構造化したまま
  /// 走らせるとキャンセルでループが終わるからである。その前提自体をここで assertion にする。
  @Test("対照: 呼び出し元 Task の中で直接回すと、キャンセルでループが終わる")
  func structuredLoopStopsOnCallerCancellation() async {
    let (inputs, input) = AsyncStream.makeStream(of: Int.self)
    let (observed, observation) = AsyncStream.makeStream(of: Int.self)
    var iterator = observed.makeAsyncIterator()

    let caller = Task { @MainActor in
      for await value in inputs { observation.yield(value) }
      observation.yield(Self.loopEndedMarker)
    }

    input.yield(1)
    #expect(await iterator.next() == 1)

    caller.cancel()
    await caller.value
    #expect(await iterator.next() == Self.loopEndedMarker)

    input.finish()
    observation.finish()
  }

  @Test("2 回目の start は本体を再入させない")
  func secondStartDoesNotRunAnotherBody() async {
    let (releases, release) = AsyncStream.makeStream(of: Void.self)
    let (observed, observation) = AsyncStream.makeStream(of: Int.self)
    var iterator = observed.makeAsyncIterator()
    let subject = DetachedOnceTask()

    subject.start {
      observation.yield(1)
      for await _ in releases {}
      observation.yield(Self.loopEndedMarker)
      observation.finish()
    }
    #expect(await iterator.next() == 1)

    subject.start { observation.yield(2) }

    // 1 本目を終わらせ、そこで stream を閉じる。2 本目が起動していれば、閉じるより前に
    // 積まれた `2` がここで観測される。
    release.finish()
    var rest: [Int] = []
    while let value = await iterator.next() { rest.append(value) }
    #expect(rest == [Self.loopEndedMarker])
  }

  @Test("本体が終了した後も start は再入させない")
  func startAfterBodyFinishedDoesNotRunAnotherBody() async {
    let (inputs, input) = AsyncStream.makeStream(of: Int.self)
    let (observed, observation) = AsyncStream.makeStream(of: Int.self)
    var iterator = observed.makeAsyncIterator()
    let subject = DetachedOnceTask()

    input.finish()
    subject.start {
      for await value in inputs { observation.yield(value) }
      observation.yield(Self.loopEndedMarker)
    }
    #expect(await iterator.next() == Self.loopEndedMarker)

    subject.start { observation.yield(2) }
    // 2 本目より後に積んだ Task で閉じる。2 本目が起動していれば、その `2` が先に積まれる。
    Task { @MainActor in observation.finish() }

    var rest: [Int] = []
    while let value = await iterator.next() { rest.append(value) }
    #expect(rest.isEmpty)
  }

  /// ループが終わったことを観測するための、入力値と衝突しない番兵。
  private static let loopEndedMarker = -1
}
