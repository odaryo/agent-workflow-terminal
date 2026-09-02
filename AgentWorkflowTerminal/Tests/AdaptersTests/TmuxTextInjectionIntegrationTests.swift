import Adapters
import Foundation
import TerminalCore
import Testing

private let isTmuxIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

/// 注入を拒む pane の状態。受け側 pane の状態がこの型の安全性を決めるので、統合テストの軸にする。
private enum RefusingPaneState: Sendable, CaseIterable {
  case copyMode
  case inputDisabled

  func setUpArguments(for pane: PaneID) -> [String] {
    switch self {
    case .copyMode: ["copy-mode", "-t", pane.rawValue]
    case .inputDisabled: ["select-pane", "-d", "-t", pane.rawValue]
    }
  }

  func expectedError(for pane: PaneID) -> TmuxTextInjectionError {
    switch self {
    case .copyMode: .paneInCopyMode(pane)
    case .inputDisabled: .paneInputDisabled(pane)
    }
  }
}

@Suite(
  "隔離 tmux server の pane へのテキスト注入 (設計書 §9.2 / §10)",
  .enabled(if: isTmuxIntegrationEnabled)
)
struct TmuxTextInjectionIntegrationTests {

  @Test("複数行・特殊文字・日本語・絵文字が bracketed paste に包まれてそのまま pane へ届く")
  func deliversTextVerbatimInsideBracketedPaste() async throws {
    let text = """
      $PATH `id` "quoted" 'single' back\\slash\ttab
      日本語とふりがな 🙂👨‍👩‍👧
      末尾改行あり

      """
    try await withByteCapturePane(label: "verbatim") { runner, pane, capture in
      try await TmuxTextInjection(runner: runner).inject(text, into: pane)

      try await capture.waitForDelivery(of: text)
    }
  }

