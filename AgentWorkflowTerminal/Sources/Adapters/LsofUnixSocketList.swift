/// macOS 27 の `/usr/sbin/lsof` と tmux 3.8 で計測: attach 中の client は
/// `n->0x…` の形になり、server だけが socket のパスを出す。listen と accept で同じ PID の
/// 行が複数出るため、行数は server の数にはならない (Issue #500)。
public enum LsofUnixSocketList {
  public static func processIDs(listening socketPath: String, in output: String) -> [Int32] {
    var processID: Int32?
    var matches: Set<Int32> = []
    for line in output.split(separator: "\n") {
      switch line.first {
      case "p":
        processID = Int32(line.dropFirst())
      case "n":
        if line.dropFirst() == socketPath, let processID, processID > 0 {
          matches.insert(processID)
        }
      default:
        continue
      }
    }
    return matches.sorted()
  }
}
