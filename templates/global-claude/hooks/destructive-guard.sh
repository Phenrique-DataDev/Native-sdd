#!/usr/bin/env bash
# Hook PreToolUse (matcher Bash) — guard ASK do destrutivo NAO-git. ESPELHO de destructive-guard.ps1 (J5).
#
# Irmao do main-push-guard.sh / secret-guard.sh; usado quando NAO ha `pwsh`. Em cada Bash:
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

main() {
  command -v jq >/dev/null 2>&1 || exit 0
  command -v get_destructive_decision >/dev/null 2>&1 || exit 0   # lib ausente -> passthrough
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
