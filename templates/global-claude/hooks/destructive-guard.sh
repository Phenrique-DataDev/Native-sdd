#!/usr/bin/env bash
# Hook PreToolUse (matcher Bash) — guard ASK do destrutivo NAO-git. ESPELHO de destructive-guard.ps1 (J5).
#
# Irmao do secret-guard.sh; usado quando NAO ha `pwsh`. Em cada Bash:
#   - destrutivo nao-git arriscado (rm -rf de alvo absoluto/home/var/glob, chmod -R 777, curl|sh) -> "ask"
#   - qualquer outro caso                                                                          -> PASSTHROUGH (exit 0)
#
# NUNCA usa "deny": so pede confirmacao (o deny inviolavel vive na managed policy). Sem git/rede ->
# sem fail-safe assimetrico: o lado seguro e' sempre silencio. Sem `jq` ou sem a lib -> passthrough.
#
# Deteccao vem da lib UNICA lib/destructive-patterns.sh (sourced). Paridade .ps1==.sh por Pester.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/lib/destructive-patterns.sh" ] && . "$HERE/lib/destructive-patterns.sh"

# PURA: monta o JSON da decisao. Espelha New-HookDecisionJson.
emit_decision() {
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r},systemMessage:$r}'
}

# Aviso unico (1x/dia, stderr, NUNCA bloqueia) quando a camada ASK degrada por dep ausente.
# Sem isso, a falta de jq/lib desliga o guard em SILENCIO (fail-OPEN) — Y4 do e2e.
_sdd_ask_degraded() {
  local m="${TMPDIR:-/tmp}/.sdd-ask-degraded.$(date +%Y%m%d 2>/dev/null)"
  [ -e "$m" ] && return 0
  printf '%s\n' "[sdd] aviso: '$1' ausente — guards interativos (.sh) INATIVOS (passthrough). Instale para reativar a camada ASK." >&2
  : > "$m" 2>/dev/null || true
}

main() {
  command -v jq >/dev/null 2>&1 || { _sdd_ask_degraded jq; exit 0; }
  command -v get_destructive_decision >/dev/null 2>&1 || { _sdd_ask_degraded 'lib de hooks'; exit 0; }   # lib ausente -> passthrough
  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0
  local tool command reason
  tool="$(printf '%s' "$raw" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
  [ "$tool" = "Bash" ] || exit 0
  command="$(printf '%s' "$raw" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [ -z "${command//[[:space:]]/}" ] && exit 0

  if reason="$(get_destructive_decision "$command")"; then
    emit_decision ask "$reason"
  fi
  exit 0
}

# Guard: roda o fluxo so quando executado, nao quando sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
