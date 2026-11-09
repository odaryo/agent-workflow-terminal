public struct HighlightJSRun: Equatable, Sendable {
  public let text: String
  public let scopes: [[String]]

  public init(text: String, scopes: [[String]]) {
    self.text = text
    self.scopes = scopes
  }
}

public enum HighlightJSMarkup: Sendable {
  public static func parse(_ html: String) -> [HighlightJSRun]? {
    var parser = HighlightJSMarkupParser(bytes: Array(html.utf8))
    return parser.parse()
  }
}

private struct HighlightJSMarkupParser {
  private static let entities: [(String, UInt8)] = [
    ("&amp;", 0x26), ("&lt;", 0x3C), ("&gt;", 0x3E), ("&quot;", 0x22), ("&#x27;", 0x27),
  ]

  private struct Scope {
    let classes: [String]
    let parent: Int?
  }

  let bytes: [UInt8]
  private var offset = 0
  private var scopes: [Scope] = []
  private var currentScope: Int?
  private var text: [UInt8] = []
  private var runs: [HighlightJSRun] = []

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  mutating func parse() -> [HighlightJSRun]? {
    while offset < bytes.count {
      switch bytes[offset] {
      case 0x3C:
        flushText()
        guard consumeTag() else { return nil }
      case 0x3E:
        return nil
      case 0x26:
        guard consumeEntity() else { return nil }
      default:
        text.append(bytes[offset])
        offset += 1
      }
    }
    guard currentScope == nil else { return nil }
    flushText()
    return runs
  }

  private mutating func consumeTag() -> Bool {
    if consume("</span>") {
      guard let currentScope else { return false }
      self.currentScope = scopes[currentScope].parent
      return true
    }
    guard consume("<span class=\"") else { return false }
    let start = offset
    while offset < bytes.count && bytes[offset] != 0x22 {
      guard ![0x3C, 0x3E, 0x26].contains(bytes[offset]) else { return false }
      offset += 1
    }
    let end = offset
    guard consume("\">") else { return false }
    let classes = bytes[start..<end].split(whereSeparator: Self.isWhitespace).map {
      String(decoding: $0, as: UTF8.self)
    }
    scopes.append(Scope(classes: classes, parent: currentScope))
    currentScope = scopes.count - 1
    return true
  }

  private mutating func consumeEntity() -> Bool {
    for (entity, byte) in Self.entities where consume(entity) {
      text.append(byte)
      return true
    }
    return false
  }

  private mutating func consume(_ literal: String) -> Bool {
    let expected = literal.utf8
    guard bytes.count - offset >= expected.count else { return false }
    for (distance, byte) in expected.enumerated() where bytes[offset + distance] != byte {
      return false
    }
    offset += expected.count
    return true
  }

  private mutating func flushText() {
    guard !text.isEmpty else { return }
    // 空の入れ子でもスタックのスナップショットをコピーすると二次になるため、親を索引で保持する。
    var runScopes: [[String]] = []
    var scope = currentScope
    while let index = scope {
      runScopes.append(scopes[index].classes)
      scope = scopes[index].parent
    }
    runs.append(
      HighlightJSRun(
        text: String(decoding: text, as: UTF8.self), scopes: Array(runScopes.reversed())))
    text.removeAll(keepingCapacity: true)
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || (0x09...0x0D).contains(byte)
  }
}
