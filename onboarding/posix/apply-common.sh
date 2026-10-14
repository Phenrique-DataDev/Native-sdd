#!/usr/bin/env bash
# apply-common.sh — orquestrador POSIX compartilhado (Linux/macOS). Sourced pelo <so>/apply.sh.
# A1 (deps, pelo install-clis.sh do SO) roda em processo filho; A2+ (baseline ~/.claude, shim, MCP,
# suplementos, managed policy) é delegado ao miolo pwsh — onboarding/windows/apply.ps1, agnóstico de
# SO desde a F1.
#
# Fonte ÚNICA do parse de flags e do repasse ao apply.ps1. Antes de existir, cada SO teria o seu — e o
# do Linux já não repassava -WithSemanticKb, -SemanticKbModel, -SemanticKbOllamaHost, -WithHerdr,
# -KeepRetired nem -OverwriteCustom (MACOS_ONBOARDING, 2026-09-10).

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Gancho chamado entre o A1 e a procura do pwsh. O A1 roda em processo FILHO, então o que ele pôs no
# PATH não chega aqui — o apply.sh do SO redefine isto quando precisa (o macOS carrega o brew).
posix_after_a1() { :; }

# uso: posix_apply_main <rotulo-do-SO> <install-clis.sh> <apply.sh-que-chamou> [flags...]
posix_apply_main() {
  local label="$1" clis="$2" self="$3"; shift 3
  local repo_root apply_ps1
  repo_root="$(cd "$(dirname "$self")/../.." && pwd)"
  apply_ps1="$repo_root/onboarding/windows/apply.ps1"

  local CHECK=0 DRYRUN=0 SKIP_CLIS=0 NONINTERACTIVE=0 FORCE=0 EXTRA_PLUGINS=0
  local THEMES="" MANAGED_POLICY=""
  local WITH_HERDR=0 KEEP_RETIRED=0 OVERWRITE_CUSTOM=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)                      CHECK=1 ;;
      --dry-run)                    DRYRUN=1 ;;
      --skip-clis)                  SKIP_CLIS=1 ;;
      --non-interactive)            NONINTERACTIVE=1 ;;
      --force)                      FORCE=1 ;;
      --extra-plugins)              EXTRA_PLUGINS=1 ;;
      --themes)                     shift; THEMES="${1:-}" ;;
      --themes=*)                   THEMES="${1#*=}" ;;
      --managed-policy)             shift; MANAGED_POLICY="${1:-}" ;;
      --managed-policy=*)           MANAGED_POLICY="${1#*=}" ;;
      --with-herdr)                 WITH_HERDR=1 ;;
      --keep-retired)               KEEP_RETIRED=1 ;;
      --overwrite-custom)           OVERWRITE_CUSTOM=1 ;;
      -h|--help)
        # O cabeçalho de comentário do apply.sh que chamou É a ajuda (fonte única, sem cópia).
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"
        return 0 ;;
      *) step WARN "flag desconhecida ignorada: $1" ;;
    esac
    shift
  done

  echo ''
  echo '╔═══════════════════════════════════════════╗'
  # 'Linux' e 'macOS' têm 5 letras: o mesmo literal alinha a borda para os dois.
  echo "║   Instalador de ambiente · SDD ($label)    ║"
  echo '╚═══════════════════════════════════════════╝'
  local MODE="INSTALAÇÃO"
  [ "$DRYRUN" = 1 ] && MODE="DRY-RUN (sem alterações)"
  [ "$CHECK" = 1 ]  && MODE="CHECK (sem alterações)"
  step INFO "Modo: $MODE | SkipClis: $SKIP_CLIS"
  step INFO "Repo: $repo_root"

  if [ ! -f "$apply_ps1" ]; then
    step FAIL "miolo não encontrado: $apply_ps1"
    return 2
  fi

  # --- A1: dependências ---------------------------------------------------
  echo ''
  local A1_RC=0
  if [ "$SKIP_CLIS" = 1 ]; then
    step SKIP "A1 (CLIs) pulado por --skip-clis"
  else
    CHECK="$CHECK" DRYRUN="$DRYRUN" bash "$clis" || A1_RC=$?
    [ "$A1_RC" -ne 0 ] && step WARN "A1 reportou falhas (rc=$A1_RC) — segue p/ A2 se pwsh existir"
  fi
  posix_after_a1

  # --- A2+: miolo pwsh ----------------------------------------------------
  echo ''
  if ! have pwsh; then
    step FAIL "pwsh indisponível após A1 — não é possível montar ~/.claude (A2)."
    step INFO "Instale o PowerShell 7 e rode de novo (ou: ./apply.sh sem --skip-clis)."
    return 1
  fi

  # -SkipClis é SEMPRE passado: fora do Windows, o A1 é do lado bash.
  local PS_ARGS=(-SkipClis)
  [ "$CHECK" = 1 ]            && PS_ARGS+=(-Check)
  [ "$DRYRUN" = 1 ]           && PS_ARGS+=(-DryRun)
  [ "$NONINTERACTIVE" = 1 ]   && PS_ARGS+=(-NonInteractive)
  [ "$FORCE" = 1 ]            && PS_ARGS+=(-Force)
  [ "$EXTRA_PLUGINS" = 1 ]    && PS_ARGS+=(-ExtraPlugins)
  if [ -n "$THEMES" ]; then
    # apply.ps1 -Themes é string[]: vírgulas viram espaços -> múltiplos args.
    # shellcheck disable=SC2206
    local THEMES_ARR=(${THEMES//,/ })
    PS_ARGS+=(-Themes "${THEMES_ARR[@]}")
  fi
  [ -n "$MANAGED_POLICY" ]    && PS_ARGS+=(-ManagedPolicy "$MANAGED_POLICY")
  [ "$WITH_HERDR" = 1 ]       && PS_ARGS+=(-WithHerdr)
  [ "$KEEP_RETIRED" = 1 ]     && PS_ARGS+=(-KeepRetired)
  [ "$OVERWRITE_CUSTOM" = 1 ] && PS_ARGS+=(-OverwriteCustom)

  step INFO "Delegando A2+ ao miolo: pwsh apply.ps1 ${PS_ARGS[*]}"
  pwsh -NoProfile -File "$apply_ps1" "${PS_ARGS[@]}"
}
