import AppKit
import SwiftUI
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§7.3 highlight.js のシンタックスハイライト")
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
    // 600 段 (highlight.js が成功した実測の深さ) では HighlightJSMarkup の深さの上限 32 で nil になり、
    // errorRaised の経路を通らない。4000 段では RangeError を内部で捕まえて errorRaised を立てる (#771 の実測)。
    let depth = 4000
    let nested =
      String(repeating: "`${", count: depth) + "1" + String(repeating: "}`", count: depth)
    let failed = await service.highlight(nested, language: "javascript", isDark: false)
    #expect(failed == nil)
    let known = await service.highlight("func f() {}", language: "swift", isDark: false)
    #expect(known != nil)
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

  private func expectColor(_ color: NSColor, red: Int, green: Int, blue: Int) throws {
    let rgb = try #require(color.usingColorSpace(.sRGB))
    #expect(abs(rgb.redComponent - CGFloat(red) / 255) < 0.001)
    #expect(abs(rgb.greenComponent - CGFloat(green) / 255) < 0.001)
    #expect(abs(rgb.blueComponent - CGFloat(blue) / 255) < 0.001)
    #expect(abs(rgb.alphaComponent - 1) < 0.001)
  }
}
