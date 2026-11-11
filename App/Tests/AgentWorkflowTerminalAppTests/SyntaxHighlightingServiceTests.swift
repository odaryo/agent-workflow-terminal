import AppKit
import SwiftUI
import Testing

@testable import AgentWorkflowTerminalApp

// テストごとにサービスを作るので、並行に回すと各テストが初回の NSFont(name:size:) を同時に呼ぶ。
// hw.ncpu = 10 の機械 (macOS 27.0.1) では、Swift Concurrency の 10 本以上がそこで fontd の
// 同期の返事を同時に待つと、返事が来ないまま止まった (#982。9 本以下や Thread からの
// 呼び出しでは止まらなかった)。
@Suite("§7.3 highlight.js のシンタックスハイライト", .serialized)
struct SyntaxHighlightingServiceTests {
  private static let resourceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/highlight-js")

  @Test("Swift のキーワードにテーマの色を付ける", arguments: [false, true])
  func colorsSwiftKeyword(isDark: Bool) async throws {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let result = try #require(
      await service.highlight("func f() {}", language: "swift", isDark: isDark))
    let attributed = NSAttributedString(result.text)
    for index in 0..<4 {
      let color = try #require(
        attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
      try expectColor(
        color, red: isDark ? 0xC6 : 0xAA, green: isDark ? 0x78 : 0x0D,
        blue: isDark ? 0xDD : 0x91)
    }
    if !isDark {
      try expectColor(NSColor(result.background), red: 255, green: 255, blue: 255)
    }
  }

  @Test("Markdown の strong を太字にする")
  func boldMarkdown() async throws {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let result = try #require(
      await service.highlight("**a**", language: "markdown", isDark: false))
    let attributed = NSAttributedString(result.text)
    let font = try #require(attributed.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
  }

  @Test(
    "幅 0 の一致がある Markdown にもテーマの色を付け、入力を保持する",
    arguments: [
      ("---\nname: my_agent\n---\n\nSee foo_bar for details.\n", "name"),
      ("Configure max_retries\n---\n\nThe max_retries value is read at start.\n", "Configure"),
    ])
  func colorsMarkdownWithZeroWidthMatch(code: String, section: String) async throws {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let result = try #require(await service.highlight(code, language: "markdown", isDark: false))
    #expect(String(result.text.characters).unicodeScalars.elementsEqual(code.unicodeScalars))
    let attributed = NSAttributedString(result.text)
    let sectionRange = try #require(code.range(of: section))
    let range = NSRange(sectionRange, in: code)
    let color = try #require(
      attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
    try expectColor(color, red: 0x64, green: 0x38, blue: 0x20)
  }

  @Test("幅 0 の一致の後も script 内の失敗は nil を返し、次のハイライトは成功する")
  func nestedScriptInternalErrorAfterZeroWidthMatch() async throws {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let markdown = "---\nname: my_agent\n---\n\nSee foo_bar for details.\n"
    _ = try #require(await service.highlight(markdown, language: "markdown", isDark: false))
    let failed = await service.highlight(Self.nestedScriptCode(), language: "xml", isDark: false)
    #expect(failed == nil)
    #expect(await service.highlightedHTML(Self.nestedScriptCode(), language: "xml") == nil)
    let known = await service.highlight("func f() {}", language: "swift", isDark: false)
    #expect(known != nil)
  }

  @Test("未知の言語で失敗しても次のハイライトは成功する")
  func unknownLanguage() async {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let unknown = await service.highlight(
      "func f() {}", language: "unknown-language", isDark: false)
    #expect(unknown == nil)
    let known = await service.highlight("func f() {}", language: "swift", isDark: false)
    #expect(known != nil)
  }

  @Test("highlight.js が内部で失敗した入力は nil を返し、次のハイライトは成功する")
  func highlightJSInternalError() async {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    // 協調スレッドのスタック (512 KiB) の上では RangeError のしきい値が macOS 27 の実測で 600〜700 段なので、4000 段を使う。
    // 大きなスタックでは 4000 段でも JS が成功し、highlight は HighlightJSMarkup の深さの上限 32 で nil になって
    // JS の失敗を確かめないまま通る。そのときは highlightedHTML の #expect が落ちる (#867)。
    let depth = 4000
    let nested =
      String(repeating: "`${", count: depth) + "1" + String(repeating: "}`", count: depth)
    let failed = await service.highlight(nested, language: "javascript", isDark: false)
    #expect(failed == nil)
    #expect(await service.highlightedHTML(nested, language: "javascript") == nil)
    let known = await service.highlight("func f() {}", language: "swift", isDark: false)
    #expect(known != nil)
  }

  @Test("HTML の script 内で深い入れ子が失敗したら nil を返し、次のハイライトは成功する")
  func nestedScriptInternalError() async {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let failed = await service.highlight(Self.nestedScriptCode(), language: "xml", isDark: false)
    #expect(failed == nil)
    #expect(await service.highlightedHTML(Self.nestedScriptCode(), language: "xml") == nil)
    let known = await service.highlight("func f() {}", language: "swift", isDark: false)
    #expect(known != nil)
  }

  @Test("HTML の小さな script 内のキーワードにテーマの色を付ける")
  func colorsScriptKeyword() async throws {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let code = "<div class=\"a\">x</div>\n<script>let a = 1;</script>\n"
    let result = try #require(await service.highlight(code, language: "xml", isDark: false))
    let attributed = NSAttributedString(result.text)
    let keywordRange = try #require(code.range(of: "let"))
    let range = NSRange(keywordRange, in: code)
    for index in range.location..<(range.location + range.length) {
      let color = try #require(
        attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
      try expectColor(color, red: 0xAA, green: 0x0D, blue: 0x91)
    }
  }

  @Test("存在しないリソースでは繰り返し呼んでも nil を返す")
  func missingResources() async {
    let directory = Self.resourceDirectory.appendingPathComponent(UUID().uuidString)
    let service = SyntaxHighlightingService(resourceDirectory: directory)
    for _ in 0..<2 {
      let result = await service.highlight("func f() {}", language: "swift", isDark: false)
      #expect(result == nil)
    }
  }

  @Test(
    "補助平面の文字と CRLF をそのまま保持する",
    arguments: ["let face = \"😀\"\nfunc f() {}", "func f() {\r\n  let a = 1\r\n}\r\n"])
  func preservesSource(code: String) async throws {
    let service = SyntaxHighlightingService(resourceDirectory: Self.resourceDirectory)
    let result = try #require(await service.highlight(code, language: "swift", isDark: false))
    #expect(String(result.text.characters).unicodeScalars.elementsEqual(code.unicodeScalars))
  }

  private static func nestedScriptCode() -> String {
    // 協調スレッドのスタック (512 KiB) の上では RangeError のしきい値が macOS 27 の実測で 600〜700 段なので、4000 段を使う。
    // 大きなスタックでは 4000 段でも JS が成功し、highlight は HighlightJSMarkup の深さの上限 32 で nil になって
    // JS の失敗を確かめないまま通る。そのときは highlightedHTML の #expect が落ちる (#867)。
    let depth = 4000
    let nested =
      String(repeating: "`${", count: depth) + "1" + String(repeating: "}`", count: depth)
    return "<div class=\"a\">x</div>\n<script>\nlet a = \(nested);\n</script>\n<p>y</p>\n"
  }

  private func expectColor(_ color: NSColor, red: Int, green: Int, blue: Int) throws {
    let rgb = try #require(color.usingColorSpace(.sRGB))
    #expect(abs(rgb.redComponent - CGFloat(red) / 255) < 0.001)
    #expect(abs(rgb.greenComponent - CGFloat(green) / 255) < 0.001)
    #expect(abs(rgb.blueComponent - CGFloat(blue) / 255) < 0.001)
    #expect(abs(rgb.alphaComponent - 1) < 0.001)
  }
}
