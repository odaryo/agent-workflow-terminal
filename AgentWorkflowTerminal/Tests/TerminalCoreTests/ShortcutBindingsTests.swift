import Foundation
import TerminalCore
import Testing

private enum ShortcutFixtures {
  static let defaults: [(ShortcutAction, KeyCombination)] = [
    (.previousProject, KeyCombination(key: .upArrow, modifiers: [.command, .option])),
    (.nextProject, KeyCombination(key: .downArrow, modifiers: [.command, .option])),
    (.previousSession, KeyCombination(key: .upArrow, modifiers: [.command])),
    (.nextSession, KeyCombination(key: .downArrow, modifiers: [.command])),
    (.toggleOverview, KeyCombination(key: .character("o"), modifiers: [.command, .shift])),
    (.toggleCodeViewer, KeyCombination(key: .character("c"), modifiers: [.command, .shift])),
    (.toggleDiffViewer, KeyCombination(key: .character("d"), modifiers: [.command, .shift])),
    (.bringAppToFront, KeyCombination(key: .space, modifiers: [.command])),
    (.newSessionWithAgent, KeyCombination(key: .character("n"), modifiers: [.command, .shift])),
  ]
  static let custom = KeyCombination(key: .character("k"), modifiers: [.command, .control])
  static let otherCustom = KeyCombination(key: .character("j"), modifiers: [.command, .option])
  static let reserved =
    ["w", ",", "q", "c", "v", "x", "a", "z"].map {
      KeyCombination(key: .character($0), modifiers: [.command])
    } + [KeyCombination(key: .character("z"), modifiers: [.command, .shift])]

  static func data(_ entries: [String: KeyCombination]) throws -> Data {
    try JSONEncoder().encode(entries)
  }
}

@Suite("ショートカットの既定とキーの正規化 (設計書 §5.4)")
struct ShortcutBindingsDefaultsTests {
  @Test("各操作の既定と初期状態が仕様どおり", arguments: ShortcutFixtures.defaults)
  func defaultCombination(action: ShortcutAction, expected: KeyCombination) {
    let bindings = ShortcutBindings()
    #expect(ShortcutBindings.defaults[action] == expected)
    #expect(bindings.combination(for: action) == expected)
    #expect(bindings.isDefault(action))
  }

  @Test("全操作に重複のない既定がある")
  func defaultsAreCompleteAndUnique() {
    #expect(Set(ShortcutBindings.defaults.keys) == Set(ShortcutAction.allCases))
    #expect(Set(ShortcutBindings.defaults.values).count == ShortcutAction.allCases.count)
  }

  @Test("文字キーは小文字に揃い等値性とハッシュも一致する", arguments: ["O", "C", "Z"])
  func normalizesCharacter(character: String) {
    let upper = KeyCombination(key: .character(character), modifiers: [.command, .shift])
    let lower = KeyCombination(
      key: .character(character.lowercased()), modifiers: [.shift, .command])
    #expect(upper.key == .character(character.lowercased()))
    #expect(upper == lower)
    #expect(Set([upper, lower]).count == 1)
  }

  @Test(
    "文字以外のキーと全修飾キーを保持する",
    arguments: [
      ShortcutKey.upArrow, .downArrow, .leftArrow, .rightArrow, .space,
    ])
  func preservesSpecialKeys(key: ShortcutKey) {
    let modifiers = Set(ShortcutModifier.allCases)
    let combination = KeyCombination(key: key, modifiers: modifiers)
    #expect(combination.key == key)
    #expect(combination.modifiers == modifiers)
  }
}

