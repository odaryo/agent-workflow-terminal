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
  let procNames: Set<String>
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
    let fmt = obj["fmt"] as? [String: Any] ?? [:]
    var names: Set<String> = []
    for p in (obj["procs"] as? [[String: Any]] ?? []) {
      if let comm = p["comm"] as? String {
        names.insert(String(comm.split(separator: "/").last ?? Substring(comm)))
      }
    }
    frames.append(
      Frame(
        ts: ts, title: fmt["pane_title"] as? String ?? "", screen: obj["screen"] as? String,
        procNames: names, dead: (fmt["pane_dead"] as? String) == "1"))
  }
  return frames
}

func adapter(for run: String) -> (any AgentAdapter)? {
  if run.hasPrefix("claude") { return ClaudeCodeAdapter() }
  if run.hasPrefix("codex") { return CodexAdapter() }
  if run.hasPrefix("fallback") {
    if run.contains("bash") { return ProcessDetectionFallbackAdapter(processNames: ["bash"]) }
    if run.contains("python3") { return ProcessDetectionFallbackAdapter(processNames: ["python3"]) }
    if run.contains("top") { return ProcessDetectionFallbackAdapter(processNames: ["top"]) }
  }
  return nil
}

/// AgentScreenChangeTracker と同じ規則。実物は ContinuousClock 依存で記録の ts を注入できない。
struct ScreenChange {
  private var last: (screen: String, at: Double)?
  mutating func observe(_ screen: String, at ts: Double) -> TimeInterval? {
    guard let prev = last else {
      last = (screen, ts)
      return nil
    }
    if prev.screen != screen {
      last = (screen, ts)
      return 0
    }
    return ts - prev.at
  }
  mutating func forget() { last = nil }
}

func replayRecords(run: String, dir: URL) -> [Observed] {
  guard let ad = adapter(for: run) else { return [] }
  var tracker = ScreenChange()
  var out: [Observed] = []
  for f in loadFrames(dir) {
    let liveness: AgentLiveness =
      f.dead || f.procNames.isDisjoint(with: ad.processNames) ? .absent : .alive
    if liveness == .absent {
      tracker.forget()
      // §5.2: Agent が居ない worktree の代表状態は Idle。
      out.append(Observed(ts: f.ts, category: .idle, state: .idle))
      continue
    }
    let signals = AgentSignals(
      paneTitle: f.title, screenText: f.screen,
      secondsSinceScreenChange: tracker.observe(f.screen ?? "", at: f.ts),
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
nonisolated(unsafe) var rule = Rule.asWritten

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

// MARK: - 実行

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

let candidates: [Double] = [0, 0.5, 1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30]
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

print("\nhold_s\t表示遷移/min\t残る中断")
for t in candidates {
  print(
    "\(t)\t\(String(format: "%.2f", Double(transitions[t] ?? 0) / totalMinutes))\t"
      + "\(residual[t] ?? 0)")
}

print("\n=== 保持の対象範囲の比較 (表示が5秒未満で入れ替わった idle / unknown の回数) ===")
print("rule\thold_s\t短い idle\t短い unknown\t表示遷移/min")
for r in [Rule.asWritten, Rule.generalized] {
  rule = r
  let label = r == .asWritten ? "Working起点のみ" : "idle/unknownへ全部"
  for t in [0.0, 5, 8, 10, 15] {
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
