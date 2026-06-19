#!/usr/bin/env bash
# Hook PreToolUse (C6) — guard de push na branch default. ESPELHO SHELL de main-push-guard.ps1.
#
# Usado quando NAO ha `pwsh` (sandbox Linux do claude.ai/code, WSL, outro OS). O registro no
# settings.json e' uma dispatch-line que escolhe .ps1 (com pwsh) ou .sh (sem). Em cada Bash:
#   - comando != `git push`  OU  branch != default  -> PASSTHROUGH (exit 0, sem stdout)
#   - na default, push SOMENTE-DOCS                  -> permissionDecision "allow"
#   - na default, push com >=1 arquivo nao-doc       -> permissionDecision "ask"
#
# Fail-safe ASSIMETRICO (igual ao .ps1): antes de confirmar "push na default", qualquer erro vira
# PASSTHROUGH; DEPOIS de confirmar, qualquer erro vira "ask" — nunca "allow" por engano.
# Sem `jq` -> PASSTHROUGH (lado seguro: e' antes de qualquer confirmacao).
#
# Paridade de decisao com o .ps1 verificada por tools/tests/hooks-portable.Tests.ps1.
# Funcoes puras sao testaveis; o fluxo so roda quando o script NAO e' sourced (guard no fim).

# PURA: o comando Bash e' um `git … push`? Espelha Test-IsGitPush.
is_git_push() {
  local cmd="${1-}" seg norm
  [ -z "${cmd//[[:space:]]/}" ] && return 1
  norm="$(printf '%s' "$cmd" | tr -d '\r' | sed -E 's/&&|\|\||;|\|/\n/g')"
  while IFS= read -r seg; do
    printf '%s' "$seg" | grep -qP '(^|\s)git\s+(\S+\s+)*push(\s|$)' && return 0
  done <<< "$norm"
  return 1
}

# PURA: o path e' documentacao? Espelha Test-IsDocPath.
is_doc_path() {
  local p
  p="$(printf '%s' "${1-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$p" ] && return 1
  p="${p//\\//}"
  printf '%s' "$p" | grep -qE '\.md$' && return 0
  printf '%s' "$p" | grep -qE '^(docs|methodology|features)/' && return 0
  return 1
}

# PURA: caminhos (1/linha no stdin) -> "DECISION<TAB>NONDOCS". Espelha Get-PushDecision.
push_decision() {
  local any=0 line
  local nondocs=()
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    any=1
    is_doc_path "$line" || nondocs+=("$line")
  done
  if [ "$any" -eq 0 ]; then printf 'ask\t\n'; return; fi          # fail-safe: sem paths -> ask
  if [ "${#nondocs[@]}" -eq 0 ]; then printf 'allow\t\n'; return; fi
  local joined; joined="$(printf '%s, ' "${nondocs[@]}")"; joined="${joined%, }"
  printf 'ask\t%s\n' "$joined"
}

# PURA: monta o JSON da decisao (schema PreToolUse). Espelha New-HookDecisionJson.
emit_decision() {
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r},systemMessage:$r}'
}

# I/O (read-only): branch atual / default / paths a enviar. Espelham as funcoes git do .ps1.
current_branch() {
  local b; b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
  printf '%s' "$b" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
default_branch() {
  local ref; ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then printf '%s' "${ref#origin/}"; return; fi
  printf 'main'   # fallback conservador
}
push_paths() {
  local paths
  if paths="$(git diff --name-only '@{upstream}...HEAD' 2>/dev/null)"; then
    printf '%s\n' "$paths"; return 0
  fi
  local def; def="$(default_branch)"
  if paths="$(git diff --name-only "${def}...HEAD" 2>/dev/null)"; then
    printf '%s\n' "$paths"; return 0
  fi
  return 1
}

# Aviso unico (1x/dia, stderr, NUNCA bloqueia) quando a camada ASK degrada por dep ausente.
# Sem isso, a falta de jq desliga o guard em SILENCIO (fail-OPEN) — Y4 do e2e.
_sdd_ask_degraded() {
  local m="${TMPDIR:-/tmp}/.sdd-ask-degraded.$(date +%Y%m%d 2>/dev/null)"
  [ -e "$m" ] && return 0
  printf '%s\n' "[sdd] aviso: '$1' ausente — guards interativos (.sh) INATIVOS (passthrough). Instale para reativar a camada ASK." >&2
  : > "$m" 2>/dev/null || true
}

main() {
  command -v jq >/dev/null 2>&1 || { _sdd_ask_degraded jq; exit 0; }   # sem jq -> passthrough (antes de confirmar)
  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0
  local tool command
  tool="$(printf '%s' "$raw" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
  [ "$tool" = "Bash" ] || exit 0
  command="$(printf '%s' "$raw" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  is_git_push "$command" || exit 0

  local cur def
  cur="$(current_branch)" || exit 0
  def="$(default_branch)"
  { [ -n "$cur" ] && [ -n "$def" ] && [ "$cur" = "$def" ]; } || exit 0

  # Daqui: estamos na default com um push -> erro = ask (fail-safe assimetrico).
  local paths res dec nondocs
  if paths="$(push_paths)"; then
    res="$(printf '%s\n' "$paths" | push_decision)"
    dec="${res%%$'\t'*}"; nondocs="${res#*$'\t'}"
    if [ "$dec" = "allow" ]; then
      emit_decision allow "push somente-docs na '$def': liberado."
    else
      [ -z "$nondocs" ] && nondocs='(indeterminado)'
      emit_decision ask "push na '$def' com arquivos nao-doc: $nondocs. Confirmacao exigida."
    fi
  else
    emit_decision ask "push na '$def': nao foi possivel verificar o diff. Confirmacao exigida."
  fi
  exit 0
}

# Guard: roda o fluxo so quando executado, nao quando sourced (testes fazem `source`).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