@Suite("ショートカットの割り当てとリセット (設計書 §5.4)")
struct ShortcutBindingsAssignmentTests {
  @Test(
    "⌘のない組は予約キーと同じ文字でも拒否し状態を保つ",
    arguments: [
      Set<ShortcutModifier>(), [.shift], [.option], [.control], [.shift, .option, .control],
    ])
  func requiresCommand(modifiers: Set<ShortcutModifier>) throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutFixtures.custom, to: .toggleOverview)
    let before = bindings
    let combination = KeyCombination(key: .character("z"), modifiers: modifiers)
    #expect(throws: ShortcutAssignmentError.commandModifierRequired) {
      try bindings.assign(combination, to: .toggleOverview)
    }
    #expect(bindings == before)
  }

  @Test("予約された組は拒否し状態を保つ", arguments: ShortcutFixtures.reserved)
  func rejectsReserved(combination: KeyCombination) throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutFixtures.custom, to: .toggleOverview)
    let before = bindings
    #expect(throws: ShortcutAssignmentError.reserved) {
      try bindings.assign(combination, to: .toggleOverview)
    }
    #expect(bindings == before)
  }

  @Test("別操作の既定との競合を相手つきで返し状態を保つ", arguments: ShortcutFixtures.defaults)
  func rejectsDefaultConflict(owner: ShortcutAction, combination: KeyCombination) {
    var bindings = ShortcutBindings()
    let target: ShortcutAction = owner == .toggleOverview ? .toggleCodeViewer : .toggleOverview
    let before = bindings
    #expect(throws: ShortcutAssignmentError.conflict(owner)) {
      try bindings.assign(combination, to: target)
    }
    #expect(bindings == before)
  }

  @Test("変更済みの別操作との競合も拒否し状態を保つ")
  func rejectsCustomConflict() throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutFixtures.custom, to: .nextSession)
    let before = bindings
    #expect(throws: ShortcutAssignmentError.conflict(.nextSession)) {
      try bindings.assign(ShortcutFixtures.custom, to: .toggleOverview)
    }
    #expect(bindings == before)
  }

  @Test("自分の現在の組の再指定は成功する", arguments: ShortcutFixtures.defaults)
  func reassignsCurrent(action: ShortcutAction, combination: KeyCombination) throws {
    var bindings = ShortcutBindings()
    try bindings.assign(combination, to: action)
    #expect(bindings.combination(for: action) == combination)
    try bindings.assign(ShortcutFixtures.custom, to: action)
    try bindings.assign(ShortcutFixtures.custom, to: action)
    #expect(bindings.combination(for: action) == ShortcutFixtures.custom)
    #expect(!bindings.isDefault(action))
  }

  @Test("成功した割り当てだけを変え既定との一致を判定する", arguments: ShortcutFixtures.defaults)
  func assignsAndRestoresDefault(action: ShortcutAction, combination: KeyCombination) throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutFixtures.custom, to: action)
    #expect(bindings.combination(for: action) == ShortcutFixtures.custom)
    #expect(!bindings.isDefault(action))
    for (other, expected) in ShortcutFixtures.defaults where other != action {
      #expect(bindings.combination(for: other) == expected)
      #expect(bindings.isDefault(other))
    }
    try bindings.assign(combination, to: action)
    #expect(bindings.combination(for: action) == combination)
    #expect(bindings.isDefault(action))
    #expect(bindings == ShortcutBindings())
  }

  @Test("操作ごとに既定へ戻し他の変更は保持する", arguments: ShortcutFixtures.defaults)
  func resetsOne(action: ShortcutAction, combination: KeyCombination) throws {
    var bindings = ShortcutBindings()
    let other: ShortcutAction = action == .nextProject ? .previousProject : .nextProject
    try bindings.assign(ShortcutFixtures.custom, to: action)
    try bindings.assign(ShortcutFixtures.otherCustom, to: other)
    try bindings.resetToDefault(action)
    #expect(bindings.combination(for: action) == combination)
    #expect(bindings.isDefault(action))
    #expect(bindings.combination(for: other) == ShortcutFixtures.otherCustom)
    #expect(!bindings.isDefault(other))
  }

  @Test("戻す既定が使われていれば競合として状態を保つ")
  func resetRejectsConflict() throws {
    var bindings = ShortcutBindings()
    let original = KeyCombination(key: .character("o"), modifiers: [.command, .shift])
    try bindings.assign(ShortcutFixtures.custom, to: .toggleOverview)
    try bindings.assign(original, to: .toggleCodeViewer)
    let before = bindings
    #expect(throws: ShortcutAssignmentError.conflict(.toggleCodeViewer)) {
      try bindings.resetToDefault(.toggleOverview)
    }
    #expect(bindings == before)
  }

  @Test("全リセットは他操作が既定を使っていてもすべて戻す")
  func resetsAll() throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutFixtures.custom, to: .toggleOverview)
    try bindings.assign(
      KeyCombination(key: .character("o"), modifiers: [.command, .shift]), to: .toggleCodeViewer)
    bindings.resetAll()
    #expect(bindings == ShortcutBindings())
    for (action, expected) in ShortcutFixtures.defaults {
      #expect(bindings.combination(for: action) == expected)
      #expect(bindings.isDefault(action))
    }
  }
}

@Suite("ショートカットの保存と部分復元 (設計書 §5.4)")
struct ShortcutBindingsPersistenceTests {
  @Test("既定は空のJSON辞書として保存する")
  func encodesOnlyOverrides() throws {
    let entries = try JSONDecoder().decode(
      [String: KeyCombination].self, from: ShortcutBindings().encoded())
    #expect(entries.isEmpty)
  }

