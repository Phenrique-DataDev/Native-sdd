#!/usr/bin/env bash
# Fonte UNICA (shell) dos detectores destrutivos — espelho fiel de lib/destructive-patterns.ps1 (J5).
#
# So define funcoes (sem efeitos colaterais ao sourced; sem prompts, sem I/O, sem git/rede).
# Postura ask (educar, nao barrar): na duvida, pass. Paridade .ps1==.sh por destructive-guard.Tests.ps1;
# sob userland BSD (macOS) por tools/tests/secret-guard-sh.Tests.ps1.
#
# PORTABILIDADE (macOS: bash 3.2): nada de `local -` (bash >= 4.4). O sed e o grep BSD do macOS 15
# segmentam por `\n` e aceitam `\b` em -E como o GNU (medido no runner macos-15, 2026-09-10).

# PURA: divide o comando em segmentos por separadores de shell (1 por linha). Espelha Split-CommandSegment.
split_command_segment() {
  printf '%s' "${1-}" | tr -d '\r' | sed -E 's/&&|\|\||;|\|/\n/g'
}

# PURA: o segmento e' um `rm` recursivo E force? Espelha Test-IsDestructiveRm.
is_destructive_rm() {
  local seg="${1-}" tok has_rec=0 has_force=0
  [ -z "${seg//[[:space:]]/}" ] && return 1
  printf '%s' "$seg" | grep -qE '(^|[[:space:]])(sudo[[:space:]]+)?rm([[:space:]]|$)' || return 1
  for tok in $seg; do
    case "$tok" in
      --recursive) has_rec=1 ;;
      --force) has_force=1 ;;
      -[A-Za-z]*)
        case "$tok" in *[rR]*) has_rec=1 ;; esac
        case "$tok" in *f*) has_force=1 ;; esac
        ;;
    esac
  done
  [ "$has_rec" -eq 1 ] && [ "$has_force" -eq 1 ]
}

# PURA: alvos (tokens nao-flag) de um segmento `rm`, 1 por linha. Espelha Get-RmTarget.
rm_targets() {
  local seg="${1-}" tok seen=0
  for tok in $seg; do
    if [ "$seen" -eq 0 ]; then
      [ "$tok" = "rm" ] && seen=1
      continue
    fi
    case "$tok" in -*) continue ;; esac
    printf '%s\n' "$tok"
  done
}

# --- GUARD_RM_ESCOPO: contexto por parametro (cwd/temp/home/TEMP-TMP-TMPDIR), lib continua pura ---
# Os globais abaixo sao o "parametro" (bash 3.2 nao tem array associativo nem passa estrutura):
# _destructive_decision os preenche a partir dos argumentos; ninguem mais escreve neles.
#   GUARD_ROOTS    raizes seguras normalizadas, 1 por linha (guard_safe_roots)
#   GUARD_VARS     NOME<TAB>valor, 1 por linha; valor \001 = conhecido como NAO resolvivel
#   GUARD_ENVVARS  NOME<TAB>valor de TEMP/TMP/TMPDIR do env do HOOK
#   GUARD_POISON   nomes envenenados, 1 por linha; '*' = nada se resolve
GUARD_TAB="$(printf '\t')"
GUARD_UNK="$(printf '\001')"
GUARD_NL='
'

# Maiuscula de UMA letra, sem subshell (fork e' caro no MSYS). Resultado em _GU.
# Sem faixa `[a-z]`: no bash 3.2 ela segue a colacao do locale e pode casar maiuscula.
GUARD_LC=abcdefghijklmnopqrstuvwxyz
GUARD_UC=ABCDEFGHIJKLMNOPQRSTUVWXYZ
_guard_upper1() {
  local pre
  case "$GUARD_LC" in
    *"$1"*) pre="${GUARD_LC%%"$1"*}"; _GU="${GUARD_UC:${#pre}:1}" ;;
    *) _GU="$1" ;;
  esac
}

