import Foundation

public struct DiffReviewCommentID: Sendable, Equatable, Hashable {
  public let rawValue: UUID

  /// 値の生成は呼び出し側が行う (`DiffSnapshotID` と同じ理由: docs/coding-guidelines.md §2.1)。
  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}

/// 設計書 §9.2 のローカルレビューコメント。
///
/// - Important: `body` は加工しない。制御文字の検出と拒否は注入層 (`TmuxTextInjection`) の
///   責務であり、ここで sanitize すると「加工せず拒否」という設計方針 (§9.2.1 制約2) が崩れる。
public struct DiffReviewComment: Sendable, Equatable, Identifiable {
  public let id: DiffReviewCommentID
  public let anchor: DiffCommentAnchor
  public let body: String
  public let createdAt: Date
  /// pane へ**貼り付けた**時刻。§9.2.1 制約1 のとおり注入は実行ではないので、
  /// 「Agent が受け取った」ことは表さない。未送信は `nil`。
  public private(set) var sentAt: Date?

  public init(id: DiffReviewCommentID, anchor: DiffCommentAnchor, body: String, createdAt: Date) {
    self.id = id
    self.anchor = anchor
    self.body = body
    self.createdAt = createdAt
    sentAt = nil
  }

  public mutating func markSent(at date: Date) {
    sentAt = date
  }
}

/// worktree 1件ぶんのコメント保持 (設計書 §9.2)。再起動を跨いだ永続化は Issue #208 の対象外で、
/// この型はプロセス内のメモリだけを持つ。
///
/// 列挙順は挿入順ではなく `DiffReviewCommentOrder` の全順序で、同じ集合なら操作順に依らず
/// 同じ並びになる。Review batch の文面を決定的にするため (§9.2)。
public struct DiffReviewComments: Sendable, Equatable {
  public private(set) var all: [DiffReviewComment] = []

  public init() {}

  public var isEmpty: Bool { all.isEmpty }
  public var count: Int { all.count }

  /// 既に同じ ID があれば追加しない。`false` は「その ID のコメントが既にある」を意味する。
  @discardableResult
  public mutating func add(_ comment: DiffReviewComment) -> Bool {
    guard !all.contains(where: { $0.id == comment.id }) else { return false }
    all.append(comment)
    all.sort(by: DiffReviewCommentOrder.precedes)
    return true
  }

  @discardableResult
  public mutating func remove(_ id: DiffReviewCommentID) -> Bool {
    guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
    all.remove(at: index)
    return true
  }

  @discardableResult
  public mutating func markSent(_ id: DiffReviewCommentID, at date: Date) -> Bool {
    guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
    all[index].markSent(at: date)
    return true
  }

  public func comment(_ id: DiffReviewCommentID) -> DiffReviewComment? {
    all.first { $0.id == id }
  }

  public func comments(in snapshot: DiffSnapshotID) -> [DiffReviewComment] {
    all.filter { $0.anchor.snapshotID == snapshot }
  }

  public func comments(
    in snapshot: DiffSnapshotID, origin: DiffChangeOrigin, path: String
  ) -> [DiffReviewComment] {
    // パスの一致は `DiffSnapshot.file(origin:path:)` と同じ粒度で見る。ここだけ `String` の
    // `==` にすると、正準等価な別表記のファイルに付いたコメントが混ざる。
    all.filter {
      $0.anchor.snapshotID == snapshot && $0.anchor.origin == origin
        && DiffFilePath.isSame($0.anchor.path, path)
    }
  }
}

/// コメント列の全順序。snapshot → パス → 出所 → 側 → 行範囲 → 作成時刻 → ID の順に比べる。
public enum DiffReviewCommentOrder {
  public static func precedes(_ lhs: DiffReviewComment, _ rhs: DiffReviewComment) -> Bool {
    SortKey(lhs).precedes(SortKey(rhs))
  }

  private struct SortKey {
    let snapshot: String
    let path: String
    let origin: Int
    let side: Int
    let start: Int
    let end: Int
    let createdAt: Date
    let id: String

    init(_ comment: DiffReviewComment) {
      let anchor = comment.anchor
      snapshot = anchor.snapshotID.rawValue.uuidString
      path = anchor.path
      origin = anchor.origin.sortOrder
      side = anchor.side.sortOrder
      start = anchor.lines.start
      end = anchor.lines.end
      createdAt = comment.createdAt
      id = comment.id.rawValue.uuidString
    }

    func precedes(_ other: Self) -> Bool {
      if snapshot != other.snapshot { return snapshot < other.snapshot }
      // 同値判定と順序判定を同じ粒度 (UTF-8 バイト列) に揃える。同値だけ `String` の `==`
      // (正準等価) のままだと、NFC・NFD・その間に挟まる名前の3件で `a < b < c < a` の循環ができ、
      // 列挙順が挿入順に依存する (実測: 6通りの挿入順で3通りの並びになった)。
      if !DiffFilePath.isSame(path, other.path) {
        return DiffFilePath.precedes(path, other.path)
      }
      if origin != other.origin { return origin < other.origin }
      if side != other.side { return side < other.side }
      if start != other.start { return start < other.start }
      if end != other.end { return end < other.end }
      if createdAt != other.createdAt { return createdAt < other.createdAt }
      return id < other.id
    }
  }
}

extension DiffChangeOrigin {
  /// §9.1.3 の並び (commit済み → staged → unstaged → untracked → 競合)。表示にも使える。
  fileprivate var sortOrder: Int {
    switch self {
    case .committed: 0
    case .staged: 1
    case .unstaged: 2
    case .untracked: 3
    case .unmerged: 4
    }
  }
}

extension DiffLineSide {
  fileprivate var sortOrder: Int {
    switch self {
    case .old: 0
    case .new: 1
    }
  }
}
