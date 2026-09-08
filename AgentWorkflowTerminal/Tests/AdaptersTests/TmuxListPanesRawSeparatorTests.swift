import Adapters
import Foundation
import TerminalCore
import Testing

/// tmux 3.7c は出力段の escape を行わず、format に埋めた Unit Separator を生 0x1F のまま出す
/// (3.4 と同一 format で並べて `od -c` 実測)。版を判定せず両方の区切りを受理する splitter の
/// 場合分けを、ここで版ごとに固定する。
@Suite("tmux 3.7c の生 Unit Separator 区切り")
struct TmuxListPanesRawSeparatorTests {
  @Test("tmux 3.7c の生 0x1F 区切りから pane を復元する")
  func parsesRawUnitSeparatorFixture() throws {
    // 採取: tmux 3.7c (homebrew bottle を /private/tmp/tmux37b へ隔離展開したもの。CI と同一
    // バイナリ) / `TMUX_TMPDIR=/private/tmp/fr-bottle`, socket `sbottle`。
    // `mkdir "$root/dir\037x-日本語🚀"`
    // `tmux -L sbottle -u new-session -d -s escaped-37c -c <上記path>
    //   "printf '\033]2;題名🚀\007'; exec sleep 300"`
    // `tmux -L sbottle -u list-panes -t escaped-37c -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.7c-list-panes-escaped-path.txt")
    )
    let pane = try #require(result.panes.first)

