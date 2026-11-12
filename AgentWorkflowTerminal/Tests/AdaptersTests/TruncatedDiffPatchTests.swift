import Foundation
import Testing

@testable import Adapters

@Suite("§7.2・§12.3 打ち切った patch の完全なレコード")
struct TruncatedDiffPatchTests {
  @Test("§7.2 hunk が完結した境界でも最後のレコードを捨てる")
  func dropsLastRecordAtHunkBoundary() throws {
    let patch = try DiffTruncationFixtures.cached()
    let end = try #require(patch.range(of: "diff --git a/keep.txt"))
    let input = String(patch[..<end.lowerBound])
    let result = TruncatedDiffPatch.completeRecords(in: input)
    let omitted = try #require(patch.range(of: "diff --git a/del.txt"))
    #expect(result.patch == String(patch[..<omitted.lowerBound]))
    #expect(result.firstOmittedPath == "del.txt")
    let parsed = UnifiedDiffPatch.parse(output: result.patch)
    #expect(parsed.files.map(\.path) == ["bin.dat"])
    #expect(parsed.failures.isEmpty)
  }

  @Test("§7.2 行の途中で切れても前のレコードだけ残す")
  func dropsPartialLine() throws {
    let patch = try DiffTruncationFixtures.cached()
    let cut = try #require(patch.range(of: "+l2 sta"))
    let input = String(patch[..<cut.upperBound])
    let start = try #require(patch.range(of: "diff --git a/keep.txt"))
    let result = TruncatedDiffPatch.completeRecords(in: input)
    #expect(result.patch == String(patch[..<start.lowerBound]))
    #expect(result.firstOmittedPath == "keep.txt")
    #expect(
      UnifiedDiffPatch.parse(output: result.patch).files.map(\.path) == ["bin.dat", "del.txt"])
  }

  @Test("§7.2 マルチバイト文字の途中の置換文字を含むレコードを捨てる")
  func dropsPartialUTF8Character() throws {
    let prefix = try DiffTruncationFixtures.cached()
    let edge = try DiffTruncationFixtures.edge()
    let cut = try #require(edge.range(of: "+café"))
    let bytes = Array(edge[..<cut.lowerBound].utf8) + Array("+caf".utf8) + [0xC3]
    let input = prefix + String(decoding: bytes, as: UTF8.self)
    #expect(input.hasSuffix("\u{FFFD}"))
    let result = TruncatedDiffPatch.completeRecords(in: input)
    #expect(result.patch == prefix)
    #expect(result.firstOmittedPath == "café.txt")
  }

  @Test("§7.2 最初のレコード内で切れたら完全なレコードは空になる")
  func dropsFirstRecord() throws {
    let patch = try DiffTruncationFixtures.edge()
    let cut = try #require(patch.range(of: "+café"))
    let result = TruncatedDiffPatch.completeRecords(in: String(patch[..<cut.upperBound]))
    #expect(result.patch.isEmpty)
    #expect(result.firstOmittedPath == "café.txt")
  }

  @Test("§12.3 header の途中で切れたパスを推測しない")
  func doesNotGuessPartialHeaderPath() throws {
    let patch = try DiffTruncationFixtures.cached()
    let cut = try #require(patch.range(of: "diff --git a/bin.dat b/"))
    let result = TruncatedDiffPatch.completeRecords(in: String(patch[..<cut.upperBound]))
    #expect(result.patch.isEmpty)
    #expect(result.firstOmittedPath == nil)
  }

  @Test("§7.2 捨てた rename のパスは新しい側になる")
  func usesRenameDestination() throws {
    let patch = try DiffTruncationFixtures.cached()
    let start = try #require(patch.range(of: "diff --git a/oldname.txt"))
    let result = TruncatedDiffPatch.completeRecords(in: patch)
    #expect(result.patch == String(patch[..<start.lowerBound]))
    #expect(result.firstOmittedPath == "newname.txt")
  }

  @Test("§7.2 レコード開始行の無い打ち切り出力は空になる")
  func dropsOutputWithoutRecordStart() {
    let result = TruncatedDiffPatch.completeRecords(in: "diff --gi")
    #expect(result.patch.isEmpty)
    #expect(result.firstOmittedPath == nil)
  }
}

enum DiffTruncationFixtures {
  static func cached() throws -> String {
    try load("git-2.50.1-diff-patch-cached-head.txt")
  }

  static func edge() throws -> String {
    try load("git-2.50.1-diff-patch-edge.txt")
  }

  private static func load(_ name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}
