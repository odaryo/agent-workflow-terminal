import Foundation
import TerminalCore

/// `ps -Ao pid=,ppid=,comm=` の1行。`name` は `comm` の最後のパス要素で、空白を含み得る。
struct ProcessTableRow: Sendable, Equatable {
  let pid: Int32
  let parentPID: Int32
  let name: String
}

/// 1回の `ps` 出力を、pane ごとの木探索が O(木の大きさ) で済む形に畳んだもの。
///
/// 生文字列ではなくこの形でキャッシュするのは、pane 数ぶんの探索が同じ出力を毎回
/// パースし直すと、起動を畳んでも CPU が残るため (Issue #239 R1)。
struct ProcessTableSnapshot: Sendable {
  private let rowsByPID: [Int32: ProcessTableRow]
  private let childrenByParentPID: [Int32: [ProcessTableRow]]

  init(rows: [ProcessTableRow]) {
    // 同一 pid が2行現れることは無いが、現れた場合は先着を残す (後着で上書きしない)。
    self.rowsByPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    self.childrenByParentPID = Dictionary(grouping: rows, by: \.parentPID)
  }

  /// dead pane は呼び出し側で除外済みなので、直接 exec された Agent を拾うため `root` 自身から辿る。
  func processTreeNames(of root: Int32) -> Set<String> {
    var pending = rowsByPID[root].map { [$0] } ?? []
    var names: Set<String> = []
    while let row = pending.popLast() {
      names.insert(row.name)
      pending.append(contentsOf: childrenByParentPID[row.pid] ?? [])
    }
    return names
  }

  static func parse(_ output: String) -> Self {
    Self(
      rows: output.split(separator: "\n").compactMap { line in
        let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard fields.count == 3, let pid = Int32(fields[0]), let parentPID = Int32(fields[1])
        else { return nil }
        let command = String(fields[2])
        return ProcessTableRow(
          pid: pid, parentPID: parentPID,
          name: command.split(separator: "/").last.map(String.init) ?? command
        )
      })
  }
}

/// 全 pane が共有する `ps` スナップショット。TTL 内の連続呼び出しと、同時に到着した呼び出しの
/// 両方を1回の起動へ畳む (Issue #239 R1)。`ps` は1回 48ms 級で、pane ごとに起動すると
/// 観測コストの過半を占める。
///
/// - Important: TTL は呼び出し側の `AgentObservationIntervals.liveness` の**半分以下**を渡す。
///   pane ごとの生存確認は位相がばらけるため、TTL が周期に近いと「前回から TTL 未満だが
///   別 pane の観測」が畳めず、実効の鮮度だけが落ちる。既定値はこの前提で選んでいる。
actor ProcessTableSnapshotCache {
  /// 既定の `liveness` 周期 5s の半分。生存判定の最悪鮮度は 5s + 2.5s = 7.5s になる。
  static let defaultTimeToLive = Duration.milliseconds(2_500)

  private let processRunner: any ProcessRunning
  private let executableURL: URL
  private let timeToLive: Duration
  private let timeSource: any ContinuousTimeSource
  private var latest: (snapshot: ProcessTableSnapshot, capturedAt: ContinuousClock.Instant)?
  private var inFlight: InFlightRead?

  /// 起動側と待ち手側で同じ時刻を刻むため、開始時刻を task と一緒に持つ。
  private struct InFlightRead {
    let task: Task<ProcessTableSnapshot?, Never>
    let capturedAt: ContinuousClock.Instant
  }

  init(
    processRunner: any ProcessRunning,
    executableURL: URL,
    timeToLive: Duration = defaultTimeToLive,
    timeSource: any ContinuousTimeSource = SystemContinuousTimeSource()
  ) {
    self.processRunner = processRunner
    self.executableURL = executableURL
    self.timeToLive = timeToLive
    self.timeSource = timeSource
  }

  /// `nil` は「読めなかった」。失敗はキャッシュしないので、次の呼び出しで再試行される。
  func snapshot() async -> ProcessTableSnapshot? {
    if let latest, timeSource.now < latest.capturedAt.advanced(by: timeToLive) {
      return latest.snapshot
    }
    if let inFlight {
      let value = await inFlight.task.value
      if self.inFlight?.task == inFlight.task {
        complete(value, capturedAt: inFlight.capturedAt)
      }
      return value
    }
    let capturedAt = timeSource.now
    let task = Task { [processRunner, executableURL] in
      await Self.read(processRunner: processRunner, executableURL: executableURL)
    }
    inFlight = InFlightRead(task: task, capturedAt: capturedAt)
    let value = await task.value
    if inFlight?.task == task { complete(value, capturedAt: capturedAt) }
    return value
  }

  private func complete(
    _ value: ProcessTableSnapshot?, capturedAt: ContinuousClock.Instant
  ) {
    inFlight = nil
    // 失敗はキャッシュしない。次の呼び出しで再試行できるようにする。
    guard let value else { return }
    latest = (value, capturedAt)
  }

  private static func read(
    processRunner: any ProcessRunning, executableURL: URL
  ) async -> ProcessTableSnapshot? {
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: executableURL, arguments: ["-Ao", "pid=,ppid=,comm="],
        environment: ["LC_ALL": "C"], timeout: .seconds(10)
      )
    } catch { return nil }
    guard result.exitCode == 0 else { return nil }
    return ProcessTableSnapshot.parse(result.stdout)
  }
}
