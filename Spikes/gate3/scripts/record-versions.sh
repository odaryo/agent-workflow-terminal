#!/usr/bin/env bash
# 計測に刻む版数 (PLAN.md M0 / §8 R3)。
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
{
  printf 'recorded_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'macos\t%s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf 'arch\t%s\n' "$(uname -m)"
  printf 'tmux\t%s\n' "$(tmux -V)"
  printf 'claude\t%s\n' "$(claude --version 2>&1 | head -1)"
  printf 'codex\t%s\n' "$(codex --version 2>&1 | head -1)"
} | tee "$G3_EVIDENCE/versions.tsv"
