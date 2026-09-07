import TerminalCore
import Testing

@Suite("拡張子から syntax highlight の言語を引く (設計書 §7.3)")
struct SyntaxHighlightLanguageTests {
  @Test("拡張子から highlight.js の言語名を引く")
  func mapsKnownExtensions() {
    #expect(SyntaxHighlightLanguage.name(forFileName: "Package.swift") == "swift")
    #expect(SyntaxHighlightLanguage.name(forFileName: "main.rs") == "rust")
    #expect(SyntaxHighlightLanguage.name(forFileName: "server.tsx") == "typescript")
    #expect(SyntaxHighlightLanguage.name(forFileName: "config.yml") == "yaml")
  }

  @Test("大文字の拡張子も同じ言語になる")
  func foldsExtensionCase() {
    #expect(SyntaxHighlightLanguage.name(forFileName: "MAIN.SWIFT") == "swift")
    #expect(SyntaxHighlightLanguage.name(forFileName: "Notes.MD") == "markdown")
  }

  @Test("知らない拡張子は推測しない")
  func doesNotGuessUnknownExtensions() {
    #expect(SyntaxHighlightLanguage.name(forFileName: "archive.tar.gz") == nil)
    #expect(SyntaxHighlightLanguage.name(forFileName: "data.bin") == nil)
    #expect(SyntaxHighlightLanguage.name(forFileName: "notes.h") == nil)
    #expect(SyntaxHighlightLanguage.name(forFileName: "old.m") == nil)
  }

  @Test("拡張子が無いファイル名は言語を持たない")
  func requiresAnExtension() {
    #expect(SyntaxHighlightLanguage.name(forFileName: "Makefile") == nil)
    #expect(SyntaxHighlightLanguage.name(forFileName: "README") == nil)
    #expect(SyntaxHighlightLanguage.name(forFileName: "") == nil)
    #expect(SyntaxHighlightLanguage.name(forFileName: "trailing.") == nil)
  }

  @Test("先頭のドットは拡張子ではない")
  func leadingDotIsNotAnExtension() {
    #expect(SyntaxHighlightLanguage.name(forFileName: ".swift") == nil)
    #expect(SyntaxHighlightLanguage.name(forFileName: ".gitignore") == nil)
  }

  @Test("最後のドットより後ろだけを拡張子とする")
  func usesTheLastExtension() {
    #expect(SyntaxHighlightLanguage.name(forFileName: "a.py.swift") == "swift")
    #expect(SyntaxHighlightLanguage.name(forFileName: "a.swift.py") == "python")
  }
}
