import TerminalCore
import Testing

/// 同期は全て `AsyncStream` の受信で取り、`Task.sleep` を同期点にしない。時間で待つと、
/// 遅いマシンで偽陽性 (止まっていないのに止まったと読む) になる。
///
/// - Important: `.timeLimit` は飾りではない。この型が壊れる代表的な形は「本体が走らない」で、
///   その退行は待ち合わせが永久に返らない**ハング**として出る。Swift Testing にはテスト単位の
///   既定の制限時間が無いため、付けないと `swift test` が CI ジョブの時間を丸ごと食い、
///   失敗理由も出ない。`.minutes(1)` は受け付けられる最小の粒度で、正常系の実測は 1 ミリ秒未満。
@MainActor
@Suite("view より長く生きるループの起動 (Issue #238)", .timeLimit(.minutes(1)))
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
    let (inputs, input) = AsyncStream.makeStream(of: Int.self)
    let (observed, observation) = AsyncStream.makeStream(of: Int.self)
    var iterator = observed.makeAsyncIterator()
    let subject = DetachedOnceTask()

    #expect(
      subject.start {
        for await value in inputs { observation.yield(value) }
        observation.yield(Self.loopEndedMarker)
        observation.finish()
      })
    input.yield(1)
    #expect(await iterator.next() == 1)

    // 「2 本目が走らなかった」を副作用の不在では測らない。不在の観測は 2 本目が走る順序に
    // 依存し、順序が崩れた日に壊れた実装のまま緑になる。
    #expect(subject.start { observation.yield(Self.secondBodyMarker) } == false)

    // 入力を処理し続けているのは依然として 1 本目である。
    input.yield(2)
    #expect(await iterator.next() == 2)

    input.finish()
    #expect(await iterator.next() == Self.loopEndedMarker)
  }

  @Test("本体が終了した後も start は再入させない")
  func startAfterBodyFinishedDoesNotRunAnotherBody() async {
    let (inputs, input) = AsyncStream.makeStream(of: Int.self)
    let (observed, observation) = AsyncStream.makeStream(of: Int.self)
    var iterator = observed.makeAsyncIterator()
    let subject = DetachedOnceTask()

    input.finish()
    #expect(
      subject.start {
        for await value in inputs { observation.yield(value) }
        observation.yield(Self.loopEndedMarker)
        observation.finish()
      })
    // 1 本目が最後まで走り切ったことを、終了印と stream の終端の両方で確かめる。
    #expect(await iterator.next() == Self.loopEndedMarker)
    #expect(await iterator.next() == nil)

    #expect(subject.start { observation.yield(Self.secondBodyMarker) } == false)
  }

  /// ループが終わったことを観測するための、入力値と衝突しない番兵。
  private static let loopEndedMarker = -1
  /// 起動してはならない本体が走ったときだけ流れる値。
  private static let secondBodyMarker = -2
}
