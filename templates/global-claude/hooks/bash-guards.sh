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

# Aviso de degradacao sem jq, 1x/dia. Os dois guards dependem do jq e o aviso deles (Y4) nunca
# chegava: este dispatcher saia antes de chama-los, e stderr de hook com exit 0 vai so para o debug
# log. O canal que chega ao usuario e' o systemMessage (doc de hooks + sonda com claude -p,
# 2026-09-12) -- em JSON FIXO por printf, porque o jq e' justamente o que falta.
_warn_no_jq() {
  local m="${TMPDIR:-/tmp}/.sdd-dispatch-no-jq.$(date +%Y%m%d 2>/dev/null)"
  [ -e "$m" ] && return 0
  printf '%s' '{"systemMessage":"[sdd] aviso: jq ausente - os guards de Bash (segredo e destrutivo) estao INATIVOS e os comandos passam sem pedir confirmacao. Instale o jq para reativar."}'
  : > "$m" 2>/dev/null || true
}

main() {
  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0

  # Sem jq nenhum guard roda nem ha como combinar as saidas -> passthrough, mas AVISANDO.
  command -v jq >/dev/null 2>&1 || { _warn_no_jq; exit 0; }

  local outs=() out g
  for g in secret-guard.sh destructive-guard.sh; do
    [ -f "$DIR/$g" ] || continue
    # Falha de um guard nao decide pelo outro: o erro fica contido nesta iteracao.
    out="$(printf '%s' "$raw" | bash "$DIR/$g" 2>/dev/null)" || out=""
    [ -n "${out//[[:space:]]/}" ] && outs+=("$out")
  done

  [ ${#outs[@]} -eq 0 ] && exit 0

  # Concatena as razoes (unicas, na ordem) num unico "ask" -- nenhuma e' descartada.
  local reason notes
  reason="$(printf '%s
' "${outs[@]}"     | jq -rs 'map(.hookSpecificOutput.permissionDecisionReason // empty)
              | map(select(. != "")) | unique_by(.) | join(" | ")')" || exit 0
  # Aviso avulso: guard degradado (lib ausente) devolve so systemMessage, sem decisao. Sem este
  # repasse o aviso morria aqui, porque acima so a razao do "ask" e' aproveitada.
  notes="$(printf '%s
' "${outs[@]}"     | jq -rs 'map(select(.hookSpecificOutput == null) | .systemMessage // empty)
              | map(select(. != "")) | unique_by(.) | join(" | ")')" || notes=""

  if [ -z "${reason//[[:space:]]/}" ]; then
    [ -z "${notes//[[:space:]]/}" ] && exit 0
    jq -nc --arg m "$notes" '{systemMessage: $m}'
    exit 0
  fi

  jq -nc --arg r "$reason" --arg m "$notes" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    },
    systemMessage: (if $m == "" then $r else $r + " | " + $m end)
  }'
  exit 0
}

# Guard: roda o fluxo so quando executado, nao quando sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
