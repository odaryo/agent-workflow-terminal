import Foundation

public enum ShortcutAction: String, CaseIterable, Sendable, Hashable, Codable {
  case previousProject, nextProject, previousSession, nextSession
  case toggleOverview, toggleCodeViewer, toggleDiffViewer, toggleEvidenceViewer, bringAppToFront
}

public enum ShortcutKey: Hashable, Sendable, Codable {
  case character(String)
  case upArrow, downArrow, leftArrow, rightArrow, space
}

public enum ShortcutModifier: String, CaseIterable, Sendable, Hashable, Codable {
  case command, shift, option, control
}

public struct KeyCombination: Hashable, Sendable, Codable {
  public let key: ShortcutKey
  public let modifiers: Set<ShortcutModifier>

  public init(key: ShortcutKey, modifiers: Set<ShortcutModifier>) {
    if case .character(let character) = key {
      self.key =
        switch character {
        case " ": .space
        case "\u{F700}": .upArrow
        case "\u{F701}": .downArrow
        case "\u{F702}": .leftArrow
        case "\u{F703}": .rightArrow
        default: .character(character.lowercased())
        }
    } else {
      self.key = key
    }
    self.modifiers = modifiers
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      key: try container.decode(ShortcutKey.self, forKey: .key),
      modifiers: try container.decode(Set<ShortcutModifier>.self, forKey: .modifiers))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
  }

  private enum CodingKeys: String, CodingKey {
    case key, modifiers
  }
}

public enum ShortcutAssignmentError: Error, Equatable, Sendable {
  case unsupportedKey
  case commandModifierRequired
  case reserved
  case conflict(ShortcutAction)
}

public struct ShortcutBindings: Equatable, Sendable {
  public static let defaults: [ShortcutAction: KeyCombination] = Dictionary(
    uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultCombination) })

  // ⌘W / ⌘, / ⌘Q はアプリの固定操作、⌘C / ⌘V / ⌘X / ⌘A / ⌘Z / ⌘⇧Z は編集の標準操作なので割り当てられない。
  private static let reserved: Set<KeyCombination> = Set(
    ["w", ",", "q", "c", "v", "x", "a", "z"].map {
      KeyCombination(key: .character($0), modifiers: [.command])
    } + [KeyCombination(key: .character("z"), modifiers: [.command, .shift])])

  private var overrides: [ShortcutAction: KeyCombination] = [:]

  public init() {}

  public func combination(for action: ShortcutAction) -> KeyCombination {
    overrides[action] ?? action.defaultCombination
  }

  public func isDefault(_ action: ShortcutAction) -> Bool {
    overrides[action] == nil
  }

  public mutating func assign(
    _ combination: KeyCombination, to action: ShortcutAction
  )
    throws(ShortcutAssignmentError)
  {
    try Self.validate(combination)
    if let other = ShortcutAction.allCases.first(where: {
      $0 != action && self.combination(for: $0) == combination
    }) {
      throw .conflict(other)
    }
    overrides[action] = combination == action.defaultCombination ? nil : combination
  }

  public mutating func resetToDefault(_ action: ShortcutAction) throws(ShortcutAssignmentError) {
    try assign(action.defaultCombination, to: action)
  }

  public mutating func resetAll() {
    overrides.removeAll()
  }

  public func encoded() -> Data {
    let entries = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(entries)) ?? Data("{}".utf8)
  }

  public static func decoded(from data: Data?) -> (bindings: Self, droppedCount: Int) {
    guard let data,
      let entries = try? JSONDecoder().decode([String: StoredCombination].self, from: data)
    else { return (Self(), 0) }

    var bindings = Self()
    var droppedCount = 0
    for (name, entry) in entries {
      guard let action = ShortcutAction(rawValue: name), let combination = entry.combination else {
        droppedCount += 1
        continue
      }
      do {
        try validate(combination)
        if combination != action.defaultCombination {
          bindings.overrides[action] = combination
        }
      } catch {
        droppedCount += 1
      }
    }

    // 逐次 assign すると、別操作が復元時に手放す既定との一時的な競合で正常な変更も失う。
    var droppedConflict: Bool
    repeat {
      droppedConflict = false
      var seen: Set<KeyCombination> = []
      for action in ShortcutAction.allCases {
        let combination = bindings.combination(for: action)
        if bindings.overrides[action] != nil,
          seen.contains(combination)
            || ShortcutAction.allCases.contains(where: {
              $0 != action && bindings.overrides[$0] == nil && $0.defaultCombination == combination
            })
        {
          bindings.overrides[action] = nil
          droppedCount += 1
          droppedConflict = true
        }
        seen.insert(bindings.combination(for: action))
      }
    } while droppedConflict
    return (bindings, droppedCount)
  }

  private static func validate(_ combination: KeyCombination) throws(ShortcutAssignmentError) {
    if case .character(let character) = combination.key {
      guard character.unicodeScalars.count == 1,
        let scalar = character.unicodeScalars.first,
        (0x21...0x7E).contains(scalar.value)
      else {
        throw .unsupportedKey
      }
    }
    guard combination.modifiers.contains(.command) else {
      throw .commandModifierRequired
    }
    guard !reserved.contains(combination) else {
      throw .reserved
    }
  }

  private struct StoredCombination: Decodable {
    let combination: KeyCombination?

    init(from decoder: any Decoder) throws {
      combination = try? KeyCombination(from: decoder)
    }
  }
}

extension ShortcutAction {
  fileprivate var defaultCombination: KeyCombination {
    switch self {
    case .previousProject:
      KeyCombination(key: .upArrow, modifiers: [.command, .option])
    case .nextProject:
      KeyCombination(key: .downArrow, modifiers: [.command, .option])
    case .previousSession:
      KeyCombination(key: .leftArrow, modifiers: [.command, .option])
    case .nextSession:
      KeyCombination(key: .rightArrow, modifiers: [.command, .option])
    case .toggleOverview:
      KeyCombination(key: .character("o"), modifiers: [.command, .shift])
    case .toggleCodeViewer:
      KeyCombination(key: .character("c"), modifiers: [.command, .shift])
    case .toggleDiffViewer:
      KeyCombination(key: .character("d"), modifiers: [.command, .shift])
    case .toggleEvidenceViewer:
      KeyCombination(key: .character("e"), modifiers: [.command, .shift])
    case .bringAppToFront:
      KeyCombination(key: .space, modifiers: [.command])
    }
  }
}
