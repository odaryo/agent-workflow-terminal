# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

`agent_workflow_terminal` is pre-alpha and currently **documentation-only**: there is no source code, no build system, and no test harness. The repository contains `README.md`, `docs/architecture.md`, `LICENSE` (MIT), `.editorconfig`, and a Swift/Xcode `.gitignore`.

There are therefore no build/lint/test commands yet. When the first Swift package or Xcode project lands, add its commands to this file.

Documentation is written in Japanese; keep that language when editing docs. Commits follow Conventional Commits (`docs: ...`).

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
- **Explicit non-goals:** full code editor/IDE, full Git client, GitHub PR review client, CI dashboard, tmux GUI replacement, web preview/DevTools, VNC, a custom chat UI built by parsing Claude Code output, a custom remote-terminal protocol, and any credential/SSH-key management (Git auth is fully delegated to the host environment).

## Planned stack (candidate, PoC-gated)

Swift 6 + SwiftUI, libghostty behind a `TerminalRenderer` protocol, tmux CLI, git CLI, SwiftNIO SSH for iOS, SQLite + GRDB (metadata only; large blobs on the filesystem), ripgrep CLI, and a small `hostctl` JSON-Lines CLI over separate SSH channels for structured data.

Everything in `docs/architecture.md` §21–22 is **現在の推奨** (leading candidate), not adopted. PoC gates 1–5 in §24 must pass first; Gate 1 (macOS libghostty + PTY + tmux quality) blocks broader UI work.

## License policy

Permissive only (MIT/BSD/ISC/Apache-2.0). GPL/LGPL/AGPL and unknown licenses are rejected by default — this is why Mosh is not embedded and tmux/ripgrep are used as external CLIs rather than vendored source. Do not copy code from other projects "for reference"; depend on it properly or implement clean-room. Avoid branding that implies an official Ghostty derivative.

## Project slash commands

- `/design-status <topic>` — look up a topic in `docs/architecture.md` and report whether it is 確定 / 現在の推奨 / 未確定 / 対象外. Use before implementing anything.
- `/decide <decision>` — promote an item to 確定 and update the doc body, §25/§31, and Appendices A/B consistently.

## Editing `docs/architecture.md`

The document deliberately separates four statuses: **確定** / **現在の推奨** / **未確定** / **対象外・不採用**. Preserve that distinction — do not promote a 現在の推奨 or 未確定 item to 確定 without the user saying so, and keep §25 (terminal open questions) and §31 (Agent Skills open questions) in sync when something is decided. Appendix A (decided checklist) and Appendix B (candidate checklist) also need updating when status changes.

Part I (terminal app) and Part II (Agent Skills / dev workflow) are intentionally kept separate; do not merge concerns across them.