# Minuscula da string inteira, sem fork (`tr` custa um processo por chamada no MSYS). Em _GL.
_guard_lower() {
  local s="${1-}" out="" c pre
  while [ -n "$s" ]; do
    c="${s:0:1}"; s="${s:1}"
    case "$GUARD_UC" in *"$c"*) pre="${GUARD_UC%%"$c"*}"; c="${GUARD_LC:${#pre}:1}" ;; esac
    out="$out$c"
  done
  _GL="$out"
}

# PURA: normaliza caminho (D7). Espelha ConvertTo-GuardPath. Resultado em _GP.
guard_norm_path() {
  local p="${1-}" re_msys='^/([A-Za-z])(/|$)' re_drv='^([a-z]):'
  p="${p//\"/}"; p="${p//\'/}"; p="${p//\\//}"
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  if [[ $p =~ $re_msys ]]; then _guard_upper1 "${BASH_REMATCH[1]}"; p="$_GU:${p:2}"; fi
  if [[ $p =~ $re_drv ]]; then _guard_upper1 "${BASH_REMATCH[1]}"; p="$_GU${p:1}"; fi
  while [[ $p == *//* ]]; do p="${p//\/\//\/}"; done
  case "$p" in [A-Z]:) p="$p/" ;; esac
  if [ "${#p}" -gt 1 ]; then
    case "$p" in
      [A-Z]:/) ;;
      */) while [ "${#p}" -gt 1 ] && [[ $p == */ ]] && [[ ! $p =~ ^[A-Z]:/$ ]]; do p="${p%/}"; done ;;
    esac
  fi
  _GP="$p"
}

# PURA: chave de comparacao (drive Windows sem caixa). Espelha Get-GuardPathKey. Resultado em _GK.
guard_path_key() {
  case "${1-}" in
    [A-Za-z]:*) _guard_lower "$1"; _GK="$_GL" ;;
    *) _GK="${1-}" ;;
  esac
}

