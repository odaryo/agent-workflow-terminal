import Foundation
import TerminalCore

// Gate 3 の記録を実装済み Adapter へ流し直し、設計書 §12.2 の「代表状態の保持時間」を
// 実測で決めるための使い捨てハーネス。分類器を書き直すと本物の Adapter と乖離するため、
// TerminalCore の Adapter をそのまま呼ぶ。
//
// 使い方 (このディレクトリで):
//   swift run -c release replay-swift                       # 遷移列 TSV から再計算 (既定)
//   swift run -c release replay-swift --records <runs dir>  # 生記録 (.gitignore) から計算
//   swift run -c release replay-swift --records <dir> --dump # 遷移列 TSV を書き出す
//   swift run -c release replay-swift --score --records <runs dir> [--poll 2.0]
//                                                           # 真値区間との混同行列 (生記録が要る)
//   swift run -c release replay-swift --score --records <dir> --poll 2.0 --min-changed-lines 1
//                                     # 「出力とみなす最小変化行数」を Adapter の宣言値から差し替える。
//                                     # Issue #203 の k=1/2/3 の表はこの引数を振って再現する。
//
// 生記録 (evidence/runs) は容量のため追跡していない。追跡しているのは
// evidence/replay-observations.tsv (Adapter の分類結果の遷移列) で、
// 保持時間の表はここからそのまま再現できる。

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  return args[i + 1]
}
let recordsDir = option("--records")
let tsvPath = option("--tsv") ?? "../evidence/replay-observations.tsv"
let shouldDump = args.contains("--dump")
/// 属性 (dim) を無かったことにして採点する。同じ記録で属性ありと無しを並べるため
/// (Issue #217: 属性を持たない旧記録では replay で再採点できないことの対照)。
let ignoresStyling = args.contains("--no-styled")
/// 記録の間隔。生記録は 250ms 周期で、TSV から復元するときも同じ間隔で刻む。
let framePeriod = 0.25

struct Observed {
  let ts: Double
  let category: WorktreeStateCategory
  let state: AgentState
}

// MARK: - 生記録から

struct Frame {
  let ts: Double
  let title: String
  let screen: String?
  /// `capture-pane -e -p` の生画面。属性を持たない旧記録では nil になり、
  /// dim を使う判定は「属性が取れなかった」側へ落ちる (Issue #217)。
  let screenEsc: String?
  /// pane 配下のプロセス名。recorder の `descendants()` は pane_pid 自身を含まないため、
  /// 製品の `TmuxAgentSignalSource.processTreeNames(of:rows:)` に合わせて
  /// `pane_current_command` を呼び出し側で足す。
  let procNames: Set<String>
  let paneCommand: String
  let dead: Bool
}

func loadFrames(_ dir: URL) -> [Frame] {
  guard
    let data = try? String(
      contentsOf: dir.appendingPathComponent("signals.jsonl"), encoding: .utf8)
  else { return [] }
  var frames: [Frame] = []
  for line in data.split(separator: "\n") {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let ts = obj["ts"] as? Double
    else { continue }
    // recorder が pane を観測できなかったフレーム (`{"ts":…, "error":…}`)。Agent の状態では
    // なく記録側の失敗なので、観測が無かったものとして落とす。
    guard let fmt = obj["fmt"] as? [String: Any] else { continue }
    var names: Set<String> = []
    for p in (obj["procs"] as? [[String: Any]] ?? []) {
      if let comm = p["comm"] as? String {
        names.insert(String(comm.split(separator: "/").last ?? Substring(comm)))
      }
    }
    frames.append(
      Frame(
        ts: ts, title: fmt["pane_title"] as? String ?? "", screen: obj["screen"] as? String,
        screenEsc: obj["screen_esc"] as? String,
        procNames: names, paneCommand: fmt["pane_current_command"] as? String ?? "",
        dead: (fmt["pane_dead"] as? String) == "1"))
  }
  return frames
}

