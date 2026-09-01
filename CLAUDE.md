# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

`agent_workflow_terminal` is pre-alpha. It holds the design documents, one throwaway PoC spike, and a scaffolding-only Swift package — **no product feature is implemented yet**.

- `docs/architecture.md` — the specification (Japanese). `docs/coding-guidelines.md` — the coding rules; read it before writing Swift.
- `Spikes/gate1/` — the PoC Gate 1 spike (SwiftUI + libghostty + PTY + tmux). Throwaway code: excluded from lint, format, tests, and CI. Read it as a reference implementation; never copy code out of it.
- `AgentWorkflowTerminal/` — the SwiftPM package. Targets: `TerminalCore` (domain model, no UI/process deps) ← `Adapters` (external-world boundary, placeholder only). Each has a Swift Testing test target. Swift 6 language mode, strict concurrency.
- There is deliberately **no app target / Xcode project yet** — the Gate 1 spike already serves as the running macOS reference, and Gate 2+ is unfinished. See `AgentWorkflowTerminal/README.md`.
- **Tasks live in GitHub Issues — Issues are the single source of truth.** Never keep TODO lists in files, docs, or code comments; file an Issue instead.

### Build / test / lint

```shell
cd AgentWorkflowTerminal && swift build && swift test     # SwiftPM package
```

```shell
# from the repository root
swift format lint --configuration .swift-format --recursive --strict \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift
swift format format --configuration .swift-format --recursive --in-place \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift
swiftlint lint --config .swiftlint.yml                    # requires `brew install swiftlint`
```

`swift-format` ships with the Swift 6 toolchain (no install); SwiftLint must be installed separately and is optional locally. CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` + `swift format lint` + `swiftlint lint --strict` on a macOS runner (the SwiftLint job installs SwiftLint via brew if the runner image lacks it).

Domain logic and CLI-output parsers are written test-first with Swift Testing; UI rendering and libghostty integration are explicitly not unit-tested (spike + manual). See `docs/coding-guidelines.md`.

**Code = How / tests = What / commit log = Why / code comments = Why not.** Comments — `///` doc comments included — carry only what the code cannot: constraints, pitfalls, units, and design-doc section references. Never restate a name or a signature. See `docs/coding-guidelines.md` §8.

Documentation is written in Japanese; keep that language when editing docs. Commits follow Conventional Commits (`docs: ...`), with the *why* in the body.

### Repo operations (use scripts/)

| Operation | Script |
| --- | --- |
| Commit | `scripts/wf-commit.sh` |
| Push | `scripts/wf-push.sh` |
| Review diff (PR or branch) | `scripts/wf-review-diff.sh` |
| Create an Issue | `scripts/wf-issue-create.sh` |
| Update Issue Project status | `scripts/wf-project-status.sh` |
| Create a PR | `scripts/wf-pr-create.sh` |
| Merge a PR | `scripts/wf-pr-merge.sh` |
| Close a PR without merging | `scripts/wf-pr-close.sh` |
| Read / reply to PR comments | `scripts/wf-pr-comments.sh` / `scripts/wf-pr-reply.sh` |
| Clean up merged branches | `scripts/wf-cleanup-branches.sh` |

Both agents and humans perform these operations through the scripts, never through raw `git`/`gh` write commands. If a request can't be expressed through a script, fix the script — don't route around it with a raw command.

Always invoke these from the repository root as `scripts/wf-*.sh <args>` — the `.claude/settings.json` allow rules are defined against that exact string form.

Merging is squash-only, with commit title `<PR title> (#N)` — so PR titles follow Conventional Commits too (`wf-pr-create.sh` and `wf-pr-merge.sh` both enforce this); `scripts/wf-pr-merge.sh` enforces checks-GREEN before it will merge.

## The product in one line

A macOS terminal app that runs multiple AI agents in parallel, one per Git worktree, each backed by its own persistent tmux session, with iPhone/iPad acting as thin remote clients to the same Mac host.

## Architecture constraints that shape all future code

These are recorded as **確定** (decided) in `docs/architecture.md` and should be treated as fixed unless the user changes them:

