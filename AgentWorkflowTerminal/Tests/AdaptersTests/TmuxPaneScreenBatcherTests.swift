import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// バッチの1回目だけ応答を止める `ProcessRunning`。in-flight のバッチに「そのバッチに含まれない
/// pane」の初回登録が重なる経路は、逐次呼び出しでは作れない。
private actor FirstBatchGateRunner: ProcessRunning {
  private(set) var launches = 0
  private var waiter: CheckedContinuation<Void, Never>?
  private var launchWaiter: CheckedContinuation<Void, Never>?
  private var isGateOpen = false
  private let screens: [PaneID: String]

  init(screens: [PaneID: String]) { self.screens = screens }

  func openGate() {
    isGateOpen = true
    waiter?.resume()
    waiter = nil
  }

  /// 1本目のバッチが起動するまで待つ。`Task.yield()` の空回しで待つと、協調スレッドを占有して
  /// 同じプロセスで並行に走る他 suite の待ち合わせを飢えさせる (実測: それで
  /// `WorktreePaneAgentStateFeedTests` が 10 回に 1 回落ちた)。
  func waitForFirstLaunch() async {
    guard launches < 1 else { return }
    await withCheckedContinuation { launchWaiter = $0 }
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    launches += 1
    launchWaiter?.resume()
    launchWaiter = nil
    if !isGateOpen {
      await withCheckedContinuation { waiter = $0 }
    }
    let request = ObservationProcessSpy.parseBatch(arguments)
    var stdout = ""
    for pane in request.panes {
      stdout += screens[pane] ?? "\n"
      stdout += "\(request.nonce) "
      stdout += ObservationProcessSpy.render(
        format: request.format, paneID: pane.rawValue, title: "t")
      stdout += "\n"
    }
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }
}

/// 指定した pane のマーカーだけ、pane ID は正しいまま**区切りごと**壊して返す。
/// exit code は 0 のままなので、判定は復号側にしかできない。
private actor MalformedMarkerRunner: ProcessRunning {
  private let malformed: PaneID
  private let screens: [PaneID: String]

  init(malformed: PaneID, screens: [PaneID: String]) {
    self.malformed = malformed
    self.screens = screens
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    let request = ObservationProcessSpy.parseBatch(arguments)
    var stdout = ""
    for pane in request.panes {
      stdout += screens[pane] ?? "\n"
      if pane == malformed {
        // 区切りが消えてフィールドが1つになった形 (`invalidFieldCount`)。
        stdout += "\(request.nonce) \(pane.rawValue)\n"
      } else {
        stdout += "\(request.nonce) "
        stdout += ObservationProcessSpy.render(
          format: request.format, paneID: pane.rawValue, title: "t")
        stdout += "\n"
      }
    }
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }
}

@Suite("capture-pane バッチの失敗経路")
struct TmuxPaneScreenBatcherTests {
  private let first = PaneID(rawValue: "%1")
  private let second = PaneID(rawValue: "%2")
  private let third = PaneID(rawValue: "%3")

  /// in-flight のバッチを待った後の refresh で取れた画面を捨ててはならない。tmux を1回起動して
  /// 得た画面を `.unavailable` にすると、その pane は次の周期まで Unknown のままになる。
  @Test("in-flight のバッチに重なった初回登録でも、その周期の画面を返す")
  func returnsScreenRegisteredDuringInFlightBatch() async throws {
    let runner = FirstBatchGateRunner(screens: [first: "one\n", second: "two\n"])
    let batcher = TmuxPaneScreenBatcher(
      runner: try makeTmuxRunner(socketName: "batcher-test", processRunner: runner),
      timeToLive: .seconds(30), timeSource: ManualTimeSource())

    // %1 のバッチを in-flight のまま止める。
    async let firstScreen = batcher.screen(of: first)
    await runner.waitForFirstLaunch()
    // %2 はこのバッチに含まれていないので、待った後にもう一度読み直す必要がある。
    async let secondScreen = batcher.screen(of: second)
    // %2 が batcher へ到達する猶予。足りなければ起動が 2 回になってテストが落ちるので、
    // 見逃す方向へは倒れない。`Task.sleep` は協調スレッドを手放すので他 suite を妨げない。
    try await Task.sleep(for: .milliseconds(50))
    await runner.openGate()

    let results = try await [firstScreen, secondScreen]
    #expect(results[0].screen == .captured("one\n"))
    #expect(results[1].screen == .captured("two\n"))
    // 「refresh の回数を増やせば結果的に取れる」実装で緑にならないよう、起動回数も縛る。
    // %1 のバッチ (%2 を含まない) と、%2 を含む2本目の 2 回で足りる。
    #expect(await runner.launches == 2)
  }

