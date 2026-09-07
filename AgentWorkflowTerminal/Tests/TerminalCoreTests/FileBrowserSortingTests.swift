import TerminalCore
import Testing

@Suite("File Browser の1階層並び順 (設計書 §7.1)")
struct FileBrowserSortingTests {
  @Test("ディレクトリを先にし、各種類を大文字小文字非依存、同値なら区別して並べる")
  func sortsDeterministically() {
    let entries = [
      FileBrowserChild(name: "beta.swift", kind: .file),
      FileBrowserChild(name: "alpha", kind: .directory),
      FileBrowserChild(name: "Alpha.swift", kind: .file),
      FileBrowserChild(name: "alpha.swift", kind: .file),
      FileBrowserChild(name: "Beta", kind: .directory),
    ]

    #expect(
      entries.fileBrowserSorted() == [
        FileBrowserChild(name: "alpha", kind: .directory),
        FileBrowserChild(name: "Beta", kind: .directory),
        FileBrowserChild(name: "Alpha.swift", kind: .file),
        FileBrowserChild(name: "alpha.swift", kind: .file),
        FileBrowserChild(name: "beta.swift", kind: .file),
      ])
  }

  @Test("大小文字だけが異なる名前は入力順によらず大文字を先にする")
  func breaksCaseInsensitiveTies() {
    let entries = [
      FileBrowserChild(name: "alpha.swift", kind: .file),
      FileBrowserChild(name: "Alpha.swift", kind: .file),
    ]

    #expect(entries.fileBrowserSorted().map(\.name) == ["Alpha.swift", "alpha.swift"])
  }
}
