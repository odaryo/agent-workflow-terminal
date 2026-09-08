import Foundation

public struct DiffSnapshotID: Sendable, Equatable, Hashable {
  public let rawValue: UUID

  /// 値の生成は呼び出し側が行う。ドメインの型が乱数を自分で引かない (docs/coding-guidelines.md §2.1)。
  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}

/// §9.1.3 の5区分。出所をまたいで hunk をマージしない。
public enum DiffChangeOrigin: Sendable, Equatable, Hashable, CaseIterable {
  case committed
  case staged
  case unstaged
  case untracked
  case unmerged
}

public enum DiffSubject: Sendable, Equatable {
  case commit(hash: String)
  /// `mergeBase` は `git merge-base <branch> HEAD` の OID (§9.1.2)。
  case base(branch: String, mergeBase: String)
  case branch(name: String, mergeBase: String)
}

public struct DiffOriginSection: Sendable, Equatable {
  public let origin: DiffChangeOrigin
  public let files: [UnifiedDiffFile]
  /// パーサが落としたレコード数。0 でないことを UI が黙って捨てない (docs/coding-guidelines.md §2.3)。
  public let unparsedRecordCount: Int

  public init(origin: DiffChangeOrigin, files: [UnifiedDiffFile], unparsedRecordCount: Int = 0) {
    self.origin = origin
    self.files = files
    self.unparsedRecordCount = unparsedRecordCount
  }
}

public enum DiffReviewState: Sendable, Equatable, Hashable, CaseIterable {
  case reviewing
  case reviewed
}

/// snapshot を開いた時点の観測値。`fingerprint` は内容の同一性だけを表す不透明値で、
/// 中身の意味 (OID かハッシュか) に依存しない。
public struct DiffFileObservation: Sendable, Equatable, Hashable {
  public let origin: DiffChangeOrigin
  public let path: String
  public let fingerprint: String

  public init(origin: DiffChangeOrigin, path: String, fingerprint: String) {
    self.origin = origin
    self.path = path
    self.fingerprint = fingerprint
  }
}

public struct DiffSnapshotObservation: Sendable, Equatable {
  /// 観測できなかった場合は `nil`。取れなかったことを「変わっていない」へ丸めない (§12.3)。
  public let headObject: String?
  public let files: [DiffFileObservation]

  public init(headObject: String?, files: [DiffFileObservation]) {
    self.headObject = headObject
    self.files = files
  }
}

public enum DiffSnapshotFileChange: Sendable, Equatable, Hashable {
  case appeared(origin: DiffChangeOrigin, path: String)
  case disappeared(origin: DiffChangeOrigin, path: String)
  case modified(origin: DiffChangeOrigin, path: String)

  public var path: String {
    switch self {
    case .appeared(_, let path), .disappeared(_, let path), .modified(_, let path): path
    }
  }

  public var origin: DiffChangeOrigin {
    switch self {
    case .appeared(let origin, _), .disappeared(let origin, _), .modified(let origin, _): origin
    }
  }
}

public enum DiffSnapshotHeadComparison: Sendable, Equatable, Hashable {
  case unchanged
  case changed
  /// どちらかの観測に HEAD が無く、比較できない。
  case unknown
}

public struct DiffSnapshotComparison: Sendable, Equatable {
  public let head: DiffSnapshotHeadComparison
  public let fileChanges: [DiffSnapshotFileChange]

  public var hasChanges: Bool { head == .changed || !fileChanges.isEmpty }

  public var changedPaths: [String] {
    var seen: Set<String> = []
    return fileChanges.map(\.path).filter { seen.insert($0).inserted }
  }
}

