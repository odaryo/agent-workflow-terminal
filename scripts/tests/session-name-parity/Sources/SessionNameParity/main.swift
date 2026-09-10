import Foundation
import TerminalCore

// 安定 ID の一覧を読み、`<何件目か>\t<session 名>` を 1 行ずつ出す。判定は行わない
// (突き合わせは scripts/check-session-name-parity.sh が bash 側の出力との diff で行う)。
//
// 安定 ID そのものを出力に載せないのは、不正な UTF-8 を含む入力を検査できるようにするため。
// こちらは lossy デコード後 (U+FFFD 化済み) の文字列を持つのに対し bash 側は生バイトのままなので、
// 安定 ID を並べると導出が一致していても必ずバイト差になる。突き合わせたいのは導出結果だけ。

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  fail("使い方: SessionNameParity <安定 ID の一覧ファイル>")
}

guard let data = FileManager.default.contents(atPath: arguments[1]) else {
  fail("一覧ファイルを読めません: \(arguments[1])")
}

var output = ""
var index = 0
for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
  let identifier = String(line)
  if identifier.isEmpty || identifier.hasPrefix("#") { continue }
  index += 1
  guard let identity = WorktreeIdentity(rawValue: identifier) else {
    fail("\(index) 件目の安定 ID が絶対パスではありません: \(identifier)")
  }
  output += "\(index)\t\(TmuxSessionName(identity: identity).rawValue)\n"
}
print(output, terminator: "")
