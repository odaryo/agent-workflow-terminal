import Foundation

public struct HighlightJSColor: Equatable, Sendable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }
}

public struct HighlightJSStyle: Equatable, Sendable {
  public var color: HighlightJSColor?
  public var backgroundColor: HighlightJSColor?
  public var isBold: Bool
  public var isItalic: Bool
  public var isUnderlined: Bool

  public init(
    color: HighlightJSColor? = nil, backgroundColor: HighlightJSColor? = nil,
    isBold: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false
  ) {
    self.color = color
    self.backgroundColor = backgroundColor
    self.isBold = isBold
    self.isItalic = isItalic
    self.isUnderlined = isUnderlined
  }
}

public struct HighlightJSTheme: Equatable, Sendable {
  public let baseColor: HighlightJSColor
  public let backgroundColor: HighlightJSColor
  private let rulesByClass: [String: [HighlightJSThemeRule]]

  public static func parse(css: String) -> Self? {
    guard let css = HighlightJSThemeParser.removingComments(css) else { return nil }
    var remaining = css[...]
    var base = HighlightJSDeclarations()
    var rulesByClass: [String: [HighlightJSThemeRule]] = [:]
    var order = 0
    while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let open = remaining.firstIndex(of: "{"),
        let close = remaining[open...].firstIndex(of: "}")
      else { return nil }
      let declarations = HighlightJSDeclarations.parse(
        remaining[remaining.index(after: open)..<close])
      for selector in remaining[..<open].split(separator: ",") {
        guard let classes = HighlightJSThemeParser.classes(in: selector),
          let first = classes.first
        else { continue }
        if classes == ["hljs"] {
          base.merge(declarations)
        } else {
          rulesByClass[first, default: []].append(
            HighlightJSThemeRule(classes: classes, order: order, declarations: declarations))
        }
        order += 1
      }
      remaining = remaining[remaining.index(after: close)...]
    }
    guard let color = base.color, let background = base.backgroundColor else { return nil }
    return Self(baseColor: color, backgroundColor: background, rulesByClass: rulesByClass)
  }

  public func style(forScopes scopes: [[String]]) -> HighlightJSStyle {
    var inherited = HighlightJSDeclarations()
    for scope in scopes {
      let classes = Set(scope)
      var matching: [HighlightJSThemeRule] = []
      for name in classes {
        for rule in rulesByClass[name] ?? [] where rule.classes.allSatisfy(classes.contains) {
          matching.append(rule)
        }
      }
      matching.sort {
        if $0.classes.count != $1.classes.count {
          return $0.classes.count < $1.classes.count
        }
        return $0.order < $1.order
      }
      for rule in matching {
        inherited.merge(rule.declarations)
      }
    }
    return HighlightJSStyle(
      color: inherited.color, backgroundColor: inherited.backgroundColor,
      isBold: inherited.isBold ?? false, isItalic: inherited.isItalic ?? false,
      isUnderlined: inherited.isUnderlined ?? false)
  }
}

private struct HighlightJSThemeRule: Equatable, Sendable {
  let classes: [String]
  let order: Int
  let declarations: HighlightJSDeclarations
}

private struct HighlightJSDeclarations: Equatable, Sendable {
  var color: HighlightJSColor?
  var backgroundColor: HighlightJSColor?
  var isBold: Bool?
  var isItalic: Bool?
  var isUnderlined: Bool?

  mutating func merge(_ other: Self) {
    color = other.color ?? color
    backgroundColor = other.backgroundColor ?? backgroundColor
    isBold = other.isBold ?? isBold
    isItalic = other.isItalic ?? isItalic
    isUnderlined = other.isUnderlined ?? isUnderlined
  }

  static func parse(_ body: Substring) -> Self {
    var result = Self()
    for declaration in body.split(separator: ";") {
      guard let colon = declaration.firstIndex(of: ":") else { continue }
      let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = declaration[declaration.index(after: colon)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      switch property {
      case "color":
        result.color = HighlightJSThemeParser.color(value) ?? result.color
      case "background", "background-color":
        result.backgroundColor = HighlightJSThemeParser.color(value) ?? result.backgroundColor
      case "font-weight":
        result.isBold = ["bold": true, "normal": false][value] ?? result.isBold
      case "font-style":
        result.isItalic = ["italic": true, "normal": false][value] ?? result.isItalic
      case "text-decoration":
        if value == "underline" { result.isUnderlined = true }
      default:
        continue
      }
    }
    return result
  }
}

private enum HighlightJSThemeParser {
  static func color(_ value: String) -> HighlightJSColor? {
    let bytes = Array(value.utf8)
    guard bytes.first == 0x23, bytes.count == 4 || bytes.count == 7,
      bytes.dropFirst().allSatisfy({
        (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
      }),
      let hex = UInt32(value.dropFirst(), radix: 16)
    else { return nil }
    if bytes.count == 4 {
      return HighlightJSColor(
        red: UInt8((hex >> 8) & 0xF) * 17, green: UInt8((hex >> 4) & 0xF) * 17,
        blue: UInt8(hex & 0xF) * 17)
    }
    return HighlightJSColor(
      red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
  }

  static func classes(in selector: Substring) -> [String]? {
    let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = selector.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1, parts.first?.isEmpty == true else { return nil }
    var classes: [String] = []
    for part in parts.dropFirst() {
      guard !part.isEmpty,
        part.utf8.allSatisfy({
          (0x61...0x7A).contains($0) || (0x41...0x5A).contains($0)
            || (0x30...0x39).contains($0) || $0 == 0x5F || $0 == 0x2D
        })
      else { return nil }
      classes.append(String(part))
    }
    return classes
  }

  static func removingComments(_ css: String) -> String? {
    let bytes = Array(css.utf8)
    var output: [UInt8] = []
    var offset = 0
    var inComment = false
    while offset < bytes.count {
      if !inComment && offset + 1 < bytes.count
        && bytes[offset] == 0x2F && bytes[offset + 1] == 0x2A
      {
        inComment = true
        offset += 2
      } else if inComment && offset + 1 < bytes.count
        && bytes[offset] == 0x2A && bytes[offset + 1] == 0x2F
      {
        inComment = false
        offset += 2
      } else {
        if !inComment { output.append(bytes[offset]) }
        offset += 1
      }
    }
    return inComment ? nil : String(decoding: output, as: UTF8.self)
  }
}