- **1 development task = 1 Git worktree = 1 task tab = 1 dedicated tmux session.** The Project Root gets its own separate permanent tmux session, outside the task-tab model.
- **The Agent Terminal is always the primary UI.** Code, Diff, and Evidence appear only on demand in a Viewer Drawer (max 2 panes).
- **Do not reimplement tmux.** Pane splitting, key bindings, and session management stay in tmux; the app exposes only a minimal operation set (split, close, select, zoom) and reads pane/process/agent state.
- **tmux and git are driven as external CLI processes**, not as embedded libraries (no libgit2). Rationale: the app must observe the same entities the user sees in their own terminal, and version differences get absorbed at an adapter boundary.
- **Git is read-heavy, write-free.** Viewing (file browser, code viewer, diff, history/blame) is rich; commit/merge/rebase/worktree-creation is delegated to the agent or a plain shell. Worktree creation belongs to the agent because naming/placement rules are project-specific.
- **Agent-agnostic via `AgentAdapter`** (`ClaudeCodeAdapter`, `CodexAdapter`, process-detection fallback). Never build a Claude-Code-only feature. Normalized states are `Working / Question / Permission / Completed(Ready for Review) / Error / Idle / Unknown`, with tab priority `Needs Attention > Ready for Review > Working > Idle`.
- **`Unknown` is a first-class state.** When an adapter cannot determine state, never round it to `Working` or `Idle`.
- **Mac/PC is the only execution host.** No repositories, agent processes, or Docker on iOS devices; mobile connects over SSH and attaches to the same tmux session. Multiple devices may attach simultaneously with no input-exclusion mechanism.
- **Terminal core and Agent Skills stay decoupled.** The terminal must work as a plain terminal + worktree manager with no Agent Skills present, and must not invent phase state it cannot observe. Agent Skills must run without any terminal-specific API.
- **Single-user product.** One developer, their own Mac host, their own devices. No multi-user/team sharing, accounts, or permissions.
- **Remote reachability is delegated to the user's VPN** (e.g. Tailscale); the app only speaks SSH and ships no relay/NAT-traversal infrastructure. Structured data (agent state, diff, evidence) is available to mobile only while the Mac app (Host Core) is running — no standalone daemon; bare SSH + tmux attach still works without it.
- **Push notifications** use an opt-in lightweight relay to APNs with a minimal payload (worktree ID + notification kind; never code or terminal output). Without the relay, only local notifications while connected.
- **Diff review comments are sent to the implementation agent pane** (not the consultation pane). The consultation feature (`Ask Agent`, renamed from "Ask Claude") stays separate.
- **Agent Skills flow is a 4-phase pipeline** (requirements → design → implementation → independent review session, each with fresh context) as the final goal; per-phase details remain open.
- **Explicit non-goals:** full code editor/IDE, full Git client, GitHub PR review client, CI dashboard, tmux GUI replacement, web preview/DevTools, VNC, a custom chat UI built by parsing Claude Code output, a custom remote-terminal protocol, and any credential/SSH-key management (Git auth is fully delegated to the host environment).

## Planned stack (candidate, PoC-gated)

Swift 6 + SwiftUI, libghostty behind a `TerminalRenderer` protocol, tmux CLI, git CLI, SwiftNIO SSH for iOS, SQLite + GRDB (metadata only; large blobs on the filesystem), ripgrep CLI, and a small `hostctl` JSON-Lines CLI over separate SSH channels for structured data.

Everything in `docs/architecture.md` §21–22 is **現在の推奨** (leading candidate), not adopted — including Swift 6 / SwiftUI, so the SwiftPM scaffolding under `AgentWorkflowTerminal/` follows the recommendation and does not by itself make it 確定. The one exception is §21.5: Gate 1 passed on 2026-08-31 and libghostty for the **macOS** `TerminalRenderer` is now 確定 (the iOS renderer is not). Gates 2–5 in §24 are still unrun.

## Agent workflow (validated 2026-09-01)

Implementation tasks use a three-role pipeline, validated end-to-end on the tmux `list-panes` parser (3 rounds to converge; the pilot caught 2 Critical bugs in code that was fully GREEN).

