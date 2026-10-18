#!/usr/bin/env bash
# lib.sh (POSIX) — helpers compartilhados pelos install-clis.sh de Linux e macOS. Sourced; ao carregar
# só define funções e variáveis (sem efeito colateral). Espelha o Write-Step/summary do lado Windows.
#
# Contrato com quem faz source: CHECK, DRYRUN e SUDO definidos (ou vazios) antes de chamar as funções
# — o `run` honra DRYRUN; o instalador de tarball usa ${SUDO:-}.
# Portável para bash 3.2 (o do macOS): sem arrays associativos, `local -`, mapfile nem ${x,,}.

step() { printf '[%-7s] %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Executa respeitando --dry-run (em check nunca chega aqui).
run() {
  if [ "${DRYRUN:-0}" = "1" ]; then step DRY "$*"; return 0; fi
  "$@"
}

# --- contadores p/ summary ------------------------------------------------
N_INSTALLED=0; N_SKIPPED=0; N_WARN=0; N_FAILED=0; FAILURES=""
mark_installed() { N_INSTALLED=$((N_INSTALLED+1)); }
mark_skipped()   { N_SKIPPED=$((N_SKIPPED+1)); }
mark_warn()      { N_WARN=$((N_WARN+1)); }
mark_failed()    { N_FAILED=$((N_FAILED+1)); FAILURES="${FAILURES}${FAILURES:+, }$1"; }

# Imprime o SUMMARY do A1; devolve 1 se algo falhou.
print_a1_summary() {
  echo ''
  echo '──────────── A1 SUMMARY ────────────'
  printf '  Instalado : %s\n' "$N_INSTALLED"
  printf '  Pulado    : %s\n' "$N_SKIPPED"
  [ "$N_WARN" -gt 0 ]   && printf '  Avisos    : %s\n' "$N_WARN"
  printf '  Falhou    : %s\n' "$N_FAILED"
  [ "$N_FAILED" -gt 0 ] && printf '  Falhas    : %s\n' "$FAILURES"
  echo '────────────────────────────────────'
  [ "$N_FAILED" -gt 0 ] && return 1 || return 0
}

# Arquitetura normalizada (amd64/arm64). O Linux diz `aarch64`; o macOS diz `arm64`.
arch_norm() {
  case "$(uname -m)" in
    x86_64)        echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)             uname -m ;;
  esac
}

# Última versão estável do PowerShell (release "latest" do GitHub, exclui prereleases).
# Fallback p/ uma LTS conhecida se a API falhar (rate-limit/offline). Sem dep de jq (usa sed).
PWSH_FALLBACK_VERSION="7.4.6"
pwsh_latest_version() {
  local v
  v="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
  if printf '%s' "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then echo "$v"; else echo "$PWSH_FALLBACK_VERSION"; fi
}

# PowerShell 7 pelo tarball oficial do GitHub — o método "binary archive" da doc da Microsoft, igual
# em Linux e macOS; muda só a plataforma do asset (linux|osx).
# uso: posix_install_pwsh_tarball <linux|osx> <dir-destino> <dir-do-link>
# Encadeado com &&: se um passo falha, NÃO segue criando link para um binário que não existe.
posix_install_pwsh_tarball() {
  local plat="$1" dest="$2" linkdir="$3" ver a
  # Em dry-run não consulta a rede (usa o fallback só p/ exibir o comando).
  if [ "${DRYRUN:-0}" = "1" ]; then ver="$PWSH_FALLBACK_VERSION"; else ver="$(pwsh_latest_version)"; fi
  a="$(arch_norm)"
  case "$a" in
    amd64) a=x64 ;;
    arm64) a=arm64 ;;
    *) step FAIL "pwsh: arquitetura '$a' sem build oficial (a Microsoft publica só x64/arm64)"; return 1 ;;
  esac
  local url="https://github.com/PowerShell/PowerShell/releases/download/v${ver}/powershell-${ver}-${plat}-${a}.tar.gz"
  run ${SUDO:-} mkdir -p "$dest" "$linkdir" \
    && run bash -c "set -o pipefail; curl -fsSL '$url' | ${SUDO:-} tar zxf - -C '$dest'" \
    && run ${SUDO:-} chmod +x "$dest/pwsh" \
    && run ${SUDO:-} ln -sf "$dest/pwsh" "$linkdir/pwsh"
}
