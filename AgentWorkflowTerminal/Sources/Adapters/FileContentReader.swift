import Darwin
import Foundation
import TerminalCore

public enum FileSystemItemKind: Sendable, Equatable {
  case regularFile
  case directory
  case symbolicLink
  case fifo
  case characterDevice
  case blockDevice
  case socket
  case unknown

  fileprivate init(mode: mode_t) {
    switch mode & S_IFMT {
    case S_IFREG: self = .regularFile
    case S_IFDIR: self = .directory
    case S_IFLNK: self = .symbolicLink
    case S_IFIFO: self = .fifo
    case S_IFCHR: self = .characterDevice
    case S_IFBLK: self = .blockDevice
    case S_IFSOCK: self = .socket
    default: self = .unknown
    }
  }
}

public enum FileContentReaderError: Error, Sendable, Equatable {
  case notRegularFile(path: String, kind: FileSystemItemKind)
  case statFailed(path: String, code: Int32)
  case readFailed(String)
  case incompleteSample(expected: Int, actual: Int)
  case fileChanged(expected: Int, actual: Int)
}

public struct FileContentText: Sendable, Equatable {
  public let content: String
  /// `absoluteMaximumByteCount` で打ち切った場合だけ、実際に復号できたバイト数が入る。
  /// `nil` はファイル全体であることを意味する。
  public let truncatedAtByteCount: Int?
}

public struct FileContentReadResult: Sendable, Equatable {
  public let observation: FileViewObservation
  public let decision: FileOpenDecision
  public let text: FileContentText?
}

struct OpenedRegularFile {
  let handle: FileHandle
  let byteCount: Int
}

public struct FileContentReader: Sendable {
  private let openRegularFile: @Sendable (URL) throws(FileContentReaderError) -> OpenedRegularFile

  public init() {
    self.init(openRegularFile: Self.openRegularFile(at:))
  }

  init(
    openRegularFile: @escaping @Sendable (URL) throws(FileContentReaderError) -> OpenedRegularFile
  ) {
    self.openRegularFile = openRegularFile
  }

  /// 不正な UTF-8 をバイナリと見なす判定は、実際に読んだ範囲にしか及ばない。警告閾値を超えていて
  /// `confirmation` が `.notConfirmed` の場合は本文を読まないため、そのファイルがテキストか
  /// どうかは先頭 8 KiB の NUL 判定までしか分かっていない。
  public func read(
    url: URL,
    thresholds: FileViewThresholds = .default,
    confirmation: FileOpenConfirmation = .notConfirmed
  ) throws -> FileContentReadResult {
    let opened = try openRegularFile(url)
    let byteCount = opened.byteCount
    let handle = opened.handle
    defer { try? handle.close() }

    do {
      let sampleCount = min(byteCount, BinaryFileDetection.sampleByteCount)
      let sampleData = try handle.read(upToCount: sampleCount) ?? Data()
      guard sampleData.count == sampleCount,
        let sample = BinaryFileSample(bytes: Array(sampleData), fileByteCount: byteCount)
      else {
        throw FileContentReaderError.incompleteSample(
          expected: sampleCount, actual: sampleData.count)
      }
      if BinaryFileDetection.isBinary(sample: sample) {
        return result(observation: .binary(byteCount: byteCount), text: nil, thresholds: thresholds)
      }
      if byteCount > thresholds.maximumByteCount, confirmation == .notConfirmed {
        return result(
          observation: .text(byteCount: byteCount, lineCount: nil), text: nil,
          thresholds: thresholds)
      }

      return try readText(
        from: handle,
        sampleData: sampleData,
        byteCount: byteCount,
        thresholds: thresholds,
        confirmation: confirmation)
    } catch let error as FileContentReaderError {
      throw error
    } catch {
      throw FileContentReaderError.readFailed(url.path)
    }
  }

