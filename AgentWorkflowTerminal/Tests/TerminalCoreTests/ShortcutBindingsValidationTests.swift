import Foundation
import TerminalCore
import Testing

private enum ShortcutValidationFixtures {
  static let unsupportedCharacters = [
    "", "ab", "😀", "é", "Ｗ", "\0", "\t", "\n", "\u{1B}", "\u{7F}",
  ]
  static let aliases: [(String, ShortcutKey)] = [
    (" ", .space), ("\u{F700}", .upArrow), ("\u{F701}", .downArrow),
    ("\u{F702}", .leftArrow), ("\u{F703}", .rightArrow),
  ]
  static let custom = KeyCombination(key: .character("k"), modifiers: [.command, .control])

  static func decoded(_ json: String) -> (bindings: ShortcutBindings, droppedCount: Int) {
    ShortcutBindings.decoded(from: Data(json.utf8))
  }
}

@Suite("ショートカットの物理キーの正規化と入力検証 (設計書 §5.4)")
struct ShortcutBindingsValidationTests {
  @Test("特殊キーの文字表現は専用の値と等値かつ同じハッシュになる", arguments: ShortcutValidationFixtures.aliases)
  func normalizesSpecialCharacters(character: String, key: ShortcutKey) {
    let alias = KeyCombination(key: .character(character), modifiers: [.command])
    let canonical = KeyCombination(key: key, modifiers: [.command])
    #expect(alias.key == key)
    #expect(alias == canonical)
    #expect(Set([alias, canonical]).count == 1)
  }

  @Test("文字のSpaceも前面表示の既定と競合し状態を保つ")
  func rejectsSpaceAliasConflict() throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutValidationFixtures.custom, to: .toggleOverview)
    let before = bindings
    #expect(throws: ShortcutAssignmentError.conflict(.bringAppToFront)) {
      try bindings.assign(
        KeyCombination(key: .character(" "), modifiers: [.command]), to: .toggleOverview)
    }
    #expect(bindings == before)
  }

  @Test(
    "未対応の文字は⌘の有無にかかわらずunsupportedKeyで状態を保つ",
    arguments: ShortcutValidationFixtures.unsupportedCharacters,
    [Set<ShortcutModifier>(), [.command]])
  func rejectsUnsupportedCharacter(character: String, modifiers: Set<ShortcutModifier>) throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutValidationFixtures.custom, to: .toggleOverview)
    let before = bindings
    #expect(throws: ShortcutAssignmentError.unsupportedKey) {
      try bindings.assign(
        KeyCombination(key: .character(character), modifiers: modifiers), to: .toggleOverview)
    }
    #expect(bindings == before)
  }

  @Test("ASCII表示文字の両端と数字は割り当てられる", arguments: ["!", "~", "1"])
  func acceptsPrintableASCII(character: String) throws {
    var bindings = ShortcutBindings()
    let combination = KeyCombination(key: .character(character), modifiers: [.command])
    try bindings.assign(combination, to: .toggleOverview)
    #expect(bindings.combination(for: .toggleOverview) == combination)
    #expect(!bindings.isDefault(.toggleOverview))
  }
}

