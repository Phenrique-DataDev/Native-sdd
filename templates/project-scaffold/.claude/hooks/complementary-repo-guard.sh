#!/usr/bin/env bash
# Hook PreToolUse (matcher Write|Edit) — backstop do boundary read-only de repositorios
# complementares (REPOS_COMPLEMENTARES, DESIGN D3). ESPELHO SHELL de complementary-repo-guard.ps1.
#
# Em cada Write/Edit:
#   - file_path cai dentro de um Path registrado (.claude/complementary-repos.psd1, ainda no
#     disco) OU dentro do cache .claude/.cache/complementary-repos/          -> "ask"
#   - qualquer outro caso                                                    -> PASSTHROUGH (exit 0)
#
# NUNCA usa "deny": so pede confirmacao (mesma filosofia do .ps1/secret-guard/destructive-guard).
# Fail-safe ASSIMETRICO: registro AUSENTE -> passthrough. Registro PRESENTE mas erro de leitura ->
# "ask". Sem `jq` -> degrada em SILENCIO (fail-OPEN, aviso 1x/dia — molde secret-guard.sh), pois
# sem jq nao ha como nem parsear o payload.
#
# Parse do .psd1 e' INTENCIONALMENTE simples (nao um parser PSD1 geral): o arquivo e' sempre
# gerado por tools/complementary-repos.ps1 (ConvertTo-ComplementaryRepoPsd1Text) no formato fixo
# `Path   = 'valor'` uma chave por linha — extraido via sed, sem depender de pwsh.

emit_decision() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r},systemMessage:$r}'
}

# Aviso unico (1x/dia, stderr, NUNCA bloqueia) quando falta jq. Molde secret-guard.sh.
_sdd_ask_degraded() {
  local m="${TMPDIR:-/tmp}/.sdd-complementary-guard-degraded.$(date +%Y%m%d 2>/dev/null)"
  [ -e "$m" ] && return 0
  printf '%s\n' "[sdd] aviso: 'jq' ausente — complementary-repo-guard (.sh) INATIVO (passthrough). Instale jq para reativar." >&2
  : > "$m" 2>/dev/null || true
}

# PURA: extrai os valores de `Path = '...'` do registro .psd1 (formato fixo, ver cabecalho).
extract_registered_paths() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n "s/^[[:space:]]*Path[[:space:]]*=[[:space:]]*'\(.*\)'[[:space:]]*$/\1/p" "$file"
}

# PURA: normaliza um path (barra unica, minusculo, sem barra final) p/ comparacao.
normalize_path() {
  printf '%s' "$1" | tr '\\' '/' | tr '[:upper:]' '[:lower:]' | sed 's:/*$::'
}

# PURA: $1 (file_path normalizado) cai dentro de algum path protegido (lista em $2, um por linha)?
path_under_protected() {
  local target="$1" list="$2" p pn
  [ -z "$target" ] && return 1
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    pn="$(normalize_path "$p")"
    [ "$target" = "$pn" ] && return 0
    case "$target" in "$pn"/*) return 0 ;; esac
  done <<< "$list"
  return 1
}

main() {
  command -v jq >/dev/null 2>&1 || { _sdd_ask_degraded; exit 0; }

  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0

  local tool file_path cwd
  tool="$(printf '%s' "$raw" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
  case "$tool" in Write|Edit) ;; *) exit 0 ;; esac

  file_path="$(printf '%s' "$raw" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  [ -z "${file_path//[[:space:]]/}" ] && exit 0

  cwd="$(printf '%s' "$raw" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -z "$cwd" ] && cwd="$(pwd)"

  local registry_path="$cwd/.claude/complementary-repos.psd1"
  [ -f "$registry_path" ] || exit 0   # nada registrado -> passthrough

  # Registro presente: monta a lista de paths protegidos (cache root + Path de cada entrada).
  # NAO usa `cd ... && pwd` para "resolver": no Git Bash/MSYS isso reescreve um path Windows
  # (C:\...) para a forma POSIX do mount (/c/... ou /tmp/...), que nao bate mais, em string, com
  # o file_path recebido do payload (sempre no estilo do host, Windows). Fica no MESMO espaco de
  # path do payload — normalize_path (barra+minusculo) ja basta para a comparacao de prefixo.
  local cache_root="$cwd/.claude/.cache/complementary-repos"
  local protected="$cache_root"
  local paths; paths="$(extract_registered_paths "$registry_path")"
  if [ -n "$paths" ]; then
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ -d "$p" ] && protected="$protected"$'\n'"$p"
    done <<< "$paths"
  fi

  local target; target="$(normalize_path "$file_path")"
  if path_under_protected "$target" "$protected"; then
    emit_decision "O caminho '$file_path' pertence a um repositorio complementar registrado (leitura-only). Confirme que quer mesmo escrever fora do projeto atual."
    exit 0
  fi
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