    #expect(result.failures.isEmpty)
    #expect(result.panes.count == 1)
    #expect(pane.paneID == PaneID(rawValue: "%0"))
    #expect(pane.sessionName == "escaped-37c")
    #expect(pane.windowIndex == 0)
    #expect(pane.windowID == "@0")
    #expect(pane.paneIndex == 0)
    #expect(pane.panePID == 6970)
    #expect(pane.isActive)
    #expect(pane.currentCommand == "sleep")
    #expect(pane.termination == nil)
    #expect(pane.tty == "/dev/ttys031")
    // 値に含まれるリテラル `\037` (4文字) は置換で `\\037` になり区切りにならない。3.4 の
    // 同名 fixture と同じ path を、区切りの形だけが違う出力から同じ値へ戻せている。
    #expect(pane.currentPath == #"/private/tmp/fr-bottle/dir\037x-日本語🚀"#)
    #expect(pane.title == "題名🚀")
  }

  @Test("tmux 3.7c の display-message 出力から agent pane の title を復元する")
  func parsesAgentPaneStatusFromRawUnitSeparatorFixture() throws {
    // 採取: 上と同じ server / pane。
    // `tmux -L sbottle -u display-message -p -t %0 -F "$agentPaneStatusFormat"`
    let status = try TmuxListPanes.parseAgentPaneStatus(
      output: try fixture(named: "tmux-3.7c-display-message-agent-pane-status.txt")
    )

    #expect(status.paneID == PaneID(rawValue: "%0"))
    #expect(status.title == "題名🚀")
  }

  @Test("tmux 3.7c の session 名の backslash 列は偶数のまま復号する")
  func decodesBackslashSessionNameFromRawUnitSeparatorFixture() throws {
    // 採取: 上と同じ server。`tmux -L sbottle -u new-session -d -s 'host\$1\name'
    //   -P -F '#{pane_id}' 'sleep 300'` の pane を `list-panes -t <pane> -F "$format"`。
    // 3.4 の hostile fixture と違い 3.7c は TAB / LF / 0x1F を含む session 名を
    // `invalid session name` で拒否するため、backslash と `$` だけを残した。
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.7c-list-panes-backslash-session.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(result.panes.first?.sessionName == #"host\\$1\\name"#)
  }

  @Test("tmux 3.7c は $ の前に backslash を足さないので偶数列のまま復号する")
  func decodesDollarPatternSessionsFromRawUnitSeparatorFixture() throws {
    // 採取: 上と同じ server。3.4 の同名 fixture と同じ13個の session 名を作り
    // `list-panes -a -F "$format"`。
    //
    // 3.4 は保存段で `$` の前にも `\` を足すため `bsletter` が奇数列 (`\`7個) になるが、
    // 3.7c は足さないので4個 = 偶数のまま出る (`#{s/\\/Q/:#{s/\$/D/:session_name}}` で
    // 保存段だけを取り出して両版を比較)。復号後の名前が版で違うのはこのためで、どちらも
    // その版の `has-session -t` が要求する正式名。
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.7c-list-panes-dollar-pattern-sessions.txt")
    )

    #expect(result.failures.isEmpty)
    #expect(
      result.panes.map(\.sessionName)
        == [
          #"brace${x}"#,
          #"bsemoji\\$😀"#,
          #"bshebrew\\$א"#,
          #"bsletter\\$a"#,
          #"digit\\$1"#,
          "double$$",
          "emoji$😀",
          "hebrew$א",
          "japanese$日",
          "letter$a",
          "symbol$-",
          "terminal$",
          "under$_",
        ]
    )
  }

  @Test("tmux 3.7c でも値の中の実 0x1F は区切り衝突として failure にする")
  func rejectsRawUnitSeparatorCollisionFixture() throws {
    // 採取: 上と同じ server。`mkdir "$root/collision/$(printf 'p\037q')"`
    // `tmux -L sbottle -u new-session -d -s collision-path -c <上記path> 'sleep 300'`
    // `tmux -L sbottle -u list-panes -t collision-path -F "$format"`
    let result = TmuxListPanes.parse(
      output: try fixture(named: "tmux-3.7c-list-panes-unit-separator-path.txt")
    )

    #expect(result.panes.isEmpty)
    #expect(result.failures.map(\.error) == [.invalidFieldCount(actual: 15)])
  }

  @Test("生 0x1F 区切りでも直前の二重化 backslash をフィールドの値として残す")
  func rawSeparatorDoesNotConsumePrecedingDoubledBackslash() throws {
    let pane = try TmuxListPanes.parse(
      line: rawSeparatorLine(currentCommand: #"cmd\\"#)
    )

    #expect(pane.currentCommand == #"cmd\"#)
  }

  @Test("生 0x1F 区切りは先頭・末尾・連続でも空フィールドを保つ")
  func rawSeparatorKeepsEmptyFields() throws {
    // dead_status / dead_signal が連続する空フィールドで、tty が空、title が行末の空。
    let pane = try TmuxListPanes.parse(
      line: rawSeparatorLine(tty: "", title: "")
    )

    #expect(pane.tty.isEmpty)
    #expect(pane.title.isEmpty)
    #expect(pane.termination == nil)

    // 先頭が空になるのは pane_id が空のときだけで、フィールド数は保たれる。
    #expect(throws: TmuxListPanesParseError.invalidPaneID("")) {
      try TmuxListPanes.parse(line: rawSeparatorLine(paneID: ""))
    }
  }

  @Test("3.4 の奇数 backslash 区切りと 3.7c の生 0x1F 区切りを同じ行内で受理する")
  func acceptsBothSeparatorFormsInOneLine() throws {
    // 版の混在は実出力には現れないが、片方の受理がもう片方を弱めていないことをここで固定する。
    let fields = [
      "%0", "session", "0", "@0", "0", "123", "1", "zsh", "0", "", "", "/dev/ttys000",
      "/tmp", "title",
    ]
    var mixed = fields[0]
    for (offset, field) in fields.dropFirst().enumerated() {
      mixed += (offset.isMultiple(of: 2) ? "\u{1F}" : "\\037") + field
    }

    #expect(try TmuxListPanes.parse(line: mixed).sessionName == "session")
  }

  @Test("3.4 の区切り判定は直前の backslash 列の偶奇だけで決まる")
  func backslashParityDecidesEncodedSeparator() throws {
    // 偶数列 (置換由来) で終わる値の直後の `\037` は区切りのまま。
    let pane = try TmuxListPanes.parse(line: encodedLine(currentCommand: #"zsh\\"#))
    #expect(pane.currentCommand == #"zsh\"#)

    // 奇数列で終わる値は直後の区切りと `\\` の対を作り、区切りが1つ消えて13フィールドになる。
    // 実出力でこの形になるのは値が実 0x1F を含むときだけで、その pane は failure に落ちる。
    #expect(throws: TmuxListPanesParseError.invalidFieldCount(actual: 13)) {
      try TmuxListPanes.parse(line: encodedLine(currentCommand: #"zsh\"#))
    }
  }

  @Test("生 0x1F 区切りは直前の奇数 backslash 列に飲まれない")
  func rawSeparatorSurvivesOddBackslashRun() {
    // 3.4 の `\037` と違い生 0x1F は `\` と対を作れないため、フィールド数はずれず、
    // ありえない奇数列は復号の失敗として現れる。
    #expect(throws: TmuxListPanesParseError.invalidRawFieldEscape(#"zsh\"#)) {
      try TmuxListPanes.parse(line: rawSeparatorLine(currentCommand: #"zsh\"#))
    }
  }

  /// 3.7c 実出力と同じく生 0x1F で区切る。既定値は 3.4 の `encodedLine` と揃える。
  private func rawSeparatorLine(
    paneID: String = "%0",
    currentCommand: String = "zsh",
    tty: String = "/dev/ttys000",
    title: String = "title"
  ) -> String {
    [
      paneID, "session", "0", "@0", "0", "123", "1", currentCommand, "0", "", "",
      tty, "/tmp", title,
    ].joined(separator: "\u{1F}")
  }

  /// 3.4 実出力と同じく奇数 backslash + `037` で区切る。
  private func encodedLine(currentCommand: String) -> String {
    [
      "%0", "session", "0", "@0", "0", "123", "1", currentCommand, "0", "", "",
      "/dev/ttys000", "/tmp", "title",
    ].joined(separator: "\\037")
  }

  private func fixture(named name: String) throws -> String {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    )
    return try String(contentsOf: fixtureURL, encoding: .utf8)
  }
}
