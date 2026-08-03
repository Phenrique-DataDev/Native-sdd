#!/usr/bin/env bash
# Degradacao CONSCIENTE do curation-nudge sem pwsh (J4). NAO porta os sinais de staleness:
# eles dependem da camada tools/*.ps1 (init/update-skills/sync-context/agent-lint/kb-lint),
# que esta FORA do escopo do J4. Aqui apenas avisamos 1x por sessao que o nudge requer pwsh —
# para que a ausencia da curadoria nao passe em silencio total fora do Windows.
#
# Acionado pela dispatch-line do settings.json SO quando nao ha pwsh. Read-only, nunca bloqueia.
#   - SessionStart -> 1 additionalContext curto avisando a indisponibilidade
#   - PostToolUse / demais / erro / sem jq -> SILENCIO (exit 0)

emit_context() {
  jq -nc --arg e "$1" --arg c "$2" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
}

main() {
  command -v jq >/dev/null 2>&1 || exit 0
  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0
  local ev; ev="$(printf '%s' "$raw" | jq -r '.hook_event_name // "SessionStart"' 2>/dev/null)"
  [ "$ev" = "SessionStart" ] || exit 0   # so no baseline de sessao; PostToolUse -> silencio
  emit_context "$ev" "curation-nudge: avisos de staleness da curadoria indisponiveis sem PowerShell (pwsh) neste ambiente (J4). Rode no Windows/local com pwsh, ou use /init e /sync-context manualmente."
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