  @Test("注入されたコマンドは実行されず、行編集バッファに入るだけになる")
  func doesNotExecuteInjectedCommand() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("no-exec")) { runner in
      let workspace = try Workspace()
      defer { workspace.remove() }
      let probe = ExecutionProbe(workspace: workspace)
      let pane = try await makeShellPane(runner)

      try await TmuxTextInjection(runner: runner).inject(probe.text, into: pane)

      // 実行されていれば touch が先に走るため、本文が画面に出た時点で判定できる。
      try await waitUntil("注入テキストが pane の画面に現れる") {
        try await capturePane(runner, pane: pane).contains(probe.token)
      }
      try await Task.sleep(for: .milliseconds(500))
      #expect(!probe.didExecute)
    }
  }

  @Test("copy-mode の pane へ注入しても、コマンドは実行されない")
  func doesNotExecuteInjectedCommandWhilePaneIsInCopyMode() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("copy-exec")) { runner in
      let workspace = try Workspace()
      defer { workspace.remove() }
      let probe = ExecutionProbe(workspace: workspace)
      let pane = try await makeShellPane(runner)
      _ = try await runner.run(arguments: RefusingPaneState.copyMode.setUpArguments(for: pane))

      await #expect(throws: TmuxTextInjectionError.paneInCopyMode(pane)) {
        try await TmuxTextInjection(runner: runner).inject(probe.text, into: pane)
      }

      try await Task.sleep(for: .milliseconds(500))
      #expect(!probe.didExecute)
    }
  }

  @Test(
    "入力が bracketed paste にならない状態の pane へは1バイトも送らない",
    arguments: RefusingPaneState.allCases
  )
  fileprivate func deliversNothingWhilePaneCannotAcceptABracketedPaste(
    _ state: RefusingPaneState
  ) async throws {
    try await withByteCapturePane(label: "refuse") { runner, pane, capture in
      _ = try await runner.run(arguments: state.setUpArguments(for: pane))

      await #expect(throws: state.expectedError(for: pane)) {
        try await TmuxTextInjection(runner: runner).inject("touch /tmp/nope\n", into: pane)
      }

      try await Task.sleep(for: .milliseconds(500))
      #expect(capture.delivered() == Data())
      #expect(try await listBuffers(runner).isEmpty)
    }
  }

  @Test("死んだ pane への注入は tmux の失敗のまま返り、buffer を残さない")
  func reportsDeadPaneAsARawFailure() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("dead")) { runner in
      let root = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      _ = try await runner.run(arguments: ["set-option", "-g", "remain-on-exit", "on"])
      let pane = try await splitPane(runner, from: root, command: "true")
      try await waitUntil("pane の終了") {
        try await display(runner, pane: pane, format: "#{pane_dead}") == "1"
      }

      let raised = await #expect(throws: TmuxTextInjectionError.self) {
        try await TmuxTextInjection(runner: runner).inject("text\n", into: pane)
      }

      #expect(
        raised
          == .tmux(.commandFailed(exitCode: 1, stdout: "", stderr: "target pane has exited\n")))
      #expect(try await listBuffers(runner).isEmpty)
    }
  }

  @Test("bracketed paste を抜け出す制御文字を含むテキストは、pane へ1バイトも届かない")
  func neverDeliversTextThatCanEscapeTheBracketedPaste() async throws {
    let payload = "safe;\u{1b}[201~touch /tmp/awt-should-never-run\n"
    try await withByteCapturePane(label: "escape") { runner, pane, capture in
      await #expect(
        throws: TmuxTextInjectionError.unsafeControlCharacter(
          scalar: "\u{1b}", unicodeScalarOffset: 5)
      ) {
        try await TmuxTextInjection(runner: runner).inject(payload, into: pane)
      }

      try await Task.sleep(for: .milliseconds(500))
      #expect(capture.delivered() == Data())
    }
  }

  @Test("256 KiB のテキストも欠けずに届く")
  func deliversLargeText() async throws {
    let text = String(repeating: "0123456789abcdef", count: 16 * 1_024)
    try await withByteCapturePane(label: "large") { runner, pane, capture in
      try await TmuxTextInjection(runner: runner).inject(text, into: pane)

      try await capture.waitForDelivery(of: text)
    }
  }

  @Test("注入の前後で、ユーザーの buffer stack が変わらない")
  func leavesTheUsersBufferStackUntouched() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("buffers")) { runner in
      let pane = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      _ = try await runner.run(arguments: ["set-buffer", "-b", "user-named", "USER NAMED"])
      _ = try await runner.run(arguments: ["set-buffer", "USER UNNAMED"])
      let before = try await listBuffers(runner)

      try await TmuxTextInjection(runner: runner).inject("review comment\n", into: pane)

      #expect(try await listBuffers(runner) == before)
      #expect(before.contains("user-named:"))
      #expect(before.contains("buffer0:"))
    }
  }

  @Test("届かなかった注入も buffer を残さない")
  func leavesNoBufferBehindWhenThePaneIsGone() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("miss-buf")) { runner in
      let missing = try await missingPaneID(runner)

      await #expect(throws: TmuxTextInjectionError.paneNotFound(missing)) {
        try await TmuxTextInjection(runner: runner).inject("text\n", into: missing)
      }

      #expect(try await listBuffers(runner).isEmpty)
    }
  }

  @Test("空文字列の注入は、存在しない pane を指しても成功し buffer を作らない")
  func injectingEmptyTextIsANoOp() async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName("empty")) { runner in
      let missing = try await missingPaneID(runner)

      try await TmuxTextInjection(runner: runner).inject("", into: missing)

      #expect(try await listBuffers(runner).isEmpty)
    }
  }

  // MARK: - 観測用ヘルパー

  /// 注入したバイト列を受け側アプリの解釈を挟まずに観測するための pane を1つ用意する。
  /// pane では行編集 (`stty raw -echo`) を止め、DECSET 2004 を立ててから `cat` でファイルへ落とす。
  /// 2004 を立てるのは、tmux 3.4 が `paste-buffer -p` の括りを、受け側が bracketed paste を
  /// 有効にしているときだけ付けるため (実測)。
  private func withByteCapturePane(
    label: String,
    body: (TmuxRunner, PaneID, ByteCapture) async throws -> Void
  ) async throws {
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName(label)) { runner in
      let workspace = try Workspace()
      defer { workspace.remove() }
      let outputPath = workspace.path(for: "delivered")
      let root = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
      let pane = try await splitPane(
        runner, from: root,
        command: "stty raw -echo; printf '\\033[?2004hREADY'; cat > '\(outputPath)'")
      // READY は 2004 の直後に同じ stream へ書かれるため、見えた時点で 2004 は処理済み。
      try await waitUntil("観測用 pane の準備") {
        try await capturePane(runner, pane: pane).contains("READY")
      }

      try await body(runner, pane, ByteCapture(path: outputPath))
    }
  }

  /// 注入されたコマンドが実行されないことを確かめるための pane。zsh を選ぶのは、macOS 標準の
  /// bash 3.2 が bracketed paste 非対応で、同じ注入が**実行されてしまう**ことを実測したため
  /// (`TmuxTextInjection` の doc に書いた限界そのもの)。`PS1` は prompt の描画を待つ目印で、
  /// prompt が出ていれば zle が動いている = 2004 が立っている。
  private func makeShellPane(_ runner: TmuxRunner) async throws -> PaneID {
    let root = try #require(await IsolatedTmuxServer.paneIDs(runner).first)
    let pane = try await splitPane(
      runner, from: root, command: "/bin/zsh -f -i",
      environment: "PS1=AWT_SHELL_READY> ")
    try await waitUntil("shell の prompt 表示") {
      try await capturePane(runner, pane: pane).contains("AWT_SHELL_READY>")
    }
    return pane
  }

  private func splitPane(
    _ runner: TmuxRunner,
    from root: PaneID,
    command: String,
    environment: String? = nil
  ) async throws -> PaneID {
    let created = try await runner.run(
      arguments: ["split-window", "-t", root.rawValue]
        + (environment.map { ["-e", $0] } ?? [])
        + ["-P", "-F", "#{pane_id}", command])
    return PaneID(rawValue: created.stdout.trimmingCharacters(in: .newlines))
  }

  private func capturePane(_ runner: TmuxRunner, pane: PaneID) async throws -> String {
    try await runner.run(arguments: ["capture-pane", "-p", "-t", pane.rawValue]).stdout
  }

  private func display(_ runner: TmuxRunner, pane: PaneID, format: String) async throws -> String {
    try await runner.run(arguments: ["display-message", "-p", "-t", pane.rawValue, format])
      .stdout.trimmingCharacters(in: .newlines)
  }

  private func listBuffers(_ runner: TmuxRunner) async throws -> String {
    try await runner.run(arguments: ["list-buffers"]).stdout
  }

  private func missingPaneID(_ runner: TmuxRunner) async throws -> PaneID {
    let used = try await IsolatedTmuxServer.paneIDs(runner)
      .compactMap { Int($0.rawValue.dropFirst()) }
    return PaneID(rawValue: "%\((used.max() ?? 0) + 1_000)")
  }

  private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(20),
    condition: () async throws -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw IntegrationTimeout(description: description)
  }
}

