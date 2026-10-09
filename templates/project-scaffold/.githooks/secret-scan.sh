#!/usr/bin/env bash
# secret-scan.sh — par POSIX de secret-scan.ps1: bloqueia (exit 1) o commit se houver segredo no que
# esta STAGED. O shim .githooks/pre-commit o chama quando NAO ha PowerShell no PATH.
#
# Por que existe: ate a 0.10.44 o pre-commit sem PowerShell saia 0 ("varredura de segredos PULADA") e
# o commit com token entrava no historico. Medido num Mac real (2026-09-10) sob o PATH que um app
# aberto pelo Dock recebe — /usr/bin:/bin:/usr/sbin:/sbin, sem o /usr/local/bin onde fica o pwsh.
#
# Mesma decisao do .ps1, mesma deteccao: a secret-patterns.sh desta pasta e' copia IDENTICA da lib
# canonica (templates/global-claude/hooks/lib/ — anti-drift em onboarding/tests/secret-patterns.Tests.ps1).
#   - arquivo staged cujo PATH e' de segredo (.env, *.pem, id_rsa, secrets/…)  -> bloqueia
#   - segredo de ALTA confianca nas linhas adicionadas do diff staged          -> bloqueia
#
# Fail-safe ASSIMETRICO, como o .ps1 sob ErrorActionPreference=Stop: nao conseguir VERIFICAR (git
# falhou, `grep -E` quebrado, motor de regex com erro) BLOQUEIA — nunca vira "nenhum segredo".
# Lib ausente segue a degradacao declarada do .ps1: avisa e nao bloqueia.
#
# Portavel para o bash 3.2 do macOS e userland BSD (so' ERE). Bypass consciente: git commit --no-verify

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A lib: a copia vendorizada (padrao) ou a do onboarding (fallback) — mesma ordem do .ps1.
for _lib in "$HERE/secret-patterns.sh" "${HOME:-/nonexistent}/.claude/hooks/lib/secret-patterns.sh"; do
  # shellcheck source=/dev/null
  if [ -f "$_lib" ]; then . "$_lib"; break; fi
done
unset _lib

# Avaliacao: 1 problema por linha no stdout; NAO decide o exit (o teste chama esta funcao direto).
# rc: 0 = varreu (com ou sem achado) · 2 = nao conseguiu verificar.
secret_scan_problems() {
  printf 'x\n' | grep -qE 'x' 2>/dev/null || return 2
  local files diff added names f
  files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)" || return 2
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_secret_file_path "$f"; then printf 'arquivo de segredo no commit: %s\n' "$f"; fi
  done <<< "$files"
  diff="$(git diff --cached --unified=0 2>/dev/null)" || return 2
  added="$(printf '%s\n' "$diff" | grep '^+' | grep -v '^+++' | sed 's/^+//')"
  names="$(find_secret_match "$added")" || return 2
  if [ -n "$names" ]; then printf '%s\n' "$names" | sort -u | sed 's/$/ detectado/'; fi
  return 0
}

main() {
  if ! command -v find_secret_match >/dev/null 2>&1 || ! command -v is_secret_file_path >/dev/null 2>&1; then
    printf '%s\n' '[pre-commit] lib de deteccao de segredos nao encontrada — varredura PULADA.' >&2
    printf '%s\n' '             (instale o onboarding ou copie secret-patterns.sh para .githooks/)' >&2
    exit 0
  fi

  local problems rc l
  problems="$(secret_scan_problems)"; rc=$?

  if [ "$rc" -ne 0 ]; then
    {
      printf '\n  COMMIT BLOQUEADO — nao foi possivel verificar segredos no que esta staged\n'
      printf '    (git ou `grep -E` falhou; na duvida, o hook nao libera).\n\n'
      printf '  Se voce conferiu o diff e ele esta limpo:\n'
      printf '    git commit --no-verify   (pula a verificacao conscientemente)\n\n'
    } >&2
    exit 1
  fi

  [ -z "$problems" ] && exit 0

  {
    printf '\n  COMMIT BLOQUEADO — possivel segredo no que esta staged:\n'
    while IFS= read -r l; do
      if [ -n "$l" ]; then printf '    - %s\n' "$l"; fi
    done <<< "$problems"
    printf '\n  Remova/rotacione o segredo e refaca o stage. Se for falso-positivo:\n'
    printf '    git commit --no-verify   (pula a verificacao conscientemente)\n\n'
  } >&2
  exit 1
}

# Guard: roda o fluxo so quando executado, nao quando sourced (o teste sourceia).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
