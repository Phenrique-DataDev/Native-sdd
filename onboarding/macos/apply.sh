#!/usr/bin/env bash
# apply.sh (macOS) — orquestrador. Executa A1 (deps via Homebrew: install-clis.sh) e delega A2+
# (baseline ~/.claude, shim, MCP, suplementos, managed policy) ao miolo pwsh — o mesmo do Linux e do
# Windows (onboarding/windows/apply.ps1). Parse e repasse de flags: onboarding/posix/apply-common.sh.
#
# Uso:
#   ./apply.sh [--check] [--dry-run] [--skip-clis] [--non-interactive] [--force]
#              [--extra-plugins] [--themes "design reporting"] [--managed-policy Ask|Yes|No]
#              [--with-semantic-kb] [--semantic-kb-model M] [--semantic-kb-ollama-host URL]
#              [--with-herdr] [--keep-retired] [--overwrite-custom]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../posix/apply-common.sh
. "$SCRIPT_DIR/../posix/apply-common.sh"

# O A1 roda em processo filho: o brew que ele instalou (ou que já existia) não está no PATH DESTE
# processo, e o miolo pwsh precisa do node/npx dele (context7) e do ~/.local/bin (claude).
posix_after_a1() {
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then eval "$("$b" shellenv)"; break; fi
  done
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
}

posix_apply_main 'macOS' "$SCRIPT_DIR/install-clis.sh" "${BASH_SOURCE[0]}" "$@"
