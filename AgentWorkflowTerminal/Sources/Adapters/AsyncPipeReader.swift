import Darwin
import Dispatch
import Foundation
import os

// iOS でも API は利用できるが、ローカル実行ホストを Mac に限定し、呼び出し元のない配管を載せない
// (設計書 §20.1)。import をこのガードの内側へ入れると swift-format の OrderedImports が
// エラーを出さずに無効化されるため、import はガードの外に置く。
#if os(macOS)
// §1.2 の例外: stdout/stderr 双方の DispatchIO ハンドラから同期的に呼ばれ、残量の確認と
// 加算を1つの不可分操作にしないと上限を超えて受理してしまうため、actor へ hop できない。
struct OutputBudget: Sendable {
  private struct State: Sendable {
    var bytesRead = 0
  }

  struct Reservation: Sendable {
    let acceptedBytes: Int
    let exceedsLimit: Bool
  }

  private let limit: Int
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(limit: Int) {
    self.limit = limit
  }

  func reserve(_ requestedBytes: Int) -> Reservation {
    state.withLock { state in
      let remainingBytes = max(0, limit - state.bytesRead)
      let acceptedBytes = min(requestedBytes, remainingBytes)
      state.bytesRead += acceptedBytes
      return Reservation(
        acceptedBytes: acceptedBytes,
        exceedsLimit: requestedBytes > acceptedBytes
      )
    }
  }
}

// §1.2 の例外: DispatchIO のハンドラは非 async でその場で蓄積と完了判定を確定させる必要があり、
// Task で actor へ逃がすと直列キューでの到着順が崩れて完了理由が入れ替わるため、ロックで守る。
struct AsyncPipeReader: Sendable {
  enum Completion: Sendable, Equatable {
    case endOfFile
    case limitExceeded
    case failed(errorCode: Int32)

    var errorCode: Int32? {
      guard case .failed(let errorCode) = self else { return nil }
      return errorCode
    }
  }

  struct Snapshot: Sendable {
    static let empty = Self(data: Data(), completion: nil)

    let data: Data
    let completion: Completion?
  }

  private struct State: Sendable {
    var data = Data()
    var completion: Completion?
  }

  private static let maximumReadChunkBytes = 64 * 1_024

  private let channel: DispatchIO
  private let state: OSAllocatedUnfairLock<State>

  init(
    fileDescriptor: Int32,
    queueLabel: String,
    budget: OutputBudget,
    stateDidChange: @escaping @Sendable () -> Void
  ) {
    let state = OSAllocatedUnfairLock(initialState: State())
    let queue = DispatchQueue(label: queueLabel)
    let channel = DispatchIO(
      type: .stream,
      fileDescriptor: fileDescriptor,
      queue: queue
    ) { errorCode in
      let changed = state.withLock { state in
        guard state.completion == nil else { return false }
        state.completion = errorCode == 0 ? .endOfFile : .failed(errorCode: errorCode)
        return true
      }
      if changed {
        stateDidChange()
      }
      _ = Darwin.close(fileDescriptor)
    }
    channel.setLimit(lowWater: 1)
    channel.setLimit(highWater: Self.maximumReadChunkBytes)
    channel.read(offset: 0, length: Int.max, queue: queue) { isDone, data, errorCode in
      let changed = state.withLock { state in
        guard state.completion == nil else { return false }
        if let data, !data.isEmpty {
          let reservation = budget.reserve(data.count)
          if reservation.acceptedBytes > 0 {
            state.data.append(contentsOf: Data(data).prefix(reservation.acceptedBytes))
          }
          if reservation.exceedsLimit {
            state.completion = .limitExceeded
            return true
          }
        }
        if errorCode != 0 {
          state.completion = .failed(errorCode: errorCode)
          return true
        }
        if isDone {
          state.completion = .endOfFile
          return true
        }
        return false
      }
      if changed {
        stateDidChange()
      }
    }
    self.channel = channel
    self.state = state
  }

  func snapshot() -> Snapshot {
    state.withLock { Snapshot(data: $0.data, completion: $0.completion) }
  }

  func stop() {
    channel.close(flags: .stop)
  }
}
#endif
