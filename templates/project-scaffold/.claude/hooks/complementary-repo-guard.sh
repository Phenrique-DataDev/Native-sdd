#!/usr/bin/env bash
# Hook PreToolUse (matcher Write|Edit|Bash|PowerShell) — backstop do boundary read-only de repositorios
# complementares (REPOS_COMPLEMENTARES, DESIGN D3). ESPELHO SHELL de complementary-repo-guard.ps1.
#
# Em cada Write/Edit (e em cada Bash/PowerShell, pelo destino de escrita do comando):
#   - file_path cai dentro de um Path registrado (.claude/complementary-repos.psd1, ainda no
#     disco) OU dentro do cache .claude/.cache/complementary-repos/          -> "ask"
#   - qualquer outro caso                                                    -> PASSTHROUGH (exit 0)
# No shell, ler passa; escrita por script (python -c) ou caminho em variavel nao e' vista.
#
# NUNCA usa "deny": so pede confirmacao (mesma filosofia do .ps1/secret-guard/destructive-guard).
# Fail-safe ASSIMETRICO: registro AUSENTE -> passthrough. Registro PRESENTE mas erro de leitura ->
# "ask". Sem `jq` -> degrada (fail-OPEN), pois sem jq nao ha como nem parsear o payload; o aviso
# sai 1x/dia por systemMessage (molde secret-guard.sh).
#
# Parse do .psd1 e' INTENCIONALMENTE simples (nao um parser PSD1 geral): o arquivo e' sempre
# gerado por tools/complementary-repos.ps1 (ConvertTo-ComplementaryRepoPsd1Text) no formato fixo
# `Path   = 'valor'` uma chave por linha — extraido via sed, sem depender de pwsh.

emit_decision() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r},systemMessage:$r}'
}

