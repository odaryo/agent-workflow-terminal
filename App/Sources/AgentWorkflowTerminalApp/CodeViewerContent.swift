import Adapters
import AppKit
import SwiftUI
import TerminalCore

struct CodeViewerContent: View {
  @ObservedObject var model: FileBrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let selection = model.selection {
        header(name: selection.name)
        Divider()
        body(for: selection)
      } else {
        ContentUnavailableView("ファイルを選択してください", systemImage: "doc.text")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func header(name: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        if let observation = model.content?.result.observation {
          Text(summary(of: observation)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      ForEach(notices, id: \.self) { notice in
        Label(notice, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(8)
  }

  @ViewBuilder
  private func body(for selection: FileBrowserSelection) -> some View {
    if let error = model.contentError {
      ContentUnavailableView(
        "表示できません", systemImage: "exclamationmark.triangle",
        description: Text(message(for: error)))
    } else if let load = model.content {
      if let text = load.result.text {
        CodeTextView(
          text: text.content, highlight: load.highlight, highlightedLine: model.highlightedLine)
      } else if let reasons = load.result.decision.confirmationReasons {
        confirmation(reasons: reasons)
      } else {
        ContentUnavailableView("本文がありません", systemImage: "doc")
      }
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func confirmation(reasons: FileOpenConfirmationReasons) -> some View {
    let isBinary = reasons.elements.contains { if case .binary = $0 { true } else { false } }
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(reasons.elements.enumerated()), id: \.offset) { _, reason in
        Label(message(for: reason), systemImage: "exclamationmark.triangle")
      }
      if isBinary {
        // 確認を通してもバイナリの本文は返らないと型で決まっているため、ボタンを出すと
        // 必ず空表示になる。v1 で hex ビューアは作らない (§7.2 / §7.3)。
        Text("バイナリのため本文は表示しません。")
          .foregroundStyle(.secondary)
      } else {
        Button("Open anyway") {
          Task { await model.confirmOpen() }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var notices: [String] {
    var notices: [String] = []
    if model.isSelectionDeleted {
      notices.append("このファイルは削除されました。表示は最後に読み込んだ内容です。")
    }
    if let truncated = model.content?.result.text?.truncatedAtByteCount {
      notices.append("先頭 \(truncated) バイトのみ表示しています。")
    }
    if let reasons = model.content?.result.decision.confirmationReasons,
      model.content?.result.text != nil
    {
      notices.append(
        "確認のうえ表示しています: " + reasons.elements.map(message(for:)).joined(separator: " / "))
    }
    if let highlight = model.content?.highlight, let message = message(for: highlight) {
      notices.append(message)
    }
    return notices
  }

  private func summary(of observation: FileViewObservation) -> String {
    switch observation {
    case .binary(let byteCount):
      "バイナリ / \(byteCount) バイト"
    case .text(let byteCount, let lineCount):
      // 行数を数えていない場合がある。0 行と書かない (§12.3)。
      lineCount.map { "\(byteCount) バイト / \($0) 行" } ?? "\(byteCount) バイト"
    }
  }

  private func message(for reason: FileOpenConfirmationReason) -> String {
    switch reason {
    case .binary(let byteCount):
      "バイナリです (\(byteCount) バイト)"
    case .byteCount(let actual, let maximum):
      "サイズが閾値を超えています (\(actual) バイト > \(maximum) バイト)"
    case .lineCount(let actual, let maximum):
      "行数が閾値を超えています (\(actual) 行 > \(maximum) 行)"
    }
  }

  private func message(for highlight: FileContentLoad.HighlightOutcome) -> String? {
    switch highlight {
    case .highlighted:
      nil
    case .unsupportedFileType:
      "拡張子から言語を判定できないため、syntax highlight は行っていません。"
    case .tooLarge(let byteCount, let maximum):
      "サイズが大きいため syntax highlight は行っていません (\(byteCount) バイト > \(maximum) バイト)。"
    case .unavailable:
      "syntax highlight を適用できませんでした。"
    }
  }

  private func message(for error: FileContentReaderError) -> String {
    switch error {
    case .notRegularFile(_, let kind):
      "通常ファイルではないため読みません (\(label(for: kind)))。"
    case .statFailed(_, let code):
      "ファイルの情報を取得できません (errno \(code): \(String(cString: strerror(code))))。"
    case .readFailed:
      "ファイルを読み取れません。"
    case .incompleteSample(let expected, let actual):
      "読み取り中にファイルが変化しました (先頭 \(expected) バイトのうち \(actual) バイト)。"
    case .fileChanged(let expected, let actual):
      "読み取り中にファイルが変化しました (\(expected) バイトのはずが \(actual) バイト)。"
    }
  }

  private func label(for kind: FileSystemItemKind) -> String {
    switch kind {
    case .regularFile: "通常ファイル"
    case .directory: "ディレクトリ"
    case .symbolicLink: "シンボリックリンク"
    case .fifo: "FIFO"
    case .characterDevice: "キャラクタデバイス"
    case .blockDevice: "ブロックデバイス"
    case .socket: "ソケット"
    case .unknown: "不明な種別"
    }
  }
}

/// SwiftUI の `Text` は本文全体を1つのレイアウトに載せるため、数 MiB の本文で実用にならない。
/// read-only の `NSTextView` を使い、`NSScrollView` に行単位のレイアウトを任せる。
private struct CodeTextView: NSViewRepresentable {
  private static let highlightedLineColor = NSColor.systemYellow.withAlphaComponent(0.28)

  let text: String
  let highlight: FileContentLoad.HighlightOutcome?
  /// 検索結果から開いたときに強調してスクロールする行 (1 始まり)。
  let highlightedLine: Int?

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isEditable = false
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isHorizontallyResizable = true
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    scrollView.hasHorizontalScroller = true
    apply(to: textView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    apply(to: textView)
  }

  private func apply(to textView: NSTextView) {
    if case .highlighted(let attributed, let background) = highlight {
      textView.textStorage?.setAttributedString(NSAttributedString(attributed))
      textView.backgroundColor = NSColor(background)
    } else {
      textView.string = text
      textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
      textView.textColor = .labelColor
      textView.backgroundColor = .textBackgroundColor
    }
    applyLineHighlight(to: textView)
  }

  private func applyLineHighlight(to textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let whole = NSRange(location: 0, length: storage.length)
    storage.removeAttribute(.backgroundColor, range: whole)
    guard let line = highlightedLine, let range = range(ofLine: line) else { return }
    storage.addAttribute(.backgroundColor, value: Self.highlightedLineColor, range: range)
    // 本文を差し替えた直後は layout がまだ無く、`scrollRangeToVisible` が原点へ寄る。
    // 次の run loop まで待ってから寄せる。ここは既に main thread。
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        textView.scrollRangeToVisible(range)
      }
    }
  }

  /// `NSTextView` は UTF-16 の範囲を取るので、行の切り出しも UTF-16 の上で数える。
  private func range(ofLine line: Int) -> NSRange? {
    guard line >= 1 else { return nil }
    var location = 0
    var remaining = line - 1
    let units = Array(text.utf16)
    var start = 0
    while remaining > 0, location < units.count {
      if units[location] == 0x000A {
        remaining -= 1
        start = location + 1
      }
      location += 1
    }
    guard remaining == 0, start <= units.count else { return nil }
    var end = start
    while end < units.count, units[end] != 0x000A { end += 1 }
    return NSRange(location: start, length: end - start)
  }
}