**Roles**
- **Director** (the main Claude session): research, decisions, task decomposition, spec writing, progress judgment, reporting. Does not implement.
- **Implementer** (Codex): `codex exec` non-interactively with the workspace-write sandbox; follow-ups via `codex exec resume --last` (no sandbox flags — the session's settings carry over). Codex reads `AGENTS.md`, not this file; `AGENTS.md` is a thin bridge that points here and to `docs/coding-guidelines.md` — keep it a pointer, never a second copy of the rules. When Codex is unavailable, fall back to the implementer subagent defined in `.claude/agents/implementer.md`.
- **Reviewer** (an Opus subagent): adversarial diff review of each implementation commit. Must verify claims about external-CLI behavior by **measurement** (isolated resources — e.g. a dedicated `tmux -L` socket — cleaned up afterwards), not by reading code alone. Critical findings block completion. Its definition lives in `.claude/agents/reviewer.md`.

**The loop**
1. Director writes an Issue-style spec: 背景 / 要求 / スコープ (files allowed to change) / 完了条件 (the exact GREEN commands) / "on ambiguity or contradiction, stop and ask". Known limitation: in exec mode Codex tends to work around contradictions and report them instead of stopping — treat a reported workaround as a spec defect and widen the scope explicitly in the next round rather than blaming the implementer.
2. Implementer delivers; Director independently re-runs the GREEN commands (cheap; trust but verify).
3. Reviewer reviews adversarially, classifying Critical / Major / Minor and separating code defects from **spec defects** (the pilot found both).
4. Critical findings go back to the implementer via `codex exec resume` as a fix spec. **Review findings are hypotheses**: any claim in a fix spec about external behavior must be re-verified by the implementer with a measurement before coding — the pilot's only regression came from implementing a reviewer's unverified premise. Continue looping while each round is backed by fresh measurement; escalate to the user when a round fails without new evidence or a design question emerges.
5. Completion is reported only with GREEN + no Critical remaining.

**When to skip the pipeline**: docs, config, and few-line mechanical changes — the spec+review overhead exceeds the value; the Director or a single subagent handles them directly. Anything that parses external output, touches state models, or crosses a module boundary goes through the full loop.

**Scope discipline** (applies to every role): no changes beyond the spec'd scope — no drive-by refactors or周辺整理. GREEN (build / test / lint) is a necessary gate, never evidence of quality; only adversarial review with measurement is.

## Task tracking (GitHub Projects)

Issues are the single source of truth (see Repository state); [Project #6](https://github.com/users/odaryo/projects/6) is the board over them. One Issue = one worktree = one PR = one task tab.

| Status | Meaning | Transition |
| --- | --- | --- |
| `Todo` | 未着手 | Issue Open 時 — 自動 (CI `project-status.yml`。Project 未追加の Issue は対象外) |
| `In Progress` | 実装中 | **worktree を作った時** — 手動 (`wf-project-status.sh`) |
| `In Review` | マージ判断待ち | PR Open 時 — 自動 (CI `project-status.yml`。draft は除外) |
| `Done` | マージ済み | PR マージ時 — 自動 (CI `project-status.yml`) |

`In Review` / `Done` は PR 本文の `Closes #N` に依存する。無ければ `In Progress` から先へ進まない。`Todo` の対象は「Open から30秒以内に Project #6 に載っている Issue」で、`wf-issue-create.sh` の `--project` (既定) はこれを満たす。`--no-project` で外したものは CI も board に載せない (item が現れるまで短くリトライし、現れなければ warning を出して何もしない)。既に Status が入っている item は上書きしない — Issue 作成直後に `In Progress` へ動かす通常フローと、遅れて届いた CI が競合して巻き戻るのを防ぐため。 **ProjectV2 の built-in automation は使わない** — Status option ID の再生成で全て無効化されており (下記 `updateProjectV2Field` 警告の事故と整合)、ProjectV2 workflow には公開 API が無く再有効化・変更が Web UI でしかできないため、リポジトリ内で管理できる CI (`.github/workflows/project-status.yml`) に置き換えた。CI からの Status 更新には `secrets.PROJECT_TOKEN` (classic PAT / `project` スコープ) が必要で、未設定の間は warning のみ出して成功する。

`In Review` exists so that **"手が動いているタスク"と"ユーザーのマージ判断で止まっているタスク"が混ざらない** — agents run in parallel, so several tasks sit waiting on the user at once.

**「ユーザー確認待ち」には2種類ある。** `In Review` が拾うのはマージ判断待ちだけ。実装前にユーザーの決定が要るものは `設計判断` ラベルを付け、`Todo` に置いたまま **決定待ち** ビューで分離する — ラベル付きの Issue は着手不可なので、`Todo` を「着手可能」の意味に保つための区別。決定して `/decide` で設計書に反映したらラベルを外す。ステータスは増やさない。

Views: `Board` (Status グループ) / `決定待ち` (`label:"設計判断" -status:Done`) / `View 1` (全件テーブル)。

**Never edit the `Status` field's options via `updateProjectV2Field`** — the mutation replaces the whole option list, regenerating every option ID and clearing the Status of every existing item. Add options in the web UI, or back up `gh project item-list --format json` first and restore afterwards.

## License policy

The app itself is MIT (decided; matches `LICENSE`). Dependencies: permissive only (MIT/BSD/ISC/Apache-2.0). GPL/LGPL/AGPL and unknown licenses are rejected by default — this is why Mosh is not embedded and tmux/ripgrep are used as external CLIs rather than vendored source. Do not copy code from other projects "for reference"; depend on it properly or implement clean-room. Avoid branding that implies an official Ghostty derivative.

## Project slash commands

- `/design-status <topic>` — look up a topic in `docs/architecture.md` and report whether it is 確定 / 現在の推奨 / 未確定 / 対象外. Use before implementing anything.
- `/decide <decision>` — promote an item to 確定 and update the doc body, §25/§31, and Appendices A/B consistently.

## Editing `docs/architecture.md`

The document deliberately separates four statuses: **確定** / **現在の推奨** / **未確定** / **対象外・不採用**. Preserve that distinction — do not promote a 現在の推奨 or 未確定 item to 確定 without the user saying so, and keep §25 (terminal open questions) and §31 (Agent Skills open questions) in sync when something is decided. Appendix A (decided checklist) and Appendix B (candidate checklist) also need updating when status changes.

Part I (terminal app) and Part II (Agent Skills / dev workflow) are intentionally kept separate; do not merge concerns across them.