func adapter(for run: String) -> (any AgentAdapter)? {
  if run.hasPrefix("claude") { return ClaudeCodeAdapter() }
  if run.hasPrefix("codex") { return CodexAdapter() }
  // fallback は pane プロセスそのものを Agent 扱いする。名前は記録上の
  // `pane_current_command` の実測値 (python3 は "Python" と出る)。
  if run.hasPrefix("fallback") {
    if run.contains("bash") { return ProcessDetectionFallbackAdapter(processNames: ["bash"]) }
    if run.contains("python3") { return ProcessDetectionFallbackAdapter(processNames: ["Python"]) }
    if run.contains("top") { return ProcessDetectionFallbackAdapter(processNames: ["top"]) }
    if run.contains("vim") { return ProcessDetectionFallbackAdapter(processNames: ["vim"]) }
  }
  return nil
}

/// `AgentScreenChangeTracker` と同じ規則。実物は ContinuousClock 依存で記録の ts を注入できない。
/// 規則がずれると採点が製品の挙動を表さなくなるので、`observe` の分岐は製品と1対1に保つ。
struct ScreenChange {
  /// 出力とみなす最小の変化行数。製品の `minimumChangedLines` と同じで、0 以下は 1 と同じ。
  let minimumChangedLines: Int
  /// 直前の**観測**画面と、最後に出力と認めた時刻。前者は毎回、後者は出力のときだけ更新する。
  private var last: (screen: String, changedAt: Double)?
  init(minimumChangedLines: Int = 1) { self.minimumChangedLines = minimumChangedLines }
  /// 製品の `AgentScreenChangeTracker.changedLineCount` と同じく index 単位で数え、
  /// 短い側を空行で埋める。
  static func changedLineCount(_ lhs: String, _ rhs: String) -> Int {
    let left = lhs.components(separatedBy: "\n")
    let right = rhs.components(separatedBy: "\n")
    return (0..<max(left.count, right.count)).reduce(0) { count, index in
      let l = index < left.count ? left[index] : ""
      let r = index < right.count ? right[index] : ""
      return count + (l == r ? 0 : 1)
    }
  }
  mutating func observe(_ screen: String, at ts: Double) -> TimeInterval? {
    guard let prev = last else {
      last = (screen, ts)
      return nil
    }
    let isOutput = Self.changedLineCount(prev.screen, screen) >= max(1, minimumChangedLines)
    last = (screen, isOutput ? ts : prev.changedAt)
    return isOutput ? 0 : ts - prev.changedAt
  }
  mutating func forget() {
    last = nil
  }
}

func replayRecords(run: String, dir: URL) -> [Observed] {
  replay(run: run, frames: loadFrames(dir))
}

/// `--min-changed-lines`。指定が無ければ Adapter が宣言する値を使うので、無指定の再生は
/// 製品の挙動そのものになる。k を振って比べるときだけ明示する。
/// トップレベル変数なので `nonisolated(unsafe)`。使い捨てハーネスで並行実行しない。
nonisolated(unsafe) var minimumChangedLinesOverride: Int?

/// フレーム列は呼び出し側が間引ける。`secondsSinceScreenChange` は前回**観測**との差なので、
/// polling を粗くしたときの成績は分類結果を間引くのではなく、入力を間引いて再生しないと合わない。
func replay(run: String, frames: [Frame]) -> [Observed] {
  guard let ad = adapter(for: run) else { return [] }
  var tracker = ScreenChange(
    minimumChangedLines: minimumChangedLinesOverride ?? ad.minimumChangedLinesForScreenActivity)
  var out: [Observed] = []
  for f in frames {
    let names = f.procNames.union([f.paneCommand])
    let liveness: AgentLiveness =
      f.dead || names.isDisjoint(with: ad.processNames) ? .absent : .alive
    if liveness == .absent {
      tracker.forget()
      // §5.2: Agent が居ない worktree の代表状態は Idle。
      out.append(Observed(ts: f.ts, category: .idle, state: .idle))
      continue
    }
    // 画面を取れなかったフレームで "" を入れると画面が変化したことになり、復帰直後が
    // working に化ける。実路は capture 失敗時に forget して nil を渡す。
    var elapsed: TimeInterval?
    if let screen = f.screen {
      elapsed = tracker.observe(screen, at: f.ts)
    } else {
      tracker.forget()
    }
    let signals = AgentSignals(
      paneTitle: f.title, screenText: f.screen,
      styledScreenText: ignoresStyling ? nil : f.screenEsc,
      secondsSinceScreenChange: elapsed,
      observedAt: Date(timeIntervalSince1970: f.ts))
    switch ad.classify(signals: signals, liveness: liveness) {
    case .absent: out.append(Observed(ts: f.ts, category: .idle, state: .idle))
    case .observation(let o): out.append(Observed(ts: f.ts, category: o.category, state: o.state))
    }
  }
  return out
}