# Aviso unico (1x/dia, NUNCA bloqueia) quando falta jq. Molde secret-guard.sh: sai como systemMessage
# no STDOUT, porque stderr de hook com exit 0 vai so para o debug log (sonda com claude -p,
# 2026-09-12). JSON fixo por printf -- o jq e' justamente o que falta.
_sdd_ask_degraded() {
  local m="${TMPDIR:-/tmp}/.sdd-complementary-guard-degraded.$(date +%Y%m%d 2>/dev/null)"
  [ -e "$m" ] && return 0
  printf '%s\n' '{"systemMessage":"[sdd] aviso: jq ausente - complementary-repo-guard (.sh) INATIVO: escritas nos repos complementares registrados passam sem pedir confirmacao. Instale o jq para reativar."}'
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

# PURA: token de caminho -> absoluto normalizado (espelho de Resolve-CommandPathToken). $1 token,
# $2 base, $3 home. Imprime o caminho; retorno 1 quando nao resolve sem executar (variavel, vazio).
resolve_cmd_path() {
  local t="$1" base="$2" home="$3" c out="" lead=""
  t="$(printf '%s' "$t" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^[\"']*//" -e "s/[\"']*\$//")"
  [ -z "${t//[[:space:]]/}" ] && return 1
  case "$t" in *'$'*) return 1 ;; esac
  t="${t//\\//}"; base="${base//\\//}"
  if [ "$t" = "~" ] || [ "${t#\~/}" != "$t" ]; then
    [ -z "$home" ] && return 1
    home="${home//\\//}"; t="${home%/}${t#\~}"
  fi
  case "$base" in
    [a-zA-Z]:*)
      if printf '%s' "$t" | grep -qE '^/[a-zA-Z](/|$)'; then t="${t:1:1}:/${t:3}"
      # `/tmp` do Git Bash = %TEMP% (montagem usertemp); espelho do .ps1.
      elif printf '%s' "$t" | grep -qE '^/tmp(/|$)' && command -v cygpath >/dev/null 2>&1; then
        # -l: forma longa, igual ao GetTempPath do .ps1 (o TEMP do runner vem em nome curto, 8.3).
        t="$(cygpath -m -l /tmp 2>/dev/null)${t:4}"
      fi ;;
  esac
  case "$t" in
    [a-zA-Z]:/*|/*) ;;
    *) [ -z "$base" ] && return 1; t="${base%/}/$t" ;;
  esac
  [ "${t#/}" != "$t" ] && lead="/"
  local -a parts=() comps=()
  IFS='/' read -r -a comps <<< "$t"
  for c in "${comps[@]}"; do
    case "$c" in
      ''|.) ;;
      ..) if [ "${#parts[@]}" -gt 1 ] || { [ "${#parts[@]}" -eq 1 ] && [ "${parts[0]%:}" = "${parts[0]}" ]; }; then
            unset "parts[$((${#parts[@]} - 1))]"; parts=("${parts[@]}")
          fi ;;
      *) parts+=("$c") ;;
    esac
  done
  local IFS='/'; out="${parts[*]}"; unset IFS
  out="$lead$out"
  printf '%s' "$out" | grep -qE '^[a-zA-Z]:$' && out="$out/"
  printf '%s' "$out" | tr '[:upper:]' '[:lower:]'
}

# PURA: o comando escreve num path protegido? Espelho de Get-BashProtectedWrite. $1 comando, $2 cwd,
# $3 lista protegida (1 por linha), $4 home. Imprime o caminho atingido e retorna 0; senao 1.
# Heuristica de texto: segmentos (&& || ; | & quebra de linha), `cd`, redirecao (> e >>), comandos
# de escrita, `sed -i`/`perl -i` e git (com -C). Escrita por script (python -c) nao e' vista.
BASH_WRITE_PREFILTER='>|(^|[^a-z0-9_-])(tee|touch|mkdir|md|rm|rmdir|rd|del|erase|ln|chmod|chown|truncate|mv|move|ren|set-content|sc|add-content|ac|out-file|new-item|ni|remove-item|ri|move-item|mi|rename-item|rni|clear-content|clc|cp|copy|copy-item|cpi|rsync|install|scp|sed|perl|git)([^a-z0-9_-]|$)'
_cg_hit() {   # $1 token; usa cur_dir/home/protected do chamador
  local r; r="$(resolve_cmd_path "$1" "$cur_dir" "$home")" || return 1
  path_under_protected "$r" "$protected" || return 1
  printf '%s' "$r"
}
get_bash_protected_write() {
  local cmd="$1" cur_dir="$2" protected="$3" home="$4"
  [ -z "${cmd//[[:space:]]/}" ] && return 1
  [ -z "$protected" ] && return 1
  # Pre-filtro (so desempenho): espelho de $script:BashWritePrefilter do .ps1.
  printf '%s' "$cmd" | grep -qiE "$BASH_WRITE_PREFILTER" || return 1
  local q="'" nl=$'\n'
  local redir_re="[0-9]?>{1,2}[[:space:]]*(\"[^\"]*\"|${q}[^${q}]*${q}|[^[:space:];|&<>()]+)"
  local tok_re="\"[^\"]*\"|${q}[^${q}]*${q}|[^[:space:]]+"
  local text="${cmd//&&/$nl}"; text="${text//||/$nl}"; text="${text//[;|&$'\r']/$nl}"
  local seg r t i n c a k dest sub next git_dir
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^(*//' -e 's/)*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$seg" ] && continue
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      t="$(printf '%s' "$t" | sed -E 's/^[0-9]?>{1,2}[[:space:]]*//')"
      r="$(_cg_hit "$t")" && { printf '%s' "$r"; return 0; }
    done <<< "$(printf '%s' "$seg" | grep -oE "$redir_re")"
    seg="$(printf '%s' "$seg" | sed -E "s/$(printf '%s' "$redir_re" | sed 's:/:\\/:g')/ /g")"
    local -a toks=() argv=() pos=()
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      toks+=("$(printf '%s' "$t" | sed -e "s/^[\"']*//" -e "s/[\"']*\$//")")
    done <<< "$(printf '%s' "$seg" | grep -oE "$tok_re")"
    n="${#toks[@]}"; i=0
    while [ "$i" -lt "$n" ]; do
      if [[ "${toks[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
      case "${toks[$i]}" in sudo|command|builtin|exec|nohup|time) i=$((i + 1)); continue ;; esac
      break
    done
    [ "$i" -ge "$n" ] && continue
    c="$(printf '%s' "${toks[$i]##*/}" | tr '[:upper:]' '[:lower:]')"; c="${c%.exe}"
    for ((k = i + 1; k < n; k++)); do
      argv+=("${toks[$k]}")
      case "${toks[$k]}" in -*) ;; *) pos+=("${toks[$k]}") ;; esac
    done
    case "$c" in
      cd|pushd|set-location|sl|push-location)
        if [ "${#pos[@]}" -gt 0 ]; then r="$(resolve_cmd_path "${pos[0]}" "$cur_dir" "$home")" && cur_dir="$r"; fi
        continue ;;
      tee|touch|mkdir|md|rm|rmdir|rd|del|erase|ln|chmod|chown|truncate|mv|move|ren|set-content|sc|add-content|ac|out-file|new-item|ni|remove-item|ri|move-item|mi|rename-item|rni|clear-content|clc)
        for a in ${pos[@]+"${pos[@]}"}; do r="$(_cg_hit "$a")" && { printf '%s' "$r"; return 0; }; done
        continue ;;
      cp|copy|copy-item|cpi|rsync|install|scp)
        dest=""
        for ((k = 0; k < ${#argv[@]}; k++)); do
          a="${argv[$k]}"
          case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
            -destination|-dest) [ $((k + 1)) -lt "${#argv[@]}" ] && dest="${argv[$((k + 1))]}" ;;
            --target-directory=*) dest="${a#*=}" ;;
          esac
          [ "$a" = "-t" ] && [ $((k + 1)) -lt "${#argv[@]}" ] && dest="${argv[$((k + 1))]}"
        done
        [ -z "$dest" ] && [ "${#pos[@]}" -gt 0 ] && dest="${pos[$((${#pos[@]} - 1))]}"
        if [ -n "$dest" ]; then r="$(_cg_hit "$dest")" && { printf '%s' "$r"; return 0; }; fi
        continue ;;
      sed|perl)
        for a in ${argv[@]+"${argv[@]}"}; do
          if [[ "$a" =~ ^-[a-zA-Z]*i ]] || [[ "$a" =~ ^--in-place ]]; then
            for a in ${pos[@]+"${pos[@]}"}; do r="$(_cg_hit "$a")" && { printf '%s' "$r"; return 0; }; done
            break
          fi
        done
        continue ;;
      git)
        git_dir="$cur_dir"; sub=""
        for ((k = 0; k < ${#argv[@]}; k++)); do
          a="${argv[$k]}"
          case "$a" in
            -C|--work-tree|--git-dir)
              if [ $((k + 1)) -lt "${#argv[@]}" ]; then
                r="$(resolve_cmd_path "${argv[$((k + 1))]}" "$git_dir" "$home")" && git_dir="$r"
                k=$((k + 1)); continue
              fi ;;
            -c|--namespace|--config-env) k=$((k + 1)); continue ;;
          esac
          case "$a" in -*) continue ;; esac
          sub="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"; break
        done
        # `stash list`/`stash show` so leem; o resto mexe na arvore.
        if [ "$sub" = "stash" ]; then
          next=""
          for ((k = k + 1; k < ${#argv[@]}; k++)); do case "${argv[$k]}" in -*) ;; *) next="${argv[$k]}"; break ;; esac; done
          case "$next" in list|show) sub="" ;; *) sub="stash-write" ;; esac
        fi
        case "$sub" in
          add|am|apply|checkout|cherry-pick|clean|commit|merge|mv|pull|push|rebase|reset|restore|revert|rm|switch|worktree|stash-write)
            r="$(resolve_cmd_path "." "$git_dir" "$home")" && path_under_protected "$r" "$protected" && { printf '%s' "$r"; return 0; } ;;
        esac
        continue ;;
    esac
  done <<< "$text"
  return 1
}

