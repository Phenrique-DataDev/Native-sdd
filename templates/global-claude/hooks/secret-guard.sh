#!/usr/bin/env bash
# Hook PreToolUse (matcher Bash) — guard de SEGREDOS em modo "ask". ESPELHO SHELL de secret-guard.ps1.
#
# Irmao do main-push-guard.sh; usado quando NAO ha `pwsh`. Em cada Bash:
#   - comando le/exfiltra arquivo de segredo (.env/*.pem/secrets/…)        -> "ask"
#   - `git commit` cujo diff STAGED contem segredo de ALTA confianca        -> "ask"
#   - `git push`  cujo diff a ENVIAR contem segredo de ALTA confianca       -> "ask"
#   - qualquer outro caso                                                   -> PASSTHROUGH (exit 0)
#
# NUNCA usa "deny": so pede confirmacao. A rede deterministica (pre-commit/managed policy) e' a
# camada de bloqueio real. Fail-safe ASSIMETRICO (igual ao .ps1). Sem `jq` ou sem a lib -> passthrough.
#
# Deteccao vem da lib UNICA lib/secret-patterns.sh (sourced). Paridade verificada por Pester (AT-009).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/lib/secret-patterns.sh" ] && . "$HERE/lib/secret-patterns.sh"

# PURA: monta o JSON da decisao. Espelha New-HookDecisionJson.
emit_decision() {
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r},systemMessage:$r}'
}

# PURA: o comando e' um `git <…> <sub>`? Espelha Test-IsGitSubcommand (sub e' alnum: commit/push).
is_git_subcommand() {
  local cmd="${1-}" sub="${2-}" seg norm
  [ -z "${cmd//[[:space:]]/}" ] && return 1
  norm="$(printf '%s' "$cmd" | tr -d '\r' | sed -E 's/&&|\|\||;|\|/\n/g')"
  while IFS= read -r seg; do
    printf '%s' "$seg" | grep -qP "(^|\s)git\s+(\S+\s+)*${sub}(\s|$)" && return 0
  done <<< "$norm"
  return 1
}

# PURA: o comando le/exfiltra um arquivo de segredo? Espelha Test-IsSecretRead.
is_secret_read() {
  local cmd="${1-}" seg norm tok t
  [ -z "${cmd//[[:space:]]/}" ] && return 1
  command -v is_secret_file_path >/dev/null 2>&1 || return 1
  local readers='(cat|type|gc|Get-Content|bat|less|more|head|tail|strings|nl)'
  norm="$(printf '%s' "$cmd" | tr -d '\r' | sed -E 's/&&|\|\||;|\|/\n/g')"
  while IFS= read -r seg; do
    printf '%s' "$seg" | grep -qiP "(^|\s)${readers}\s" || continue
    for tok in $seg; do
      t="${tok#[\"\']}"; t="${t%[\"\']}"
      [ -n "$t" ] || continue
      case "$t" in -*) continue ;; esac
      is_secret_file_path "$t" && return 0
    done
  done <<< "$norm"
  return 1
}

# PURA: extrai as linhas ADICIONADAS de um diff unificado (stdin). Espelha Get-AddedLine.
added_lines() {
  grep '^+' | grep -v '^+++' | sed 's/^+//'
}

# PURA: achados (nomes no stdin) -> texto curto do motivo. Espelha Format-SecretReason.
format_secret_reason() {
  local ctx="${1-}" names
  names="$(sort -u | paste -sd ',' - | sed 's/,/, /g')"
  [ -z "$names" ] && names='(indeterminado)'
  printf '%s contem possivel segredo (%s). Confirmacao exigida — revise antes de prosseguir.' "$ctx" "$names"
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
  command -v find_secret_match >/dev/null 2>&1 || { _sdd_ask_degraded 'lib de hooks'; exit 0; }   # lib ausente -> passthrough
  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0
  local tool command
  tool="$(printf '%s' "$raw" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
  [ "$tool" = "Bash" ] || exit 0
  command="$(printf '%s' "$raw" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [ -z "${command//[[:space:]]/}" ] && exit 0

  # Leitura/exfiltracao de arquivo de segredo (independe de git) -> ask
  if is_secret_read "$command"; then
    emit_decision ask 'Comando le um arquivo de segredo (.env/chave). Confirmacao exigida.'
    exit 0
  fi

  local is_commit=0 is_push=0
  is_git_subcommand "$command" commit && is_commit=1
  is_git_subcommand "$command" push   && is_push=1
  { [ "$is_commit" -eq 0 ] && [ "$is_push" -eq 0 ]; } && exit 0   # nao relevante -> passthrough

  # Daqui e' relevante: erro = ask (fail-safe assimetrico).
  local diff added names reason
  if [ "$is_commit" -eq 1 ]; then
    if diff="$(git diff --cached --unified=0 2>/dev/null)"; then
      added="$(printf '%s' "$diff" | added_lines)"
      names="$(find_secret_match "$added")"
      if [ -n "$names" ]; then
        reason="$(printf '%s\n' "$names" | format_secret_reason 'O commit (staged)')"
        emit_decision ask "$reason"; exit 0
      fi
    else
      emit_decision ask 'Nao foi possivel verificar segredos no diff. Confirmacao exigida.'; exit 0
    fi
  fi
  if [ "$is_push" -eq 1 ]; then
    if diff="$(git diff --unified=0 '@{upstream}...HEAD' 2>/dev/null)"; then :; else
      local def='main' ref
      ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && [ -n "$ref" ] && def="${ref#origin/}"
      diff="$(git diff --unified=0 "${def}...HEAD" 2>/dev/null)" || { emit_decision ask 'Nao foi possivel verificar segredos no diff. Confirmacao exigida.'; exit 0; }
    fi
    added="$(printf '%s' "$diff" | added_lines)"
    names="$(find_secret_match "$added")"
    if [ -n "$names" ]; then
      reason="$(printf '%s\n' "$names" | format_secret_reason 'O push')"
      emit_decision ask "$reason"; exit 0
    fi
  fi
  exit 0   # relevante mas sem segredo -> passthrough
}

# Guard: roda o fluxo so quando executado, nao quando sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