@Suite("ショートカットの不正な保存値の部分復元 (設計書 §5.4)")
struct ShortcutBindingsPartialDecodingTests {
  @Test(
    "トップレベルが辞書でないJSONは破棄数0の既定になる",
    arguments: ["[]", "[1]", "null", "42", "true", #""text""#])
  func nonDictionaryUsesDefaults(json: String) {
    let result = ShortcutValidationFixtures.decoded(json)
    #expect(result.bindings == ShortcutBindings())
    #expect(result.droppedCount == 0)
  }

  @Test(
    "値を読めない操作だけを数えほかの割り当てを残す",
    arguments: [
      "42",
      #"{"key":"k","modifiers":["command"]}"#,
      #"{"key":{"character":{"_0":"k"}},"modifiers":["command","hyper"]}"#,
      #"{"key":{"character":{"_0":"k"}}}"#,
      #"{"key":{"tab":{}},"modifiers":["command"]}"#,
    ])
  func dropsOnlyUnreadableEntry(value: String) throws {
    let json = """
      {
        "toggleOverview": \(value),
        "bringAppToFront": {
          "key": {"character": {"_0": "k"}}, "modifiers": ["command", "control"]
        }
      }
      """
    let result = ShortcutValidationFixtures.decoded(json)
    var expected = ShortcutBindings()
    try expected.assign(ShortcutValidationFixtures.custom, to: .bringAppToFront)
    #expect(result.droppedCount == 1)
    #expect(result.bindings == expected)
    #expect(result.bindings.isDefault(.toggleOverview))
    #expect(!result.bindings.isDefault(.bringAppToFront))
  }

  @Test(
    "保存された未対応の文字だけを数え既定へ戻す",
    arguments: ShortcutValidationFixtures.unsupportedCharacters)
  func dropsUnsupportedCharacter(character: String) throws {
    let encodedCharacter = try JSONEncoder().encode(character)
    let value = String(decoding: encodedCharacter, as: UTF8.self)
    let json = """
      {
        "toggleOverview": {
          "key": {"character": {"_0": \(value)}}, "modifiers": ["command"]
        },
        "bringAppToFront": {
          "key": {"character": {"_0": "k"}}, "modifiers": ["command", "control"]
        }
      }
      """
    let result = ShortcutValidationFixtures.decoded(json)
    var expected = ShortcutBindings()
    try expected.assign(ShortcutValidationFixtures.custom, to: .bringAppToFront)
    #expect(result.droppedCount == 1)
    #expect(result.bindings == expected)
    #expect(result.bindings.isDefault(.toggleOverview))
  }
}

@Suite("ショートカットの保存順序と競合復元の回帰 (設計書 §5.4)")
struct ShortcutBindingsPersistenceEdgeTests {
  @Test("割り当て順によらずキーと修飾キーを整列した同じバイト列で保存する")
  func encodesDeterministically() throws {
    let first = KeyCombination(
      key: .character("k"), modifiers: [.shift, .option, .control, .command])
    let second = KeyCombination(
      key: .character("j"), modifiers: [.shift, .command, .control])
    var forward = ShortcutBindings()
    try forward.assign(first, to: .previousProject)
    try forward.assign(second, to: .bringAppToFront)
    var backward = ShortcutBindings()
    try backward.assign(
      KeyCombination(key: .character("j"), modifiers: [.control, .command, .shift]),
      to: .bringAppToFront)
    try backward.assign(
      KeyCombination(key: .character("k"), modifiers: [.command, .control, .option, .shift]),
      to: .previousProject)
    #expect(forward == backward)
    #expect(forward.encoded() == backward.encoded())
    let expected =
      #"{"bringAppToFront":{"key":{"character":{"_0":"j"}},"modifiers":["command","control","shift"]},"#
      + #""previousProject":{"key":{"character":{"_0":"k"}},"modifiers":["command","control","option","shift"]}}"#
    #expect(forward.encoded() == Data(expected.utf8))
    #expect(backward.encoded() == Data(expected.utf8))
  }

  @Test("後ろの操作の既定と競合する先の操作の変更を1件破棄する")
  func dropsConflictWithLaterDefault() {
    let result = ShortcutValidationFixtures.decoded(
      #"{"previousProject":{"key":{"character":{"_0":"o"}},"modifiers":["command","shift"]}}"#)
    #expect(result.droppedCount == 1)
    #expect(result.bindings == ShortcutBindings())
    #expect(result.bindings.isDefault(.previousProject))
  }

  @Test("重複の破棄で復活した既定との競合も再検査し2件破棄する")
  func rechecksConflictsAfterRestoringDefault() throws {
    let json = """
      {
        "previousProject": {
          "key": {"character": {"_0": "t"}}, "modifiers": ["command", "shift"]
        },
        "nextProject": {
          "key": {"character": {"_0": "o"}}, "modifiers": ["command", "shift"]
        },
        "toggleOverview": {
          "key": {"character": {"_0": "t"}}, "modifiers": ["command", "shift"]
        }
      }
      """
    let result = ShortcutValidationFixtures.decoded(json)
    var expected = ShortcutBindings()
    let surviving = KeyCombination(key: .character("t"), modifiers: [.command, .shift])
    try expected.assign(surviving, to: .previousProject)
    #expect(result.droppedCount == 2)
    #expect(result.bindings == expected)
    #expect(result.bindings.combination(for: .previousProject) == surviving)
    #expect(!result.bindings.isDefault(.previousProject))
    #expect(result.bindings.isDefault(.nextProject))
    #expect(result.bindings.isDefault(.toggleOverview))
  }

  @Test("明示された既定は破棄せず既定として扱う")
  func explicitDefaultIsNotAnOverride() {
    let result = ShortcutValidationFixtures.decoded(
      #"{"toggleOverview":{"key":{"character":{"_0":"o"}},"modifiers":["command","shift"]}}"#)
    #expect(result.droppedCount == 0)
    #expect(result.bindings == ShortcutBindings())
    #expect(result.bindings.isDefault(.toggleOverview))
  }

  @Test("JSONの大文字Wも予約キーとして1件破棄する")
  func dropsUppercaseReservedKey() {
    let result = ShortcutValidationFixtures.decoded(
      #"{"toggleOverview":{"key":{"character":{"_0":"W"}},"modifiers":["command"]}}"#)
    #expect(result.droppedCount == 1)
    #expect(result.bindings == ShortcutBindings())
    #expect(result.bindings.isDefault(.toggleOverview))
  }
}