  /// 「観測できなかった」と「消えた」を混ぜない (設計書 §12)。画面に紛れ込んだ偽マーカーや、
  /// 将来版で title に区切りが入った場合の field count 不一致まで `.paneNotFound` に倒すと、
  /// 生きている pane が登録解除され、変化追跡の基準も捨てられる。
  @Test("pane ID 以外のマーカー破損は消失ではなく未取得として扱う")
  func malformedMarkerFieldsAreUnavailableNotMissing() async throws {
    let runner = MalformedMarkerRunner(
      malformed: second, screens: [first: "one\n", second: "two\n", third: "three\n"])
    let batcher = TmuxPaneScreenBatcher(
      runner: try makeTmuxRunner(socketName: "batcher-test", processRunner: runner),
      timeToLive: .seconds(30), timeSource: ManualTimeSource())

    _ = try await batcher.screen(of: first)
    _ = try await batcher.screen(of: second)
    let thirdResult = try await batcher.screen(of: third)
    let secondResult = try await batcher.screen(of: second)

    #expect(secondResult.screen == .unavailable)
    // 登録は外れないので、後続の pane も同じバッチで取れている。
    #expect(thirdResult.screen == .captured("three\n"))
  }

  /// `display-message` は存在しない pane でも exit 0 で空の `#{pane_id}` を返す (tmux 3.4 実測)。
  /// 列が止まらないので、exit code だけでは pane の消失を検出できない。
  @Test("marker が壊れた pane は paneNotFound になり、後続の pane は取れる")
  func detectsBrokenMarkerWithoutFailureExitCode() async throws {
    let spy = ObservationProcessSpy(
      screens: [first: ["one\n"], second: ["two\n"], third: ["three\n"]],
      vanishingAfterCapture: [second])
    let batcher = TmuxPaneScreenBatcher(
      runner: try makeTmuxRunner(socketName: "batcher-test", processRunner: spy),
      timeToLive: .seconds(30), timeSource: ManualTimeSource())

    _ = try await batcher.screen(of: first)
    _ = try await batcher.screen(of: second)
    let thirdResult = try await batcher.screen(of: third)
    let secondResult = try await batcher.screen(of: second)
    let firstResult = try await batcher.screen(of: first)

    #expect(secondResult.screen == .paneNotFound)
    #expect(thirdResult.screen == .captured("three\n"))
    #expect(firstResult.screen == .captured("one\n"))
  }

  /// 1 pane で上限を超えたときにバッチ全体を失敗させると、その周期は全 pane が Unknown になり、
  /// 失敗はキャッシュしないので pane ごとの起動が復活する (#239 が消したはずのもの)。
  @Test("単独 pane の出力上限超過は、その pane だけを落とす")
  func oversizedSinglePaneDoesNotFailTheBatch() async throws {
    let spy = ObservationProcessSpy(
      screens: [first: ["one\n"], second: ["two\n"]], oversized: [second])
    let batcher = TmuxPaneScreenBatcher(
      runner: try makeTmuxRunner(socketName: "batcher-test", processRunner: spy),
      timeToLive: .seconds(30), timeSource: ManualTimeSource())

    _ = try await batcher.screen(of: first)
    let secondResult = try await batcher.screen(of: second)
    let firstResult = try await batcher.screen(of: first)

    #expect(secondResult.screen == .unavailable)
    #expect(firstResult.screen == .captured("one\n"))
  }

  @Test("marker から pane ごとの title を取り出す")
  func decodesTitlesFromMarkers() async throws {
    let spy = ObservationProcessSpy(
      screens: [first: ["one\n"], second: ["two\n"]],
      titles: [first: [#"back\slash $dollar"#], second: ["⠋ working"]])
    let batcher = TmuxPaneScreenBatcher(
      runner: try makeTmuxRunner(socketName: "batcher-test", processRunner: spy),
      timeToLive: .seconds(30), timeSource: ManualTimeSource())

    _ = try await batcher.screen(of: first)
    let secondResult = try await batcher.screen(of: second)

    #expect(secondResult.snapshot.titles[first] == #"back\slash $dollar"#)
    #expect(secondResult.snapshot.titles[second] == "⠋ working")
  }
}
