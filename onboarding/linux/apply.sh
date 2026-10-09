#!/usr/bin/env bash
# apply.sh (Linux) — orquestrador. Executa A1 (deps via install-clis.sh) e delega A2+
# (baseline ~/.claude, shim, MCP, suplementos, managed policy) ao miolo pwsh já testado
# (onboarding/windows/apply.ps1, agnóstico de SO desde a F1). Equivalente do windows/apply.ps1.
# Parse e repasse de flags: onboarding/posix/apply-common.sh (fonte única com o macOS).
#
# Uso:
#   ./apply.sh [--check] [--dry-run] [--skip-clis] [--non-interactive] [--force]
#              [--extra-plugins] [--themes "design reporting"] [--managed-policy Ask|Yes|No]
#              [--with-herdr] [--keep-retired] [--overwrite-custom]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../posix/apply-common.sh
. "$SCRIPT_DIR/../posix/apply-common.sh"

posix_apply_main 'Linux' "$SCRIPT_DIR/install-clis.sh" "${BASH_SOURCE[0]}" "$@"
