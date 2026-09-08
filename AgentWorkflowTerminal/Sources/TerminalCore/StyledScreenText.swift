import Foundation

/// `tmux capture-pane -e -p` の出力を、行ごとの「文字と dim 属性」へ分解する。
///
/// - Important: `plainText` は `capture-pane -p` (属性なし) の出力とバイト等価であることを
///   前提に使われる。Issue #217 の実測では 40 組中 40 組で一致した。
public struct StyledScreenText: Sendable, Hashable {
  public struct Line: Sendable, Hashable {
    /// `text` ではなく Character 配列で持つのは、`isDim` と要素数を必ず一致させるため。
    /// String へ順次 append すると結合文字が直前の Character へ吸収され、添字がずれる。
    public let characters: [Character]
    /// `characters` と同じ個数・同じ並びで、SGR 2 (dim) の有効/無効を持つ。
    public let isDim: [Bool]
    public var text: String { String(characters) }
  }

  public let lines: [Line]
  /// SGR / OSC を除去し、各行の末尾から半角スペースとタブだけを落とした文字列。
  public let plainText: String
  /// SGR を1つも含まない捕捉。色を出さない端末では dim が観測できないため、
  /// 「dim が付いていない」と「属性が取れていない」を取り違えないための材料。
  public let containsAnyStyling: Bool

  public init(capturedWithEscapeSequences captured: String) {
    var lines: [Line] = []
    var characters: [Character] = []
    var isDim: [Bool] = []
    var dimActive = false
    var sawStyling = false
    var index = captured.startIndex

    func endLine() {
      // 行末の rstrip は**半角スペースとタブだけ**。NBSP を落とすと `capture-pane -p` と
      // バイト不一致になる (Issue #217 の実測で 25 組中 9 組)。tmux は行末の NBSP を
      // 空白として刈らないため、こちらも刈ってはならない。
      var end = characters.count
      while end > 0, characters[end - 1] == " " || characters[end - 1] == "\t" { end -= 1 }
      lines.append(
        Line(characters: Array(characters.prefix(end)), isDim: Array(isDim.prefix(end))))
      characters = []
      isDim = []
    }

    while index < captured.endIndex {
      let character = captured[index]
      if character == "\u{1b}" {
        let (next, sgr) = Self.skipEscapeSequence(captured, from: index)
        if let sgr {
          sawStyling = true
          dimActive = Self.applySGR(sgr, to: dimActive)
        }
        index = next
        continue
      }
      index = captured.index(after: index)
      if character == "\n" {
        endLine()
        continue
      }
      characters.append(character)
      isDim.append(dimActive)
    }
    endLine()

    self.lines = lines
    self.plainText = lines.map(\.text).joined(separator: "\n")
    self.containsAnyStyling = sawStyling
  }

  /// エスケープシーケンス1つ分を読み飛ばし、SGR ならその引数列を返す。
  /// CSI / OSC 以外の 2 バイト列と、末尾で途切れた列も呼び出し側から見て「読み飛ばす」に統一する。
  private static func skipEscapeSequence(
    _ captured: String, from start: String.Index
  ) -> (next: String.Index, sgr: Substring?) {
    let afterESC = captured.index(after: start)
    guard afterESC < captured.endIndex else { return (captured.endIndex, nil) }
    switch captured[afterESC] {
    case "[":
      var index = captured.index(after: afterESC)
      let parameterStart = index
      while index < captured.endIndex, !("\u{40}"..."\u{7e}").contains(captured[index]) {
        index = captured.index(after: index)
      }
      guard index < captured.endIndex else { return (captured.endIndex, nil) }
      let final = captured[index]
      let parameters = captured[parameterStart..<index]
      return (captured.index(after: index), final == "m" ? parameters : nil)
    case "]":
      // OSC は BEL または ST (ESC \) で終わる。OSC 8 のハイパーリンクが該当し、
      // 表示文字は列の外側にあるため列だけを落とす。
      var index = captured.index(after: afterESC)
      while index < captured.endIndex {
        if captured[index] == "\u{07}" { return (captured.index(after: index), nil) }
        if captured[index] == "\u{1b}" {
          let next = captured.index(after: index)
          if next < captured.endIndex, captured[next] == "\\" {
            return (captured.index(after: next), nil)
          }
        }
        index = captured.index(after: index)
      }
      return (captured.endIndex, nil)
    default:
      return (captured.index(after: afterESC), nil)
    }
  }

  /// SGR の引数列から dim (2) の有効/無効だけを取り出す。
  ///
  /// - Important: `38;5;2` のような拡張色の引数を dim と読み違えないよう、
  ///   38 / 48 / 58 の後続引数は個数を数えて読み飛ばす。
  private static func applySGR(_ parameters: Substring, to dimActive: Bool) -> Bool {
    let fields = parameters.split(separator: ";", omittingEmptySubsequences: false)
    guard !fields.isEmpty else { return false }
    var dim = dimActive
    var index = 0
    while index < fields.count {
      let field = fields[index]
      index += 1
      // コロン区切りの拡張色 (`38:5:244`) は1引数で完結するため、そのまま読み捨てる。
      guard !field.contains(":") else { continue }
      // 引数の省略 (`ESC[m` / `ESC[;m`) は 0 と同義 (ECMA-48)。
      guard let code = field.isEmpty ? 0 : Int(field) else { continue }
      switch code {
      case 0, 22: dim = false
      case 2: dim = true
      case 38, 48, 58:
        guard index < fields.count else { break }
        let kind = Int(fields[index]) ?? 0
        index += 1
        index += kind == 5 ? 1 : (kind == 2 ? 3 : 0)
      default: break
      }
    }
    return dim
  }
}
