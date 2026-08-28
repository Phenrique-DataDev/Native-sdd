#!/usr/bin/env bash
# Dispatcher UNICO dos guards de Bash (par POSIX de bash-guards.ps1).
#
# No pwsh a consolidacao existe por CUSTO: cada hook paga ~367ms de startup do runtime, e dois
# hooks no mesmo matcher pagavam isso duas vezes por comando. No bash nao ha esse custo -- aqui
# o dispatcher existe por PARIDADE de comportamento: uma decisao combinada, com as razoes dos
# dois guards, em vez de duas respostas separadas.
#
# NAO funde os guards: secret-guard.sh e destructive-guard.sh seguem intactos e continuam sendo
# a fonte da logica (os dois definem main(), entao sourcear ambos colidiria -- por isso rodam
# como subprocesso, cada um com o SEU fail-safe preservado).

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0

  # Sem jq nao ha como combinar as saidas -> passthrough (mesma degradacao dos guards).
  command -v jq >/dev/null 2>&1 || exit 0

  local outs=() out g
  for g in secret-guard.sh destructive-guard.sh; do
    [ -f "$DIR/$g" ] || continue
    # Falha de um guard nao decide pelo outro: o erro fica contido nesta iteracao.
    out="$(printf '%s' "$raw" | bash "$DIR/$g" 2>/dev/null)" || out=""
    [ -n "${out//[[:space:]]/}" ] && outs+=("$out")
  done

  [ ${#outs[@]} -eq 0 ] && exit 0

  # Concatena as razoes (unicas, na ordem) num unico "ask" -- nenhuma e' descartada.
  local reason
  reason="$(printf '%s
' "${outs[@]}"     | jq -rs 'map(.hookSpecificOutput.permissionDecisionReason // empty)
              | map(select(. != "")) | unique_by(.) | join(" | ")')" || exit 0
  [ -z "${reason//[[:space:]]/}" ] && exit 0

  jq -nc --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    },
    systemMessage: $r
  }'
  exit 0
}

# Guard: roda o fluxo so quando executado, nao quando sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