private struct IntegrationTimeout: Error, CustomStringConvertible {
  let description: String
}

/// 統合テストが作る一時ファイルの置き場。テストの成否にかかわらず消す。
private struct Workspace {
  private let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "awt-injection-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func path(for name: String) -> String {
    directory.appending(path: name).path
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// 実行されたら痕跡ファイルが残る注入本文。許可された文字だけで組み立てる。
private struct ExecutionProbe {
  let token = "AWT_PASTE_\(UInt32.random(in: 0..<1_000_000))"
  private let hitPath: String

  init(workspace: Workspace) {
    hitPath = workspace.path(for: "executed")
  }

  var text: String { "\(token); touch '\(hitPath)'\n" }
  var didExecute: Bool { FileManager.default.fileExists(atPath: hitPath) }
}

/// pane が受け取ったバイト列。
private struct ByteCapture {
  /// tmux 3.4 実測: `paste-buffer -p` は本文を `ESC[200~` / `ESC[201~` で括り、本文中の LF を
  /// CR へ変換して届ける。ここは実装の写しではなく、この観測結果を期待値として書いている。
  private static let start = Data("\u{1b}[200~".utf8)
  private static let end = Data("\u{1b}[201~".utf8)

  let path: String

  func delivered() -> Data {
    FileManager.default.contents(atPath: path) ?? Data()
  }

  func waitForDelivery(of text: String) async throws {
    let expected =
      Self.start + Data(text.replacingOccurrences(of: "\n", with: "\r").utf8) + Self.end
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(20))
    while clock.now < deadline, delivered().count < expected.count {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(delivered() == expected)
  }
}
