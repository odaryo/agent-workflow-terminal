import Adapters
import Foundation
import TerminalCore

typealias WorktreePaneStatesFeed = @Sendable (TaskWorktree) -> AsyncStream<[PaneAgentState]>

func makeTemporaryPaneStatesFeed(
  runner: TmuxRunner,
  signalSource: TmuxAgentSignalSource
) -> WorktreePaneStatesFeed {
  let adapters: [any AgentAdapter] = [ClaudeCodeAdapter(), CodexAdapter()]
  let fallback = ProcessDetectionFallbackAdapter(
    processNames: Set(adapters.flatMap(\.processNames))
  )

  return { worktree in
    AsyncStream { continuation in
      let task = Task {
        let sessionName = TmuxSessionName(identity: worktree.identity).rawValue
        while !Task.isCancelled {
          guard let panes = await listPanes(sessionName: sessionName, runner: runner) else {
            continuation.yield([])
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
            continue
          }

          var states: [PaneAgentState] = []
          for pane in panes {
            if let state = await observe(
              pane: pane,
              adapters: adapters,
              fallback: fallback,
              signalSource: signalSource
            ) {
              states.append(state)
            }
          }
          continuation.yield(states)
          do { try await Task.sleep(for: .seconds(2)) } catch { break }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private func listPanes(sessionName: String, runner: TmuxRunner) async -> [TmuxPane]? {
  do {
    let output = try await runner.run(
      arguments: ["list-panes", "-s", "-t", "=\(sessionName)", "-F", TmuxListPanes.format]
    ).stdout
    let parsed = TmuxListPanes.parse(output: output)
    for failure in parsed.failures {
      NSLog("[app] tmux pane の解析に失敗: \(String(describing: failure))")
    }
    return parsed.panes
  } catch {
    return nil
  }
}

private func observe(
  pane: TmuxPane,
  adapters: [any AgentAdapter],
  fallback: any AgentAdapter,
  signalSource: TmuxAgentSignalSource
) async -> PaneAgentState? {
  let snapshot = pane.snapshot
  var candidates: [AgentAdapterCandidate] = []
  for adapter in adapters {
    let liveness = await signalSource.liveness(
      for: snapshot,
      matchingProcessNames: adapter.processNames
    )
    candidates.append(AgentAdapterCandidate(adapter: adapter, liveness: liveness))
  }
  let adapter = AgentAdapterResolver.resolve(
    pane: snapshot,
    candidates: candidates,
    fallback: fallback
  )
  let liveness: AgentLiveness
  if let matched = candidates.first(where: { $0.adapter.id == adapter.id }) {
    liveness = matched.liveness
  } else {
    liveness = await signalSource.liveness(
      for: snapshot,
      matchingProcessNames: fallback.processNames
    )
  }
  let signals: AgentSignals
  do {
    signals = try await signalSource.signals(for: snapshot)
  } catch {
    NSLog("[app] Agent signal の取得に失敗: \(String(describing: error))")
    signals = AgentSignals(
      paneTitle: snapshot.title,
      screenText: nil,
      secondsSinceScreenChange: nil,
      observedAt: Date()
    )
  }
  guard
    case .observation(let observation) = adapter.classify(
      signals: signals,
      liveness: liveness
    )
  else { return nil }
  return PaneAgentState(id: snapshot.id, observation: observation)
}
