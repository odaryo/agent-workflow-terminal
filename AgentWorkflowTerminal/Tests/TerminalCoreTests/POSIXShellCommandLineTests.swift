import Foundation
import TerminalCore
import Testing

@Suite("POSIX shell command line の符号化")
struct POSIXShellCommandLineTests {
  @Test(
    "各 argv 要素を shell の単語へ符号化する",
    arguments: [
      (["/bin/zsh"], "'/bin/zsh'"),
      (["two words"], "'two words'"),
      (["it's"], "'it'\\''s'"),
      (
        ["$HOME", "`date`", ";", "&&", "|", "*", "~"],
        "'$HOME' '`date`' ';' '&&' '|' '*' '~'"
      ),
      (["line\nbreak", "tab\tvalue"], "'line\nbreak' 'tab\tvalue'"),
      (["", "日本語"], "'' '日本語'"),
    ]
  )
  func commandLineRepresentation(argv: [String], expected: String) {
    #expect(POSIXShellCommandLine.joined(argv) == expected)
  }

  @Test("bash が符号化済み command line から argv を復元する")
  func restoresArgumentsWithBash() throws {
    let values = [
      "two words", "it's", "$HOME", "`date`", ";", "&&", "|", "*", "~",
      "line\nbreak", "tab\tvalue", "", "日本語",
    ]
    let command = POSIXShellCommandLine.joined(["/usr/bin/printf", "%s\\n"] + values)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["--noprofile", "--norc", "-c", command]
    process.standardOutput = output
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let actual = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(actual == values.map { "\($0)\n" }.joined())
  }

  @Test("libghostty の exec -l 前置後も引数を復元する")
  func restoresArgumentsWithLoginExecPrefix() throws {
    let values = ["two words", "it's", "$HOME"]
    let innerCommand = POSIXShellCommandLine.joined(
      [
        "/bin/bash", "--noprofile", "--norc", "-c",
        "printf '%s\\n' \"$0\" \"$@\"", "argv zero",
      ] + values)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(innerCommand)"]
    process.standardOutput = output
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let actual = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    // Why not `-argv zero`: login shell の bash は argv[0] の先頭の `-` を login 状態として
    // 解釈し、`-c` の明示的な command name は `$0` にそのまま公開する。
    #expect(actual == (["argv zero"] + values).map { "\($0)\n" }.joined())
  }
}