// MARK: - 遷移列 TSV

func dumpTSV(_ runs: [(String, [Observed])], to path: String) throws {
  var lines = ["run\tt\tstate\tcategory"]
  for (run, obs) in runs {
    guard let first = obs.first else { continue }
    var last: WorktreeStateCategory?
    var lastState: AgentState?
    for o in obs where o.category != last || o.state != lastState {
      lines.append(
        "\(run)\t\(String(format: "%.3f", o.ts - first.ts))\t\(o.state.rawValue)\t"
          + "\(o.category.rawValue)")
      last = o.category
      lastState = o.state
    }
    lines.append("\(run)\t\(String(format: "%.3f", obs.last!.ts - first.ts))\tEND\tEND")
  }
  try (lines.joined(separator: "\n") + "\n").write(
    toFile: path, atomically: true, encoding: .utf8)
}

/// 遷移列を記録と同じ間隔へ展開し直す。値は遷移の間で一定なので元の系列と一致する。
func loadTSV(_ path: String) -> [(String, [Observed])] {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
  var byRun: [String: [(Double, AgentState, WorktreeStateCategory)]] = [:]
  var ends: [String: Double] = [:]
  var order: [String] = []
  for line in text.split(separator: "\n").dropFirst() {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count == 4, let t = Double(f[1]) else { continue }
    if !order.contains(f[0]) { order.append(f[0]) }
    if f[2] == "END" {
      ends[f[0]] = t
      continue
    }
    guard let state = AgentState(rawValue: f[2]),
      let category = WorktreeStateCategory(rawValue: f[3])
    else { continue }
    byRun[f[0], default: []].append((t, state, category))
  }
  return order.compactMap { run in
    guard let changes = byRun[run], let end = ends[run], let first = changes.first else {
      return nil
    }
    var out: [Observed] = []
    var index = 0
    var t = first.0
    while t <= end + 1e-9 {
      while index + 1 < changes.count && changes[index + 1].0 <= t + 1e-9 { index += 1 }
      out.append(Observed(ts: t, category: changes[index].2, state: changes[index].1))
      t += framePeriod
    }
    return (run, out)
  }
}

// MARK: - 安定化と指標

enum Rule { case asWritten, generalized }
/// 既定は確定した規則 (§12.2)。`Working` 起点だけに限る案は比較表でのみ使う。
nonisolated(unsafe) var rule = Rule.generalized

func isHeld(from: WorktreeStateCategory, to: WorktreeStateCategory) -> Bool {
  switch rule {
  // §12.2 の元の文言: Working からの降格だけ。
  case .asWritten: from == .working && (to == .idle || to == .unknown)
  // 確定した規則: idle / unknown へ入る遷移をすべて保持する。
  case .generalized: (to == .idle || to == .unknown) && from != to
  }
}

/// 保持時間 T を当てたあとに実際に表示される遷移列。
func stabilize(_ obs: [Observed], hold: Double) -> [Observed] {
  var displayed: [Observed] = []
  var current: Observed?
  var pendingSince: Double?
  for o in obs {
    guard let cur = current else {
      current = o
      displayed.append(o)
      continue
    }
    if isHeld(from: cur.category, to: o.category) {
      if pendingSince == nil { pendingSince = o.ts }
      if o.ts - pendingSince! >= hold {
        current = o
        pendingSince = nil
        if displayed.last?.category != o.category { displayed.append(o) }
      }
    } else {
      pendingSince = nil
      current = o
      if displayed.last?.category != o.category { displayed.append(o) }
    }
  }
  return displayed
}