  /// 種別を `lstat` で先に見てから開くと、その隙に同じパスが `renamex_np(RENAME_SWAP)` で
  /// FIFO へ差し替わったときに `open(2)` が writer を待って戻らない (計測: 4 秒以内にハングし、
  /// SIGKILL でしか終わらない)。判定は開いた fd の `fstat` に基づける。
  ///
  /// `O_NONBLOCK` はその待ちを断つためだけに要る。`O_NOFOLLOW` は同じ隙に symlink へ
  /// 差し替わった場合に worktree の外を読むのを止める (計測: 200,000 回中 1,033 回、
  /// 外側のファイルの内容を返していた。§8.1「検索範囲は常に現在の worktree 内だけ」)。
  @Sendable
  static func openRegularFile(at url: URL) throws(FileContentReaderError) -> OpenedRegularFile {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { throw openFailure(at: url, code: errno) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      let code = errno
      close(descriptor)
      throw .statFailed(path: url.path, code: code)
    }
    let kind = FileSystemItemKind(mode: info.st_mode)
    guard kind == .regularFile else {
      close(descriptor)
      throw .notRegularFile(path: url.path, kind: kind)
    }
    // 通常ファイルの読み取りに O_NONBLOCK は要らないので、種別が確定した時点で落とす。
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
    return OpenedRegularFile(
      handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
      byteCount: Int(info.st_size))
  }

  /// `open(2)` は種別ゆえに失敗することがある (`O_NOFOLLOW` で symlink なら `ELOOP`、
  /// socket なら `EOPNOTSUPP`)。「読めない」と「種別が違う」を同じ結果に丸めない (§12.3)。
  private static func openFailure(at url: URL, code: Int32) -> FileContentReaderError {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return .statFailed(path: url.path, code: code) }
    let kind = FileSystemItemKind(mode: info.st_mode)
    guard kind == .regularFile else { return .notRegularFile(path: url.path, kind: kind) }
    return .statFailed(path: url.path, code: code)
  }

  private func readText(
    from handle: FileHandle,
    sampleData: Data,
    byteCount: Int,
    thresholds: FileViewThresholds,
    confirmation: FileOpenConfirmation
  ) throws -> FileContentReadResult {
    let limit = min(byteCount, thresholds.absoluteMaximumByteCount)
    let isTruncated = limit < byteCount
    // バイナリ判定用のサンプルは絶対上限より先に読んでいるので、上限の方が短いことがある。
    let data: Data
    if isTruncated {
      data =
        sampleData.count >= limit
        ? Data(sampleData.prefix(limit))
        : sampleData + (try handle.read(upToCount: limit - sampleData.count) ?? Data())
    } else {
      data = sampleData + (try handle.readToEnd() ?? Data())
    }
    guard data.count == limit else {
      throw FileContentReaderError.fileChanged(expected: limit, actual: data.count)
    }
    // 設計書に文字コード推測の要求が無いため、不正 UTF-8 は別 encoding ではなく binary とする。
    guard let decoded = Self.decodeUTF8(data, droppingIncompleteTail: isTruncated) else {
      return result(observation: .binary(byteCount: byteCount), text: nil, thresholds: thresholds)
    }
    // 打ち切った場合の行数は数えていない。0 や部分値に丸めない (§12.3)。
    let lineCount = isTruncated ? nil : Self.lineCount(of: data)
    let observation = FileViewObservation.text(byteCount: byteCount, lineCount: lineCount)
    let decision = FileOpenDecision.decide(observation: observation, thresholds: thresholds)
    let text = FileContentText(
      content: decoded.text,
      truncatedAtByteCount: isTruncated ? decoded.byteCount : nil)
    return FileContentReadResult(
      observation: observation,
      decision: decision,
      text: decision == .display || confirmation == .confirmed ? text : nil)
  }

  /// 絶対上限は文字境界を無視して切るため、末尾に不完全な UTF-8 列が残り得る。これを不正 UTF-8 =
  /// バイナリと見なすと、打ち切りだけを理由に本文を失う。UTF-8 の1文字は最長 4 バイト。
  private static func decodeUTF8(
    _ data: Data, droppingIncompleteTail: Bool
  ) -> (text: String, byteCount: Int)? {
    if let text = String(data: data, encoding: .utf8) { return (text, data.count) }
    guard droppingIncompleteTail else { return nil }
    for dropped in 1...3 where dropped <= data.count {
      let candidate = data.dropLast(dropped)
      if let text = String(data: candidate, encoding: .utf8) { return (text, candidate.count) }
    }
    return nil
  }

  private static func lineCount(of data: Data) -> Int {
    data.reduce(into: 0) { count, byte in
      if byte == 0x0A { count += 1 }
    } + (data.isEmpty || data.last == 0x0A ? 0 : 1)
  }

  private func result(
    observation: FileViewObservation,
    text: FileContentText?,
    thresholds: FileViewThresholds
  ) -> FileContentReadResult {
    FileContentReadResult(
      observation: observation,
      decision: FileOpenDecision.decide(observation: observation, thresholds: thresholds),
      text: text)
  }
}