  @Test("変更分だけ保存し往復で等しい")
  func roundTripsOverrides() throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutFixtures.custom, to: .previousProject)
    try bindings.assign(ShortcutFixtures.otherCustom, to: .bringAppToFront)
    let entries = try JSONDecoder().decode([String: KeyCombination].self, from: bindings.encoded())
    #expect(
      entries == [
        "previousProject": ShortcutFixtures.custom, "bringAppToFront": ShortcutFixtures.otherCustom,
      ])
    let result = ShortcutBindings.decoded(from: bindings.encoded())
    #expect(result.bindings == bindings)
    #expect(result.bindings.combination(for: .previousProject) == ShortcutFixtures.custom)
    #expect(result.bindings.combination(for: .bringAppToFront) == ShortcutFixtures.otherCustom)
    #expect(result.droppedCount == 0)
  }

  @Test("既定へ戻した割り当ては保存しない")
  func omitsRestoredDefault() throws {
    var bindings = ShortcutBindings()
    try bindings.assign(ShortcutFixtures.custom, to: .toggleOverview)
    try bindings.resetToDefault(.toggleOverview)
    let entries = try JSONDecoder().decode([String: KeyCombination].self, from: bindings.encoded())
    #expect(entries.isEmpty)
  }

  @Test(
    "nilと読めないJSONは破棄数0の既定になる",
    arguments: [
      nil, Data(), Data("{broken".utf8), Data("{\"previousProject\":".utf8),
    ] as [Data?])
  func unreadableDataUsesDefaults(data: Data?) {
    let result = ShortcutBindings.decoded(from: data)
    #expect(result.bindings == ShortcutBindings())
    #expect(result.droppedCount == 0)
  }

  @Test("空辞書は破棄数0の既定になる")
  func emptyDictionaryUsesDefaults() throws {
    let result = ShortcutBindings.decoded(from: try ShortcutFixtures.data([:]))
    #expect(result.bindings == ShortcutBindings())
    #expect(result.droppedCount == 0)
  }

  @Test("既定と同じ値の保存は変更なし・破棄0件として読む")
  func storedDefaultsAreNotOverrides() throws {
    let data = try ShortcutFixtures.data([
      "previousSession": KeyCombination(key: .upArrow, modifiers: [.command]),
      "nextSession": KeyCombination(key: .downArrow, modifiers: [.command]),
    ])
    let result = ShortcutBindings.decoded(from: data)
    #expect(result.bindings == ShortcutBindings())
    #expect(result.droppedCount == 0)
  }

  @Test("未知の操作は件数に数え正常な割り当ては復元する")
  func dropsUnknownActions() throws {
    let data = try ShortcutFixtures.data([
      "futureAction": ShortcutFixtures.custom, "anotherFutureAction": ShortcutFixtures.otherCustom,
      "toggleOverview": ShortcutFixtures.custom,
    ])
    let result = ShortcutBindings.decoded(from: data)
    #expect(result.droppedCount == 2)
    #expect(result.bindings.combination(for: .toggleOverview) == ShortcutFixtures.custom)
    #expect(!result.bindings.isDefault(.toggleOverview))
  }

  @Test(
    "⌘なしと予約の割り当てを破棄し既定へ戻す",
    arguments:
      ShortcutFixtures.reserved + [
        KeyCombination(key: .character("k"), modifiers: []),
        KeyCombination(key: .upArrow, modifiers: [.control, .option]),
      ])
  func dropsInvalidCombination(combination: KeyCombination) throws {
    let data = try ShortcutFixtures.data([
      "toggleOverview": combination, "bringAppToFront": ShortcutFixtures.custom,
    ])
    let result = ShortcutBindings.decoded(from: data)
    #expect(result.droppedCount == 1)
    #expect(
      result.bindings.combination(for: .toggleOverview)
        == KeyCombination(key: .character("o"), modifiers: [.command, .shift]))
    #expect(result.bindings.isDefault(.toggleOverview))
    #expect(result.bindings.combination(for: .bringAppToFront) == ShortcutFixtures.custom)
  }

  @Test("重複はJSONの順序に関係なくallCasesで先の操作を残す", arguments: [false, true])
  func dropsDuplicateInActionOrder(reversed: Bool) throws {
    let encoded = try JSONEncoder().encode(ShortcutFixtures.custom)
    let value = String(decoding: encoded, as: UTF8.self)
    let earlier = "\"previousProject\":\(value)"
    let later = "\"bringAppToFront\":\(value)"
    let json = reversed ? "{\(later),\(earlier)}" : "{\(earlier),\(later)}"
    let result = ShortcutBindings.decoded(from: Data(json.utf8))
    #expect(result.droppedCount == 1)
    #expect(result.bindings.combination(for: .previousProject) == ShortcutFixtures.custom)
    #expect(!result.bindings.isDefault(.previousProject))
    #expect(
      result.bindings.combination(for: .bringAppToFront)
        == KeyCombination(key: .space, modifiers: [.command]))
    #expect(result.bindings.isDefault(.bringAppToFront))
  }

  @Test("変更されていない操作の既定と競合した割り当ても破棄する")
  func dropsConflictWithUnchangedDefault() throws {
    let data = try ShortcutFixtures.data([
      "bringAppToFront": KeyCombination(key: .upArrow, modifiers: [.command, .option])
    ])
    let result = ShortcutBindings.decoded(from: data)
    #expect(result.droppedCount == 1)
    #expect(result.bindings == ShortcutBindings())
  }
}