/// `stabilize` と同じ規則で、1 フレームごとの「表示されている」区分を返す。
func displayedCategories(_ obs: [Observed], hold: Double) -> [(Double, WorktreeStateCategory)] {
  var out: [(Double, WorktreeStateCategory)] = []
  var current: Observed?
  var pendingSince: Double?
  for o in obs {
    guard let cur = current else {
      current = o
      out.append((o.ts, o.category))
      continue
    }
    if isHeld(from: cur.category, to: o.category) {
      if pendingSince == nil { pendingSince = o.ts }
      if o.ts - pendingSince! >= hold {
        current = o
        pendingSince = nil
      }
    } else {
      pendingSince = nil
      current = o
    }
    out.append((o.ts, current!.category))
  }
  return out
}

/// working が idle / unknown で中断され working へ戻るまでの長さ。これが振動の実体。
func workingInterruptions(_ obs: [Observed]) -> [Double] {
  var gaps: [Double] = []
  var lowerBegan: Double?
  var sawWorking = false
  for o in obs {
    if o.category == .working {
      if let start = lowerBegan, sawWorking { gaps.append(o.ts - start) }
      lowerBegan = nil
      sawWorking = true
    } else if o.category == .idle || o.category == .unknown {
      if lowerBegan == nil { lowerBegan = o.ts }
    } else {
      lowerBegan = nil
      sawWorking = false
    }
  }
  return gaps
}

/// 昇格が保持時間で遅れていないことの検証用。
func promotions(_ obs: [Observed]) -> [String] {
  obs.filter { $0.category == .needsAttention || $0.category == .readyForReview }
    .map { "\($0.category.rawValue)@\(String(format: "%.2f", $0.ts))" }
}

func collapse(_ obs: [Observed]) -> [Observed] {
  var out: [Observed] = []
  for o in obs where out.last?.category != o.category { out.append(o) }
  return out
}

// MARK: - --score: 真値区間との突き合わせ

