import Adapters
import AppKit
import JavaScriptCore
import SwiftUI

actor SyntaxHighlightingService {
  struct HighlightedCode: Sendable {
    let text: AttributedString
    let background: Color
  }

  static let shared = SyntaxHighlightingService(
    resourceDirectory: Bundle.main.resourceURL?.appendingPathComponent("highlight-js"))

  /// 旧実装での計測 (release ビルド、Apple Silicon、同梱 highlight.js 11.11.1、Swift ソース):
  /// 64 KiB = 0.19 s / 128 KiB = 0.36 s / 256 KiB = 0.77 s / 1 MiB = 2.87 s / 2 MiB = 5.72 s と
  /// 入力サイズにほぼ比例する。1 秒を超えて色が付かない状態を見せないため 256 KiB で切る。
  /// §7.2 の警告閾値 (1 MiB) より小さいので、その間のファイルは素のまま表示される。
  static let maximumByteCount = 262_144

  private let resourceDirectory: URL?
  private var context: JSContext?
  private var didLoadContext = false
  private var themes: [Bool: HighlightJSTheme] = [:]
  private var attemptedThemes: Set<Bool> = []

  init(resourceDirectory: URL?) {
    self.resourceDirectory = resourceDirectory
  }

  func highlight(_ code: String, language: String, isDark: Bool) -> HighlightedCode? {
    guard let theme = theme(isDark: isDark),
      let html = highlightedHTML(code, language: language), let runs = HighlightJSMarkup.parse(html)
    else { return nil }
    let reconstructed = runs.map(\.text).joined()
    guard reconstructed.unicodeScalars.elementsEqual(code.unicodeScalars) else { return nil }

    let font =
      NSFont(name: "Menlo", size: 12)
      ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let attributed = NSMutableAttributedString(
      string: code, attributes: [.font: font, .foregroundColor: nsColor(theme.baseColor)])
    var offset = 0
    for run in runs {
      let length = run.text.utf16.count
      attributed.addAttributes(
        attributes(for: theme.style(forScopes: run.scopes), baseFont: font),
        range: NSRange(location: offset, length: length))
      offset += length
    }
    return HighlightedCode(
      text: AttributedString(attributed),
      background: Color(nsColor: nsColor(theme.backgroundColor)))
  }

  func highlightedHTML(_ code: String, language: String) -> String? {
    guard let context = javascriptContext() else { return nil }
    let result = highlightResult(code, language: language, context: context)
    // safe mode での再実行は内部の失敗を errorRaised に入れるため、素のテキストを成功として扱わない。
    guard context.exception == nil,
      let errorRaised = result?.objectForKeyedSubscript("errorRaised"),
      errorRaised.isUndefined || errorRaised.isNull,
      let value = result?.objectForKeyedSubscript("value"), value.isString
    else { return nil }
    return value.toString()
  }

  private func highlightResult(_ code: String, language: String, context: JSContext) -> JSValue? {
    context.exception = nil
    let hljs = context.objectForKeyedSubscript("hljs")
    let arguments: [Any] = [code, ["language": language, "ignoreIllegals": true]]
    // main や大きなスタックのスレッドへ移すと、深い入れ子で時間・メモリが急増する。
    // 協調スレッドのスタック上限で素のテキストへ退避できるよう、JS 呼び出しはこの actor 内に留める。
    let result = hljs?.invokeMethod("highlight", withArguments: arguments)
    guard let exception = context.exception,
      let message = exception.objectForKeyedSubscript("message"), message.isString,
      message.toString()?.hasPrefix("0 width match regex") == true
    else { return result }

    // 幅 0 の一致 (Markdown の front matter や setext 見出しで起きる) は debugMode では例外になるが、
    // safe mode なら 1 文字送って続けられる。safe でのやり直しでは配列 subLanguage の内側の失敗が
    // 再び見えなくなるが、Markdown はタグしか xml に渡さないので、両方が起きる形は見つかっていない。
    context.exception = nil
    hljs?.invokeMethod("safeMode", withArguments: [])
    let retriedResult = hljs?.invokeMethod("highlight", withArguments: arguments)
    let retryHadException = context.exception != nil
    context.exception = nil
    hljs?.invokeMethod("debugMode", withArguments: [])
    guard context.exception == nil else {
      self.context = nil
      return nil
    }
    guard !retryHadException else { return nil }
    return retriedResult
  }

  private func javascriptContext() -> JSContext? {
    guard !didLoadContext else { return context }
    didLoadContext = true
    guard let resourceDirectory,
      let source = try? String(
        contentsOf: resourceDirectory.appendingPathComponent("highlight.min.js"), encoding: .utf8),
      let created = JSContext()
    else { return nil }
    created.evaluateScript(source)
    guard created.exception == nil,
      let hljs = created.objectForKeyedSubscript("hljs"), !hljs.isUndefined, !hljs.isNull
    else { return nil }
    // 配列 subLanguage の内側の失敗はトップレベルの errorRaised に出ないため、例外として受け取る (#866)。
    hljs.invokeMethod("debugMode", withArguments: [])
    guard created.exception == nil else { return nil }
    context = created
    return created
  }

  private func theme(isDark: Bool) -> HighlightJSTheme? {
    guard !attemptedThemes.contains(isDark) else { return themes[isDark] }
    attemptedThemes.insert(isDark)
    let name = isDark ? "atom-one-dark.css" : "xcode.css"
    guard let resourceDirectory,
      let css = try? String(
        contentsOf: resourceDirectory.appendingPathComponent(name), encoding: .utf8),
      let parsed = HighlightJSTheme.parse(css: css)
    else { return nil }
    themes[isDark] = parsed
    return parsed
  }

  private func attributes(
    for style: HighlightJSStyle, baseFont: NSFont
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let color = style.color { attributes[.foregroundColor] = nsColor(color) }
    if let color = style.backgroundColor { attributes[.backgroundColor] = nsColor(color) }
    if style.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    var traits: NSFontTraitMask = []
    if style.isBold { traits.insert(.boldFontMask) }
    if style.isItalic { traits.insert(.italicFontMask) }
    if !traits.isEmpty {
      attributes[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
    }
    return attributes
  }

  private func nsColor(_ color: HighlightJSColor) -> NSColor {
    NSColor(
      srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
      blue: CGFloat(color.blue) / 255, alpha: 1)
  }
}
