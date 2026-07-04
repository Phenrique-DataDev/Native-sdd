#!/usr/bin/env bash
# apply.sh (Linux) — orquestrador. Executa A1 (deps via install-clis.sh) e delega A2+
# (baseline ~/.claude, shim, MCP, suplementos, managed policy) ao miolo pwsh já testado
# (onboarding/windows/apply.ps1, agnóstico de SO desde a F1). Equivalente do windows/apply.ps1.
#
# Uso:
#   ./apply.sh [--check] [--dry-run] [--skip-clis] [--non-interactive]
#              [--extra-plugins] [--themes "design reporting"]
#              [--with-local-ai] [--local-ai-model M] [--local-ai-ollama-host URL]
#              [--managed-policy Ask|Yes|No]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APPLY_PS1="$REPO_ROOT/onboarding/windows/apply.ps1"

step() { printf '[%-7s] %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

show_help() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- defaults / parse -----------------------------------------------------
CHECK=0; DRYRUN=0; SKIP_CLIS=0; NONINTERACTIVE=0; EXTRA_PLUGINS=0; WITH_LOCAL_AI=0
THEMES=""; LOCAL_AI_MODEL=""; LOCAL_AI_HOST=""; MANAGED_POLICY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)                 CHECK=1 ;;
    --dry-run)               DRYRUN=1 ;;
    --skip-clis)             SKIP_CLIS=1 ;;
    --non-interactive)       NONINTERACTIVE=1 ;;
    --extra-plugins)         EXTRA_PLUGINS=1 ;;
    --with-local-ai)         WITH_LOCAL_AI=1 ;;
    --themes)                shift; THEMES="${1:-}" ;;
    --themes=*)              THEMES="${1#*=}" ;;
    --local-ai-model)        shift; LOCAL_AI_MODEL="${1:-}" ;;
    --local-ai-model=*)      LOCAL_AI_MODEL="${1#*=}" ;;
    --local-ai-ollama-host)  shift; LOCAL_AI_HOST="${1:-}" ;;
    --local-ai-ollama-host=*) LOCAL_AI_HOST="${1#*=}" ;;
    --managed-policy)        shift; MANAGED_POLICY="${1:-}" ;;
    --managed-policy=*)      MANAGED_POLICY="${1#*=}" ;;
    -h|--help)               show_help; exit 0 ;;
    *)                       step WARN "flag desconhecida ignorada: $1" ;;
  esac
  shift
done

# --- banner ---------------------------------------------------------------
echo ''
echo '╔═══════════════════════════════════════════╗'
echo '║   Instalador de ambiente · SDD (Linux)    ║'
echo '╚═══════════════════════════════════════════╝'
MODE="INSTALAÇÃO"
[ "$DRYRUN" = 1 ] && MODE="DRY-RUN (sem alterações)"
[ "$CHECK" = 1 ]  && MODE="CHECK (sem alterações)"
step INFO "Modo: $MODE | SkipClis: $SKIP_CLIS"
step INFO "Repo: $REPO_ROOT"

if [ ! -f "$APPLY_PS1" ]; then
  step FAIL "miolo não encontrado: $APPLY_PS1"
  exit 2
fi

# --- A1: dependências -----------------------------------------------------
echo ''
A1_RC=0
if [ "$SKIP_CLIS" = 1 ]; then
  step SKIP "A1 (CLIs) pulado por --skip-clis"
else
  CHECK="$CHECK" DRYRUN="$DRYRUN" bash "$SCRIPT_DIR/install-clis.sh" || A1_RC=$?
  [ "$A1_RC" -ne 0 ] && step WARN "A1 reportou falhas (rc=$A1_RC) — segue p/ A2 se pwsh existir"
fi

# --- A2+: miolo pwsh ------------------------------------------------------
echo ''
if ! have pwsh; then
  step FAIL "pwsh indisponível após A1 — não é possível montar ~/.claude (A2)."
  step INFO "Instale o PowerShell 7 e rode de novo (ou: ./apply.sh sem --skip-clis)."
  exit 1
fi

# Monta os argumentos do miolo. -SkipClis é SEMPRE passado: no Linux, A1 é do lado bash.
PS_ARGS=(-SkipClis)
[ "$CHECK" = 1 ]          && PS_ARGS+=(-Check)
[ "$DRYRUN" = 1 ]         && PS_ARGS+=(-DryRun)
[ "$NONINTERACTIVE" = 1 ] && PS_ARGS+=(-NonInteractive)
[ "$EXTRA_PLUGINS" = 1 ]  && PS_ARGS+=(-ExtraPlugins)
[ "$WITH_LOCAL_AI" = 1 ]  && PS_ARGS+=(-WithLocalAi)
if [ -n "$THEMES" ]; then
  # apply.ps1 -Themes é string[]: vírgulas viram espaços → múltiplos args.
  # shellcheck disable=SC2206
  THEMES_ARR=(${THEMES//,/ })
  PS_ARGS+=(-Themes "${THEMES_ARR[@]}")
fi
[ -n "$LOCAL_AI_MODEL" ] && PS_ARGS+=(-LocalAiModel "$LOCAL_AI_MODEL")
[ -n "$LOCAL_AI_HOST" ]  && PS_ARGS+=(-LocalAiOllamaHost "$LOCAL_AI_HOST")
[ -n "$MANAGED_POLICY" ] && PS_ARGS+=(-ManagedPolicy "$MANAGED_POLICY")

step INFO "Delegando A2+ ao miolo: pwsh apply.ps1 ${PS_ARGS[*]}"
pwsh -NoProfile -File "$APPLY_PS1" "${PS_ARGS[@]}"
exit $?
