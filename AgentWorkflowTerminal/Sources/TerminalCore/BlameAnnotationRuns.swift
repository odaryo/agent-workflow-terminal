/// blame の注記を、同じ commit が連続する行ごとにまとめる (設計書 §7.3)。離れた位置に同じ
/// commit が再び現れても別の run にする — 間に別の commit の行が挟まっていることを隠さないため。
public enum BlameAnnotationRuns {
  public static func runs<ID: Equatable>(of commitIDs: [ID]) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    var start = 0
    for index in commitIDs.indices.dropFirst() where commitIDs[index] != commitIDs[index - 1] {
      runs.append(start..<index)
      start = index
    }
    if !commitIDs.isEmpty { runs.append(start..<commitIDs.count) }
    return runs
  }
}