/// `scripts/analyze.py` の `TRUTH_MARKERS["claude"]` と同じ。版数依存の文言なので変えない。
struct Pattern {
  private let regex: NSRegularExpression
  init(_ pattern: String) {
    regex = try! NSRegularExpression(pattern: pattern)
  }
  func count(in text: String) -> Int {
    regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
  }
  func matches(_ text: String) -> Bool { count(in: text) > 0 }
}
let donePattern = Pattern(#"·\s*done\s+\d"#)
let permissionPattern = Pattern(#"Do you want to |❯ 1\. Yes"#)

func truthEvents(_ dir: URL) -> [String: Double] {
  guard
    let text = try? String(
      contentsOf: dir.appendingPathComponent("truth.jsonl"), encoding: .utf8)
  else { return [:] }
  var out: [String: Double] = [:]
  for line in text.split(separator: "\n") {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let event = obj["event"] as? String, let ts = obj["ts"] as? Double
    else { continue }
    if out[event] == nil { out[event] = ts }
  }
  return out
}

/// `analyze.py` の `truth_intervals()` の claude 側だけの移植。
/// ターン終了は完了マーカーの**出現回数が増えた**最初のフレーム。直前ターンのマーカーが
/// 画面に残るため、有無では境界を切れない。
func truthIntervals(events: [String: Double], frames: [Frame]) -> [(Double, Double, String)] {
  func window(after: Double, before: Double?) -> [Frame] {
    frames.filter { frame in frame.ts >= after && (before.map { frame.ts < $0 } ?? true) }
  }
  func turnEnd(after: Double, before: Double?) -> Double? {
    let seq = window(after: after, before: before)
    guard let first = seq.first else { return nil }
    let base = donePattern.count(in: first.screen ?? "")
    return seq.dropFirst().first { donePattern.count(in: $0.screen ?? "") > base }?.ts
  }
  func permissionStart(after: Double, before: Double?) -> Double? {
    window(after: after, before: before).first { permissionPattern.matches($0.screen ?? "") }?.ts
  }

  guard let idleBegin = events["idle_begin"], let longSent = events["prompt_long_sent"],
    let permSent = events["prompt_perm_sent"], let approveSent = events["approve_sent"]
  else { return [] }
  var out: [(Double, Double, String)] = [(idleBegin, longSent, "idle")]
  if let done1 = turnEnd(after: longSent, before: permSent) {
    out.append((longSent, done1, "working"))
    out.append((done1, permSent, "completed"))
  }
  if let perm = permissionStart(after: permSent, before: approveSent) {
    out.append((permSent, perm, "working"))
    out.append((perm, approveSent, "permission"))
    if let done2 = turnEnd(after: approveSent, before: events["quiesce"]) {
      out.append((approveSent, done2, "working"))
      if let quiesce = events["quiesce"] { out.append((done2, quiesce, "completed")) }
    }
  }
  if let quiesce = events["quiesce"], let runEnd = events["run_end"] {
    out.append((quiesce, runEnd, "completed-left"))
  }
  return out
}

/// 境界前後は判定不能として集計から外す (`analyze.py` の `GUARD`、単位は秒)。
let scoreGuard = 1.0
/// `analyze.py` の `NEEDS_ATTENTION`。真値がこれらのとき、丸め先が安全かどうかを測る。
let needsAttentionTruth: Set<String> = ["question", "permission", "error"]
/// `analyze.py` の `SAFE_FOR_ATTENTION`。"attention" は種別不明の注意状態 (§12.4.3)。
let safeForAttention = needsAttentionTruth.union(["unknown", "attention"])

func predictionLabel(_ observed: Observed) -> String {
  observed.state == .unknown && observed.category == .needsAttention
    ? "attention" : observed.state.rawValue
}

/// 真値区間ごとに「タブに何が表示されているか」の内訳。Issue #203 の表と同じ指標。
/// 連続時間を両向きで出すのは、悪い側が真値によって逆だからである。idle 区間では
/// working が出続けるのが症状で、working 区間では working が消えるのが代償になる。
func runDisplayedScore(recordsDir: String, poll: Double, hold: Double) {
  let root = URL(fileURLWithPath: recordsDir)
  let runs = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    .filter { $0.hasPrefix("claude-composite-r") }.sorted()
  let step = max(1, Int((poll / framePeriod).rounded()))
  print("\n=== 保持 \(hold)s 適用後の表示 (真値区間ごとの表示区分の内訳、秒) ===")
  print(
    "真値\tn位相\t区間s\t表示=working s\t表示=idle s\t表示=その他 s\t"
      + "最長working連続 s\t最長非working連続 s")
  var totals: [String: [WorktreeStateCategory: Double]] = [:]
  var maxWorkingRun: [String: Double] = [:]
  var maxNonWorkingRun: [String: Double] = [:]
  var spans: [String: Double] = [:]
  for run in runs {
    let dir = root.appendingPathComponent(run)
    let frames = loadFrames(dir)
    let intervals = truthIntervals(events: truthEvents(dir), frames: frames)
    for phase in 0..<step {
      let sampled = stride(from: phase, to: frames.count, by: step).map { frames[$0] }
      let displayed = displayedCategories(replay(run: run, frames: sampled), hold: hold)
      for (label, lo, hi) in intervals.map({ ($0.2, $0.0, $0.1) }) {
        var workingStreak = 0.0
        var nonWorkingStreak = 0.0
        var bestWorking = 0.0
        var bestNonWorking = 0.0
        var counted = 0.0
        for (ts, cat) in displayed where ts >= lo && ts < hi {
          totals[label, default: [:]][cat, default: 0] += Double(step) * framePeriod
          counted += Double(step) * framePeriod
          if cat == .working {
            workingStreak += Double(step) * framePeriod
            bestWorking = max(bestWorking, workingStreak)
            nonWorkingStreak = 0
          } else {
            nonWorkingStreak += Double(step) * framePeriod
            bestNonWorking = max(bestNonWorking, nonWorkingStreak)
            workingStreak = 0
          }
        }
        maxWorkingRun[label] = max(maxWorkingRun[label] ?? 0, bestWorking)
        maxNonWorkingRun[label] = max(maxNonWorkingRun[label] ?? 0, bestNonWorking)
        spans[label, default: 0] += counted
      }
    }
  }
  for (label, byCategory) in totals.sorted(by: { $0.key < $1.key }) {
    let working = byCategory[.working] ?? 0
    let idle = byCategory[.idle] ?? 0
    let other = byCategory.values.reduce(0, +) - working - idle
    print(
      "\(label)\t\(step)\t\(String(format: "%.1f", spans[label] ?? 0))\t"
        + "\(String(format: "%.1f", working))\t\(String(format: "%.1f", idle))\t"
        + "\(String(format: "%.1f", other))\t"
        + "\(String(format: "%.1f", maxWorkingRun[label] ?? 0))\t"
        + "\(String(format: "%.1f", maxNonWorkingRun[label] ?? 0))")
  }
}

/// 真値区間ごとの「1 観測でいくつの行が変わったか」の分布。`--min-changed-lines` の値を
/// 推測で置かないための素材で、k に依存しない (比較対象は常に 1 回前の観測のため)。
func runChangedLinesHistogram(recordsDir: String, poll: Double) {
  let root = URL(fileURLWithPath: recordsDir)
  let runs = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    .filter { $0.hasPrefix("claude-composite-r") }.sorted()
  let step = max(1, Int((poll / framePeriod).rounded()))
  var histogram: [String: [Int: Int]] = [:]
  for run in runs {
    let dir = root.appendingPathComponent(run)
    let frames = loadFrames(dir)
    let intervals = truthIntervals(events: truthEvents(dir), frames: frames)
    for phase in 0..<step {
      var previousScreen: String?
      for frame in stride(from: phase, to: frames.count, by: step).map({ frames[$0] }) {
        guard let screen = frame.screen, !frame.dead else {
          previousScreen = nil
          continue
        }
        defer { previousScreen = screen }
        guard let previous = previousScreen else { continue }
        let changed = ScreenChange.changedLineCount(previous, screen)
        guard changed > 0,
          let interval = intervals.first(where: { frame.ts >= $0.0 && frame.ts < $0.1 }),
          frame.ts - interval.0 >= scoreGuard, interval.1 - frame.ts >= scoreGuard
        else { continue }
        histogram[interval.2, default: [:]][changed, default: 0] += 1
      }
    }
  }
  print("\n=== 変化があったフレームの変化行数 (真値区間別) ===")
  print("真値\tn\t内訳")
  for (label, counts) in histogram.sorted(by: { $0.key < $1.key }) {
    let breakdown = counts.sorted { $0.key < $1.key }.map { "\($0.key)行:\($0.value)" }
      .joined(separator: " ")
    print("\(label)\t\(counts.values.reduce(0, +))\t\(breakdown)")
  }
}

func runScore(recordsDir: String, poll: Double) {
  let root = URL(fileURLWithPath: recordsDir)
  let runs = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    .filter { $0.hasPrefix("claude-composite-r") }.sorted()
  guard !runs.isEmpty else {
    FileHandle.standardError.write(Data("claude-composite-r* が無い\n".utf8))
    exit(1)
  }
  // 位相 1 つでは標本が 1/step になり、当たり外れが数字を支配する。全位相を合算する。
  let step = max(1, Int((poll / framePeriod).rounded()))
  var dist: [String: [String: Int]] = [:]
  var scored = 0
  var excluded = 0

  for run in runs {
    let dir = root.appendingPathComponent(run)
    let frames = loadFrames(dir)
    let intervals = truthIntervals(events: truthEvents(dir), frames: frames)
    for phase in 0..<step {
      let sampled = stride(from: phase, to: frames.count, by: step).map { frames[$0] }
      for observed in replay(run: run, frames: sampled) {
        guard let interval = intervals.first(where: { observed.ts >= $0.0 && observed.ts < $0.1 })
        else { continue }
        if observed.ts - interval.0 < scoreGuard || interval.1 - observed.ts < scoreGuard {
          excluded += 1
          continue
        }
        scored += 1
        dist[interval.2, default: [:]][predictionLabel(observed), default: 0] += 1
      }
    }
  }

  print(
    "min-changed-lines: "
      + (minimumChangedLinesOverride.map(String.init) ?? "Adapter の宣言値 (claude=2)"))
  print("run: \(runs.count) 本 (\(runs.joined(separator: ", ")))")
  print(
    "poll: \(String(format: "%.2f", Double(step) * framePeriod))s = \(step) フレーム間引き / "
      + "位相 \(step) 通りを合算")
  print("採点 \(scored) フレーム / GUARD \(scoreGuard)s で除外 \(excluded) フレーム")
  print("\n真値\tn\trecall\t危険率\t予測の内訳")
  for (truth, counts) in dist.sorted(by: { $0.key < $1.key }) {
    let n = counts.values.reduce(0, +)
    let hit = counts[truth.replacingOccurrences(of: "-left", with: "")] ?? 0
    // 真値が Needs Attention でない区間に「危険な誤判定」は定義されない。0.000 と書くと
    // 計測値に見えるので、測っていないことを "—" で示す。
    let danger =
      needsAttentionTruth.contains(truth)
      ? String(
        format: "%.3f",
        Double(counts.filter { !safeForAttention.contains($0.key) }.values.reduce(0, +))
          / Double(n)) : "—"
    let breakdown = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    print(
      "\(truth)\t\(n)\t\(String(format: "%.3f", Double(hit) / Double(n)))\t"
        + "\(danger)\t\(breakdown)")
  }
}

// MARK: - 実行

if args.contains("--score") {
  guard let recordsDir else {
    FileHandle.standardError.write(Data("--score には --records が要る\n".utf8))
    exit(1)
  }
  var poll = framePeriod
  if let text = option("--poll") {
    // 黙って丸めると、第三者が「表示された値で再現した」つもりで別の間隔を測ることになる。
    guard let value = Double(text), value >= framePeriod,
      abs((value / framePeriod).rounded() * framePeriod - value) < 1e-9
    else {
      FileHandle.standardError.write(
        Data("--poll は記録間隔 \(framePeriod)s 以上のその倍数で指定する (例: 0.25, 0.5, 2.0)\n".utf8))
      exit(1)
    }
    poll = value
  }
  if let text = option("--min-changed-lines") {
    // 黙って無視すると、第三者が指定したつもりの k と別の値で採点した表を読むことになる。
    guard let value = Int(text), value >= 1 else {
      FileHandle.standardError.write(Data("--min-changed-lines は 1 以上の整数で指定する\n".utf8))
      exit(1)
    }
    minimumChangedLinesOverride = value
  }
  runScore(recordsDir: recordsDir, poll: poll)
  runDisplayedScore(recordsDir: recordsDir, poll: poll, hold: 9)
  runChangedLinesHistogram(recordsDir: recordsDir, poll: poll)
  exit(0)
}

var dataset: [(String, [Observed])]
if let recordsDir {
  let root = URL(fileURLWithPath: recordsDir)
  let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
  dataset = names.compactMap { name in
    var isDir: ObjCBool = false
    let dir = root.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
    else { return nil }
    let obs = replayRecords(run: name, dir: dir)
    return obs.count > 1 ? (name, obs) : nil
  }
  print("生記録から \(dataset.count) run")
} else {
  dataset = loadTSV(tsvPath)
  print("遷移列 TSV (\(tsvPath)) から \(dataset.count) run")
}

guard !dataset.isEmpty else {
  FileHandle.standardError.write(Data("run を1つも読めなかった\n".utf8))
  exit(1)
}

if shouldDump {
  guard recordsDir != nil else {
    FileHandle.standardError.write(Data("--dump には --records が要る\n".utf8))
    exit(1)
  }
  try dumpTSV(dataset, to: tsvPath)
  print("書き出した: \(tsvPath)")
}

let candidates: [Double] = [0, 0.5, 1, 2, 3, 4, 5, 6, 8, 8.5, 9, 9.5, 10, 15, 20, 30]
var totalMinutes = 0.0
var allGaps: [Double] = []
var residual: [Double: Int] = [:]
var transitions: [Double: Int] = [:]
var promotionMismatch = 0

print("\nrun\tmin\traw_trans/min\t中断回数\tmax_gap_s")
for (run, obs) in dataset {
  let minutes = (obs.last!.ts - obs.first!.ts) / 60
  totalMinutes += minutes
  let gaps = workingInterruptions(obs)
  allGaps.append(contentsOf: gaps)
  let raw = collapse(obs).count - 1
  print(
    "\(run)\t\(String(format: "%.1f", minutes))\t"
      + "\(String(format: "%.1f", Double(raw) / max(minutes, 0.001)))\t\(gaps.count)\t"
      + "\(String(format: "%.2f", gaps.max() ?? 0))")
  let baseline = promotions(stabilize(obs, hold: 0))
  for t in candidates {
    let disp = stabilize(obs, hold: t)
    transitions[t, default: 0] += max(disp.count - 1, 0)
    residual[t, default: 0] += workingInterruptions(disp).count
    if promotions(disp) != baseline { promotionMismatch += 1 }
  }
}

let sorted = allGaps.sorted()
func pct(_ p: Double) -> Double {
  sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
}
print("\n=== 合計 \(String(format: "%.1f", totalMinutes)) 分 ===")
print(
  "working の中断: n=\(sorted.count) p50=\(String(format: "%.2f", pct(0.5)))s "
    + "p90=\(String(format: "%.2f", pct(0.9)))s max=\(String(format: "%.2f", sorted.last ?? 0))s")
print("8秒より長い中断: \(sorted.filter { $0 > 8 }.map { String(format: "%.2f", $0) })")
print("昇格 (Needs Attention / Ready for Review) が保持で変化した回数: \(promotionMismatch)")

print("\nhold_s\t表示遷移/min\t残る中断\tその長さ")
for t in candidates {
  var gaps: [Double] = []
  for (_, obs) in dataset { gaps += workingInterruptions(stabilize(obs, hold: t)) }
  let shown = gaps.sorted().suffix(8).map { String(format: "%.2f", $0) }
  print(
    "\(t)\t\(String(format: "%.2f", Double(transitions[t] ?? 0) / totalMinutes))\t"
      + "\(residual[t] ?? 0)\t\(shown)")
}

print("\n=== 保持の対象範囲の比較 (表示が5秒未満で入れ替わった idle / unknown の回数) ===")
print("rule\thold_s\t短い idle\t短い unknown\t表示遷移/min")
for r in [Rule.asWritten, Rule.generalized] {
  rule = r
  let label = r == .asWritten ? "Working起点のみ" : "idle/unknownへ全部"
  for t in [0.0, 5, 8, 9, 10, 15] {
    var shortIdle = 0
    var shortUnknown = 0
    var trans = 0
    for (_, obs) in dataset {
      let disp = stabilize(obs, hold: t)
      trans += max(disp.count - 1, 0)
      for (i, seg) in disp.enumerated() {
        let end = i + 1 < disp.count ? disp[i + 1].ts : obs.last!.ts
        guard end - seg.ts < 5 else { continue }
        if seg.category == .idle { shortIdle += 1 }
        if seg.category == .unknown { shortUnknown += 1 }
      }
    }
    print(
      "\(label)\t\(t)\t\(shortIdle)\t\(shortUnknown)\t"
        + "\(String(format: "%.2f", Double(trans) / totalMinutes))")
  }
}
