#!/usr/bin/env bash
# Degradacao CONSCIENTE do peer-heartbeat sem pwsh (J4). NAO porta a lógica de presença/heartbeat:
# ela vive em tools/peers.ps1 (funções puras + I/O, cobertas por Pester), FORA do escopo do .sh.
# Peering e' CONVENIENCIA (nao guarda de seguranca) -> mesmo precedente do curation-nudge.sh:
# sem pwsh, o quadro de peers simplesmente nao ativa.
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
  emit_context "$ev" "peers: coordenacao entre sessoes (/peers) indisponivel sem PowerShell (pwsh) neste ambiente (J4). Rode no Windows/local com pwsh para ativar o quadro de peers."
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
