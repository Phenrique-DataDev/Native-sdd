#!/usr/bin/env bash
# Fonte UNICA (shell) dos detectores destrutivos — espelho fiel de lib/destructive-patterns.ps1 (J5).
#
# So define funcoes (sem efeitos colaterais ao sourced; sem prompts, sem I/O, sem git/rede).
# Postura ask (educar, nao barrar): na duvida, pass. Paridade .ps1==.sh por destructive-guard.Tests.ps1.

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

# PURA: o alvo e' "arriscado"? (absoluto/home/var/glob). Espelha Test-IsRiskyTarget.
is_risky_target() {
  local t="${1-}"
  t="${t#[\"\']}"; t="${t%[\"\']}"
  [ -z "$t" ] && return 1
  case "$t" in
    *'$'*)   return 0 ;;   # var nao-expandida
    '~'*)    return 0 ;;   # home
    /*)      return 0 ;;   # absoluto
    '*'*)    return 0 ;;   # glob amplo (comeca com *)
    '.*')    return 0 ;;   # glob .*
    '..')    return 0 ;;   # pai direto (rm -rf ..) — J6
    '../'*)  return 0 ;;   # sobe da cwd (../x) — J6
    */../*)  return 0 ;;   # /../ no meio do path — J6
  esac
  return 1               # relativo-sob-cwd: ./build, build, node_modules, dist
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

# PURA: comando -> decisao. Echoa o motivo (stdout) e retorna 0 p/ ASK, 1 p/ pass. Espelha Get-DestructiveDecision.
get_destructive_decision() {
  local cmd="${1-}" seg t names
  local -          # localiza as opcoes de shell (restauradas no return)
  set -f           # noglob: impede que `*` nos loops `for tok in $seg` expanda p/ arquivos do cwd
  [ -z "${cmd//[[:space:]]/}" ] && return 1
  if is_download_to_shell "$cmd"; then
    printf '%s' 'Download de script executado direto no shell (curl/wget | sh). Confirmacao exigida.'
    return 0
  fi
  while IFS= read -r seg; do
    if is_destructive_rm "$seg"; then
      names=""
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        if is_risky_target "$t"; then
          names="${names:+$names, }$t"
        fi
      done <<< "$(rm_targets "$seg")"
      if [ -n "$names" ]; then
        printf 'Comando destrutivo (rm recursivo de alvo arriscado): %s. Confirmacao exigida.' "$names"
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
  done <<< "$(split_command_segment "$cmd")"
  return 1
}