main() {
  command -v jq >/dev/null 2>&1 || { _sdd_ask_degraded; exit 0; }

  local raw; raw="$(cat)" || exit 0
  [ -z "${raw//[[:space:]]/}" ] && exit 0

  local tool file_path command cwd shell=0
  tool="$(printf '%s' "$raw" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
  # Bash/PowerShell (2026-10-17): `permissions.ask Edit(...)` nao alcanca escrita via shell (medido).
  case "$tool" in Write|Edit) ;; Bash|PowerShell) shell=1 ;; *) exit 0 ;; esac

  if [ "$shell" = 1 ]; then
    command="$(printf '%s' "$raw" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -z "${command//[[:space:]]/}" ] && exit 0
  else
    file_path="$(printf '%s' "$raw" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    [ -z "${file_path//[[:space:]]/}" ] && exit 0
  fi

  cwd="$(printf '%s' "$raw" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -z "$cwd" ] && cwd="$(pwd)"

  # O registro mora na raiz do projeto; depois de um `cd` para dentro do repo complementar (o cwd do
  # shell persiste), a raiz so se acha pelo CLAUDE_PROJECT_DIR. Espelho do .ps1.
  local root="$cwd"
  [ ! -f "$root/.claude/complementary-repos.psd1" ] && [ -n "${CLAUDE_PROJECT_DIR-}" ] && root="$CLAUDE_PROJECT_DIR"
  local registry_path="$root/.claude/complementary-repos.psd1"
  [ -f "$registry_path" ] || exit 0   # nada registrado -> passthrough

  # Registro presente: monta a lista de paths protegidos (cache root + Path de cada entrada).
  # NAO usa `cd ... && pwd` para "resolver": no Git Bash/MSYS isso reescreve um path Windows
  # (C:\...) para a forma POSIX do mount (/c/... ou /tmp/...), que nao bate mais, em string, com
  # o file_path recebido do payload (sempre no estilo do host, Windows). Fica no MESMO espaco de
  # path do payload — normalize_path (barra+minusculo) ja basta para a comparacao de prefixo.
  local cache_root="$root/.claude/.cache/complementary-repos"
  local protected="$cache_root"
  local paths; paths="$(extract_registered_paths "$registry_path")"
  if [ -n "$paths" ]; then
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ -d "$p" ] && protected="$protected"$'\n'"$p"
    done <<< "$paths"
  fi

  if [ "$shell" = 1 ]; then
    local alvo
    if alvo="$(get_bash_protected_write "$command" "$cwd" "$protected" "${HOME-}")"; then
      emit_decision "O comando escreve em '$alvo', que pertence a um repositorio complementar registrado (leitura-only). Confirme que quer mesmo escrever fora do projeto atual."
    fi
    exit 0
  fi

  local target; target="$(normalize_path "$file_path")"
  if path_under_protected "$target" "$protected"; then
    emit_decision "O caminho '$file_path' pertence a um repositorio complementar registrado (leitura-only). Confirme que quer mesmo escrever fora do projeto atual."
    exit 0
  fi
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
