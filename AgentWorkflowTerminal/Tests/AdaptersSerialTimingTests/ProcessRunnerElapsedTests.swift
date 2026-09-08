import Adapters
import Darwin
import Foundation
import Testing

/// 経過時間の上限を主張するため AdaptersTests から分けている (Package.swift の
/// AdaptersSerialTimingTests の理由と同じ)。統合テストを有効にした CI で、実 tmux server の
/// 起動を並行に浴びて 1.036s / 1.327s と予算を超えた (Issue #176)。
/// `closesStandardInput` はプロセス全体の STDIN を差し替えるため、その一点だけでも
/// 並行実行から外れている必要がある。
@Suite("Foundation.Process 実行層の所要時間")
struct ProcessRunnerElapsedTests {
  private let runner = FoundationProcessRunner()

  @Test("stdout と stderr の両方をパイプ容量以上でも期限内に全バイト取得する")
  func drainsStandardOutputAndErrorConcurrently() async throws {
    let byteCount = 1_048_576
    let script = """
      dd if=/dev/zero bs=\(byteCount) count=1 2>/dev/null &
      dd if=/dev/zero bs=\(byteCount) count=1 1>&2 2>/dev/null &
      wait
      """
    let clock = ContinuousClock()
    let start = clock.now

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: [:],
      timeout: .seconds(2)
    )
    let elapsed = start.duration(to: clock.now)

    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == byteCount)
    #expect(result.stderr.utf8.count == byteCount)
    #expect(elapsed < .seconds(1))
  }

  @Test("標準入力を継承せず EOF で即時終了する")
  func closesStandardInput() async throws {
    // 親 stdin はテストランナーですでに EOF のため、継承の回帰を検出できるよう書き手を保持した
    // pipe へ一時的に差し替える。このプロセス全体への操作は、他の子を含むすべての stdin を
    // nullDevice に固定する ProcessRunning の契約の下でのみ安全である。
    var descriptors: [Int32] = [-1, -1]
    try #require(Darwin.pipe(&descriptors) == 0)
    let inheritedInput = descriptors[0]
    let heldOpenWriter = descriptors[1]
    let originalInput = Darwin.dup(STDIN_FILENO)
    guard originalInput >= 0 else {
      Darwin.close(inheritedInput)
      Darwin.close(heldOpenWriter)
      try #require(originalInput >= 0)
      return
    }
    defer {
      _ = Darwin.dup2(originalInput, STDIN_FILENO)
      Darwin.close(originalInput)
      Darwin.close(inheritedInput)
      Darwin.close(heldOpenWriter)
    }
    try #require(Darwin.dup2(inheritedInput, STDIN_FILENO) >= 0)

    let timeout = Duration.seconds(2)
    let clock = ContinuousClock()
    let start = clock.now

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      environment: [:],
      timeout: timeout
    )
    let elapsed = start.duration(to: clock.now)

    #expect(result == ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    #expect(elapsed < .seconds(1))
  }
}