# PURA: raizes seguras (D8). $1=cwd $2=home $3..=temps. Espelha Get-SafeRoot. Preenche GUARD_ROOTS.
guard_safe_roots() {
  local cwd="${1-}" home="${2-}" c r k hk=""
  shift 2 2>/dev/null || shift $#
  GUARD_ROOTS=""
  if [ -n "$home" ]; then guard_norm_path "$home"; guard_path_key "$_GP"; hk="$_GK"; fi
  for c in "$cwd" "$@"; do
    [ -n "${c//[[:space:]]/}" ] || continue
    guard_norm_path "$c"; r="$_GP"
    case "$r" in /*|[A-Z]:/*) ;; *) continue ;; esac
    case "$r" in /|[A-Z]:/) continue ;; esac
    [[ $r =~ (^|/)\.\.(/|$) ]] && continue
    guard_path_key "$r"; k="$_GK"
    if [ -n "$hk" ]; then
      [ "$k" = "$hk" ] && continue
      case "$hk" in "$k"/*) continue ;; esac
    fi
    GUARD_ROOTS="${GUARD_ROOTS}${r}${GUARD_NL}"
  done
}

# Calcula GUARD_ROOTS na 1a vez que um alvo absoluto aparece (o comum e' nao aparecer).
_guard_ensure_roots() {
  [ "${GUARD_ROOTS_READY-0}" -eq 1 ] && return 0
  local IFS="$GUARD_NL"
  # shellcheck disable=SC2086  # a lista de temps e' separada por linha de proposito
  guard_safe_roots "${GUARD_CTX_CWD-}" "${GUARD_CTX_HOME-}" ${GUARD_CTX_TEMPS-}
  GUARD_ROOTS_READY=1
}

# PURA: descendente ESTRITO de alguma raiz de GUARD_ROOTS? Espelha Test-IsUnderSafeRoot.
guard_under_root() {
  local p="${1-}" k r rk
  [ -n "$p" ] && [ -n "$GUARD_ROOTS" ] || return 1
  guard_path_key "$p"; k="$_GK"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    guard_path_key "$r"; rk="$_GK"
    case "$k" in "$rk"/*) return 0 ;; esac
  done <<< "$GUARD_ROOTS"
  return 1
}

# PURA: o alvo (ja expandido) e' "arriscado"? Espelha Test-IsRiskyTarget (usa GUARD_ROOTS).
is_risky_target() {
  local t="${1-}" n u re_up='/\.\.(/|$)'
  t="${t//\"/}"; t="${t//\'/}"
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
  [ -z "$t" ] && return 1
  case "$t" in
    *'$'*) return 0 ;;   # var nao resolvida
    '~'*)  return 0 ;;   # home
  esac
  u="${t//\\//}"
  case "$u" in
    ..|../*) return 0 ;;                 # sobe da cwd — J6
  esac
  [[ $u =~ $re_up ]] && return 0         # /../ ou /.. no fim — ANTES da raiz (D10)
  case "$t" in
    '*'*) return 0 ;;    # glob amplo
    '.*') return 0 ;;    # glob .*
  esac
  case "$u" in
    /*|[A-Za-z]:*)
      guard_norm_path "$t"; n="$_GP"   # copia: _guard_ensure_roots reescreve _GP
      case "$n" in *'*'*|*'?'*|*'['*) return 0 ;; esac
      _guard_ensure_roots
      guard_under_root "$n" && return 1
      return 0 ;;
  esac
  return 1               # relativo-sob-cwd: ./build, build, node_modules, dist
}

# PURA: `$(mktemp -d)` / `$(mktemp -d -t NOME)` exatos (D6). Espelha Test-IsMktempTemp.
guard_is_mktemp() {
  local v="${1-}" re='^\$\(mktemp -d( -t [A-Za-z0-9._-]+)?\)$'
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; esac
  [[ $v =~ $re ]]
}

# PURA: segmento e' UMA atribuicao limpa? (D4) Seta ASG_NAME/ASG_RAW. Espelha Get-LiteralAssignment.
guard_literal_assignment() {
  local seg="${1-}" re='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$' raw q=0
  [[ $seg =~ $re ]] || return 1
  ASG_NAME="${BASH_REMATCH[2]}"; raw="${BASH_REMATCH[3]}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  case "$raw" in
    \"*\") [[ ${raw:1:${#raw}-2} == *\"* ]] || q=1 ;;
    \'*\') [[ ${raw:1:${#raw}-2} == *\'* ]] || q=1 ;;
  esac
  [ "${#raw}" -lt 2 ] && q=0
  if [ "$q" -eq 0 ]; then
    if [[ $raw == *[[:space:]]* ]] && ! guard_is_mktemp "$raw"; then return 1; fi
    case "$raw" in *\"*|*\'*) return 1 ;; esac
  fi
  ASG_RAW="$raw"
  return 0
}

# PURA: marca corpo de heredoc com '#HD '. Espelha ConvertTo-GuardAnalysisText. Resultado em _GA.
guard_analysis_text() {
  local cmd="${1-}" line tag="" out="" re='(^|[^<])<<-?[[:space:]]*(["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)'
  case "$cmd" in *'<<'*) ;; *) _GA="$cmd"; return 0 ;; esac
  cmd="${cmd//$'\r'/}"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$tag" ]; then
      out="${out}#HD ${line}${GUARD_NL}"
      local tl="${line#"${line%%[![:space:]]*}"}"; tl="${tl%"${tl##*[![:space:]]}"}"
      [ "$tl" = "$tag" ] && tag=""
      continue
    fi
    out="${out}${line}${GUARD_NL}"
    if [[ $line =~ $re ]]; then
      # a aspa de abertura precisa fechar igual (o \1 do .ps1)
      tag="${BASH_REMATCH[3]}"
      if [ -n "${BASH_REMATCH[2]}" ]; then
        case "$line" in *"<<"*"${BASH_REMATCH[2]}${tag}${BASH_REMATCH[2]}"*) ;; *) tag="" ;; esac
      fi
    fi
  done <<< "$cmd"
  _GA="${out%$GUARD_NL}"
}

# PURA: nomes envenenados (o guard nao acompanha a redefinicao). Espelha Get-GuardPoisonedName.
# Preenche GUARD_POISON. Recebe o texto ja marcado por guard_analysis_text.
guard_poisoned_names() {
  local cmd="${1-}" seg line qs="" ch i in_s=0 in_d=0 rest=""
  GUARD_POISON=""
  [ -z "$cmd" ] && return 0
  if printf '%s' "$cmd" | grep -qiE '(^|[[:space:];&|(])(eval|source)[[:space:]]' \
     || printf '%s\n' "$cmd" | grep -qE '(^|[;&|(])[[:space:]]*\.[[:space:]]+[^[:space:]]'; then
    GUARD_POISON='*'; return 0
  fi
  # aspas atravessando linha fora de heredoc: so as aspas e as quebras importam (1 fork: tr)
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '#HD '*) continue ;; esac
    qs="${qs}${line}${GUARD_NL}"
  done <<< "$cmd"
  qs="$(printf '%s' "$qs" | tr -cd "\"'\n")"
  i=0
  while [ "$i" -lt "${#qs}" ]; do
    ch="${qs:$i:1}"
    if [ "$ch" = "'" ] && [ "$in_d" -eq 0 ]; then in_s=$((1 - in_s))
    elif [ "$ch" = '"' ] && [ "$in_s" -eq 0 ]; then in_d=$((1 - in_d))
    elif [ "$ch" = "$GUARD_NL" ] && { [ "$in_s" -eq 1 ] || [ "$in_d" -eq 1 ]; }; then GUARD_POISON='*'; return 0
    fi
    i=$((i + 1))
  done
  # segmentos que NAO sao atribuicao limpa
  while IFS= read -r seg; do
    guard_literal_assignment "$seg" && continue
    rest="${rest}${seg}${GUARD_NL}"
  done <<< "$(split_command_segment "$cmd")"
  GUARD_POISON="$(
    {
      printf '%s' "$cmd" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?=' | sed -E 's/^\$\{//; s/:?=$//'
      printf '%s' "$rest" | grep -oE '(^|[^A-Za-z0-9_$])[A-Za-z_][A-Za-z0-9_]*\+?=' | sed -E 's/^[^A-Za-z_]//; s/\+?=$//'
      printf '%s' "$rest" | grep -oE '(^|[^A-Za-z0-9_])(for|select)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | sed -E 's/.*[[:space:]]//'
      printf '%s' "$rest" | grep -oE '(^|[^A-Za-z0-9_])(read|mapfile|readarray|getopts|declare|local|typeset|readonly|export|unset)([^A-Za-z0-9_].*)?$' \
        | sed -E 's/^[^A-Za-z0-9_]?(read|mapfile|readarray|getopts|declare|local|typeset|readonly|export|unset)//' | grep -oE '[A-Za-z_][A-Za-z0-9_]*'
    } 2>/dev/null
  )${GUARD_NL}"
}

# consulta em lista NOME<TAB>valor. Seta _GV; retorna 0 achou, 1 nao achou.
_guard_lookup() {
  local name="$1" list="$2" l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "${l%%"$GUARD_TAB"*}" = "$name" ]; then _GV="${l#*"$GUARD_TAB"}"; return 0; fi
  done <<< "$list"
  return 1
}

_guard_is_poisoned() {
  case "$GUARD_NL$GUARD_POISON" in *"$GUARD_NL$1$GUARD_NL"*) return 0 ;; esac
  return 1
}

# PURA: troca $X/${X} pelo valor conhecido (D3/D5). Espelha Expand-GuardVariable. Resultado em _GE.
guard_expand() {
  local rest="${1-}" out="" m name pre rep re='\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)'
  if [[ $rest != *'$'* ]] || [ "$GUARD_POISON" = '*' ]; then _GE="$rest"; return 0; fi
  while [[ $rest =~ $re ]]; do
    m="${BASH_REMATCH[0]}"; name="${BASH_REMATCH[1]}"; name="${name#\{}"; name="${name%\}}"
    pre="${rest%%"$m"*}"
    rep="$m"
    if ! _guard_is_poisoned "$name"; then
      if _guard_lookup "$name" "$GUARD_VARS"; then
        [ "$_GV" != "$GUARD_UNK" ] && rep="$_GV"
      elif _guard_lookup "$name" "$GUARD_ENVVARS" && [ -n "$_GV" ]; then
        rep="$_GV"
      fi
    fi
    out="${out}${pre}${rep}"
    rest="${rest#*"$m"}"
  done
  _GE="${out}${rest}"
}

_guard_set_var() {
  local name="$1" val="$2" l new=""
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    [ "${l%%"$GUARD_TAB"*}" = "$name" ] && continue
    new="${new}${l}${GUARD_NL}"
  done <<< "$GUARD_VARS"
  GUARD_VARS="${new}${name}${GUARD_TAB}${val}${GUARD_NL}"
}

# PURA: o segmento e' um `git` que apaga trabalho nao-commitado (working-tree/stash)? Espelha Test-IsDestructiveGit (J6).
is_destructive_git() {
  local seg="${1-}" tok sub="" stage=0
  local has_force=0 has_dry=0 has_staged=0 has_worktree=0 has_ddash=0 has_dot=0 stash_first=""
  printf '%s' "$seg" | grep -qE '(^|[[:space:]])(sudo[[:space:]]+)?git([[:space:]]|$)' || return 1
  for tok in $seg; do
    case "$stage" in
      0) [ "$tok" = "git" ] && stage=1 ;;
      1) case "$tok" in -*) : ;; *) sub="$tok"; stage=2 ;; esac ;;   # flags globais ignoradas
      2)
        case "$tok" in
          --force)        has_force=1 ;;
          --dry-run)      has_dry=1 ;;
          --staged|-S)    has_staged=1 ;;
          --worktree|-W)  has_worktree=1 ;;
          --)             has_ddash=1 ;;
          .)              has_dot=1 ;;
          -[A-Za-z]*)
            case "$tok" in *f*) has_force=1 ;; esac
            case "$tok" in *n*) has_dry=1 ;; esac
            ;;
        esac
        if [ -z "$stash_first" ]; then
          case "$tok" in -*) : ;; *) stash_first="$tok" ;; esac
        fi
        ;;
    esac
  done
  [ -n "$sub" ] || return 1
  case "$sub" in
    clean)    [ "$has_force" -eq 1 ] && [ "$has_dry" -eq 0 ] && return 0 ;;
    restore)  { [ "$has_staged" -eq 0 ] || [ "$has_worktree" -eq 1 ]; } && return 0 ;;
    checkout) { [ "$has_ddash" -eq 1 ] || [ "$has_dot" -eq 1 ]; } && return 0 ;;
    stash)    { [ "$stash_first" = "drop" ] || [ "$stash_first" = "clear" ]; } && return 0 ;;
  esac
  return 1
}

# PURA: o segmento e' um `chmod` recursivo com modo perigoso? Espelha Test-IsRiskyChmod.
is_risky_chmod() {
  local seg="${1-}" tok has_rec=0 has_mode=0
  printf '%s' "$seg" | grep -qE '(^|[[:space:]])(sudo[[:space:]]+)?chmod([[:space:]]|$)' || return 1
  for tok in $seg; do
    case "$tok" in
      --recursive) has_rec=1 ;;
      -*R*) has_rec=1 ;;
    esac
    case "$tok" in
      777|666|000|a+rwx) has_mode=1 ;;
    esac
  done
  [ "$has_rec" -eq 1 ] && [ "$has_mode" -eq 1 ]
}

# PURA: o comando baixa um script e o executa direto no shell? Espelha Test-IsDownloadToShell.
is_download_to_shell() {
  printf '%s' "${1-}" | grep -qiE '\b(curl|wget|fetch)\b[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|ksh|dash|pwsh|powershell|python[0-9.]*|perl|ruby|node)\b'
}

# PURA: o segmento e' um `Remove-Item` recursivo do PowerShell? Espelha Test-IsDestructiveRemoveItem.
# Case globs em vez de `tr` para minuscula: fork por segmento e' caro no MSYS.
is_destructive_remove_item() {
  local seg="${1-}" kind tok
  [ -z "${seg//[[:space:]]/}" ] && return 1
  # shellcheck disable=SC2086  # word splitting e' a tokenizacao (noglob ligado pela decisao)
  set -- $seg
  [ $# -ge 2 ] || return 1
  case "$1" in
    [Rr][Ee][Mm][Oo][Vv][Ee]-[Ii][Tt][Ee][Mm]|[Rr][Ii]|[Dd][Ee][Ll]|[Ee][Rr][Aa][Ss][Ee]|[Rr][Dd]|[Rr][Mm][Dd][Ii][Rr]) kind=ps ;;
    [Rr][Mm]) kind=rm ;;
    *) return 1 ;;
  esac
  shift
  for tok in "$@"; do
    case "$tok" in *:\$[Tt][Rr][Uu][Ee]) tok="${tok%:*}" ;; esac
    case "$tok" in
      -[Rr][Ee][Cc]|-[Rr][Ee][Cc][Uu]|-[Rr][Ee][Cc][Uu][Rr]|-[Rr][Ee][Cc][Uu][Rr][Ss]|-[Rr][Ee][Cc][Uu][Rr][Ss][Ee]) return 0 ;;
      -[Rr]|-[Rr][Ee]) [ "$kind" = ps ] && return 0 ;;
    esac
  done
  return 1
}

# PURA: alvos de um `Remove-Item`, 1 por linha (virgula abre a lista). Espelha Get-RemoveItemTarget.
remove_item_targets() {
  local seg="${1-}" tok skip=0
  # shellcheck disable=SC2086
  set -- $seg
  shift
  for tok in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$tok" in
      -[Ff][Ii][Ll]*|-[Ii][Nn][Cc]*|-[Ee][Xx][Cc]*|-[Cc][Rr]*|-[Ss][Tt]*) skip=1; continue ;;
      -*) continue ;;
    esac
    printf '%s\n' "${tok//,/$GUARD_NL}"
  done
}

# PURA: download executado pelo PowerShell (`iwr … | iex`, `iex (irm …)`)? Espelha Test-IsPowerShellDownloadExec.
is_powershell_download_exec() {
  printf '%s' "${1-}" | grep -qiE '\b(iex|invoke-expression)\b' || return 1
  printf '%s' "${1-}" | grep -qiE '\b(iwr|irm|invoke-webrequest|invoke-restmethod|downloadstring|curl|wget)\b'
}

# PURA: comando -> decisao. Echoa o motivo (stdout) e retorna 0 p/ ASK, 1 p/ pass. Espelha Get-DestructiveDecision.
# Contexto OPCIONAL (GUARD_RM_ESCOPO, D1): $2=cwd $3=home $4=TEMP/TMP/TMPDIR do hook (NOME<TAB>valor
# por linha) $5..=temps. Sem contexto, nenhuma raiz segura: todo absoluto e' `ask`.
# noglob so' durante a decisao: impede que `*` nos loops `for tok in $seg` expanda p/ arquivos do cwd.
# Salva/restaura na mao — `local -` e' bash >= 4.4, e o macOS traz 3.2.
get_destructive_decision() {
  local had_noglob=0 rc
  case $- in *f*) had_noglob=1 ;; esac
  set -f
  _destructive_decision "$@"; rc=$?
  [ "$had_noglob" -eq 1 ] || set +f
  return "$rc"
}

_destructive_decision() {
  local cmd="${1-}" cwd="${2-}" home="${3-}" envvars="${4-}" seg t r names v raw analise temp0="" need=0
  local re_rm='(^|[[:space:]])rm([[:space:]]|$)'
  [ -z "${cmd//[[:space:]]/}" ] && return 1
  if is_download_to_shell "$cmd"; then
    printf '%s' 'Download de script executado direto no shell (curl/wget | sh). Confirmacao exigida.'
    return 0
  fi
  if is_powershell_download_exec "$cmd"; then
    printf '%s' 'Download de script executado direto no PowerShell (iwr/irm | iex). Confirmacao exigida.'
    return 0
  fi
  shift 4 2>/dev/null || shift $#
  [ $# -gt 0 ] && temp0="${1-}"
  GUARD_CTX_CWD="$cwd"; GUARD_CTX_HOME="$home"; GUARD_CTX_TEMPS=""
  for t in "$@"; do GUARD_CTX_TEMPS="${GUARD_CTX_TEMPS}${t}${GUARD_NL}"; done
  GUARD_ROOTS=""; GUARD_ROOTS_READY=0
  GUARD_ENVVARS=""
  while IFS= read -r t; do
    case "${t%%"$GUARD_TAB"*}" in TEMP|TMP|TMPDIR) [ -n "${t#*"$GUARD_TAB"}" ] && GUARD_ENVVARS="${GUARD_ENVVARS}${t}${GUARD_NL}" ;; esac
  done <<< "$envvars"
  GUARD_VARS=""; GUARD_POISON=""; analise="$cmd"
  # Variavel so importa para alvo de `rm`: sem `$` ou sem `rm`, nada disso muda a decisao (e o
  # heredoc marcado nao muda a deteccao de rm/git/chmod) -- pula o trabalho caro.
  if [[ $cmd == *'$'* ]] && [[ $cmd =~ $re_rm ]]; then
    need=1
    guard_analysis_text "$cmd"; analise="$_GA"
    guard_poisoned_names "$analise"
  fi
  while IFS= read -r seg; do
    # Atribuicao limpa ANTES do rm: registra o valor (a ultima vence — D4/D5).
    if [ "$need" -eq 1 ] && guard_literal_assignment "$seg"; then
      v="$GUARD_UNK"
      if guard_is_mktemp "$ASG_RAW"; then
        if [ -n "$temp0" ]; then guard_norm_path "$temp0"; v="$_GP/mktemp.XXXXXX"; fi
      else
        raw="$ASG_RAW"
        case "$raw" in
          \"*\") raw="${raw#\"}"; raw="${raw%\"}"; guard_expand "$raw"; raw="$_GE" ;;
          \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
          *) guard_expand "$raw"; raw="$_GE" ;;
        esac
        case "$raw" in *'$'*|*'`'*|*'('*) ;; *) v="$raw" ;; esac
      fi
      _guard_set_var "$ASG_NAME" "$v"
      continue
    fi
    if is_destructive_rm "$seg"; then
      names=""
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        guard_expand "$t"; r="$_GE"
        if is_risky_target "$r"; then
          # D11: mostra o que sera apagado de fato quando houve substituicao.
          if [ "$r" != "$t" ]; then t="$t (= $r)"; fi
          names="${names:+$names, }$t"
        fi
      done <<< "$(rm_targets "$seg")"
      if [ -n "$names" ]; then
        printf 'Comando destrutivo (rm recursivo de alvo arriscado): %s. Confirmacao exigida.' "$names"
        return 0
      fi
    fi
    if is_destructive_remove_item "$seg"; then
      names=""
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        is_risky_target "$t" && names="${names:+$names, }$t"
      done <<< "$(remove_item_targets "$seg")"
      if [ -n "$names" ]; then
        printf 'Comando destrutivo (Remove-Item recursivo de alvo arriscado): %s. Confirmacao exigida.' "$names"
        return 0
      fi
    fi
    if is_risky_chmod "$seg"; then
      printf '%s' 'Permissao recursiva perigosa (chmod -R 777/666/000). Confirmacao exigida.'
      return 0
    fi
    if is_destructive_git "$seg"; then
      printf '%s' 'Git destrutivo de working-tree/stash (clean -f / restore / checkout -- / stash drop). Confirmacao exigida.'
      return 0
    fi
  done <<< "$(split_command_segment "$analise")"
  return 1
}