public enum DiffSnapshotChangeDetection {
  /// §9.3: 開いた後に変わったファイルを知らせるための比較。`opened` は snapshot 生成時の観測値、
  /// `current` は再観測値。
  public static func compare(
    opened: DiffSnapshotObservation,
    current: DiffSnapshotObservation
  ) -> DiffSnapshotComparison {
    let head: DiffSnapshotHeadComparison
    switch (opened.headObject, current.headObject) {
    case (let before?, let after?): head = before == after ? .unchanged : .changed
    default: head = .unknown
    }

    var currentByKey = Dictionary(
      current.files.map { (Key(origin: $0.origin, path: $0.path), $0) },
      uniquingKeysWith: { first, _ in first })
    var changes: [DiffSnapshotFileChange] = []
    for file in opened.files {
      let key = Key(origin: file.origin, path: file.path)
      guard let match = currentByKey.removeValue(forKey: key) else {
        changes.append(.disappeared(origin: file.origin, path: file.path))
        continue
      }
      if match.fingerprint != file.fingerprint {
        changes.append(.modified(origin: file.origin, path: file.path))
      }
    }
    for file in current.files {
      guard currentByKey.removeValue(forKey: Key(origin: file.origin, path: file.path)) != nil
      else { continue }
      changes.append(.appeared(origin: file.origin, path: file.path))
    }
    return DiffSnapshotComparison(head: head, fileChanges: changes)
  }

  private struct Key: Hashable {
    let origin: DiffChangeOrigin
    let path: String
  }
}

public enum DiffLineSide: Sendable, Equatable, Hashable {
  case old
  case new
}

public struct DiffSnapshot: Sendable, Equatable, Identifiable {
  public let id: DiffSnapshotID
  public let subject: DiffSubject
  public let createdAt: Date
  /// 出所ごとの変更集合。同じファイルが複数の出所に現れうる (§9.1.3)。
  public let sections: [DiffOriginSection]
  public let observation: DiffSnapshotObservation
  public var reviewState: DiffReviewState

  public init(
    id: DiffSnapshotID,
    subject: DiffSubject,
    createdAt: Date,
    sections: [DiffOriginSection],
    observation: DiffSnapshotObservation,
    reviewState: DiffReviewState = .reviewing
  ) {
    self.id = id
    self.subject = subject
    self.createdAt = createdAt
    self.sections = sections
    self.observation = observation
    self.reviewState = reviewState
  }

  public var isEmpty: Bool { sections.allSatisfy(\.files.isEmpty) }

  public func section(_ origin: DiffChangeOrigin) -> DiffOriginSection? {
    sections.first { $0.origin == origin }
  }

  /// パスの一致は UTF-8 バイト列で見る。`String` の `==` は正準等価な別表記 (NFC / NFD) を
  /// 等しいと答えるため、`==` のままだと NFD のパスで引いた anchor が NFC のファイルの行を掴み、
  /// **文面には NFD のパスを載せたまま別ファイルの元コードを送る** (実測: 同じ出所に両表記を
  /// 置いた snapshot で、NFD の問い合わせが NFC の行テキストを返した)。`DiffSnapshot.verify` も
  /// 同じ引き方をするため `.intact` になり、テキストハッシュではこの取り違えを検出できない。
  /// git は同一 tree に現れた両表記をそのまま出力する一方、APFS は正規化非依存なので、
  /// これは commit 済み区分で起こる。比較の粒度は `WorktreeIdentity` と同じ理由でバイト列へ揃える。
  public func file(origin: DiffChangeOrigin, path: String) -> UnifiedDiffFile? {
    section(origin)?.files.first { DiffFilePath.isSame($0.path, path) }
  }
}

/// §9.3 の「Refresh は既存 snapshot の上書きではなく新しい snapshot の作成であり、
/// 古い snapshot は破棄しない」を型で保つ列。要素は追加されるだけで、既存の内容は
/// `reviewState` 以外は変わらない (#208 のコメントが古い snapshot を参照し続けるため)。
public struct DiffSnapshotHistory: Sendable, Equatable {
  public private(set) var snapshots: [DiffSnapshot] = []

  public init() {}

  public var isEmpty: Bool { snapshots.isEmpty }
  public var count: Int { snapshots.count }
  public var latest: DiffSnapshot? { snapshots.last }

  public func snapshot(_ id: DiffSnapshotID) -> DiffSnapshot? {
    snapshots.first { $0.id == id }
  }

  /// 既に同じ ID があれば追加しない。`false` は「その ID の snapshot が既にある」を意味する。
  @discardableResult
  public mutating func append(_ snapshot: DiffSnapshot) -> Bool {
    guard !snapshots.contains(where: { $0.id == snapshot.id }) else { return false }
    snapshots.append(snapshot)
    return true
  }

  @discardableResult
  public mutating func setReviewState(_ state: DiffReviewState, for id: DiffSnapshotID) -> Bool {
    guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return false }
    snapshots[index].reviewState = state
    return true
  }
}
