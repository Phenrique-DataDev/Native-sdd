#!/usr/bin/env bash
# install-clis.sh (Linux) — instala as dependências do ambiente dev/dados via gerenciador
# nativo (apt/dnf/pacman) + métodos oficiais (scripts/tarball/binário). Idempotente.
# Equivalente POSIX do onboarding/windows/install-clis.ps1.
#
# Pode ser executado direto ou via onboarding/linux/apply.sh. Honra:
#   --check     só relata o que falta (não instala/escreve)
#   --dry-run   mostra cada ação, sem executar
# Variáveis de ambiente equivalentes: CHECK=1 / DRYRUN=1.
#
# NOTA: deps com repositório externo (pwsh, gh, node) e métodos por distro são os pontos
# mais frágeis — validados de verdade na F3 (Docker: ubuntu/fedora/arch).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Helpers comuns com o macOS (step/have/run, contadores, arch, tarball do pwsh).
# shellcheck source=../posix/lib.sh
. "$SCRIPT_DIR/../posix/lib.sh"

# --- modo (args ou env) ---------------------------------------------------
CHECK="${CHECK:-0}"
DRYRUN="${DRYRUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --check)   CHECK=1 ;;
    --dry-run) DRYRUN=1 ;;
  esac
done

# Detecção do gerenciador de pacotes.
detect_pm() {
  if   have apt-get; then echo apt
  elif have dnf;     then echo dnf
  elif have pacman;  then echo pacman
  else echo unknown; fi
}
PM="$(detect_pm)"

# sudo só quando não-root e disponível.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if have sudo; then SUDO="sudo"; fi
fi

# os-release (ID, VERSION_ID) p/ repos versionados.
OS_ID=""; OS_VERSION_ID=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VERSION_ID="${VERSION_ID:-}"
fi

# Refresh do índice de pacotes (uma vez). apt precisa de 'update'; pacman precisa de '-Sy'
# (sem isso, 'pacman -S' num DB vazio/desatualizado dá "target not found"); dnf resolve sozinho.
PM_REFRESHED=0
pm_refresh() {
  [ "$PM_REFRESHED" = "1" ] && return 0
  case "$PM" in
    apt)    run $SUDO apt-get update -y ;;
    pacman) run $SUDO pacman -Sy --noconfirm ;;
  esac
  PM_REFRESHED=1
}

# Instala um pacote pelo gerenciador nativo (refresh antes, quando o gerenciador exige).
pm_install() {
  case "$PM" in
    apt)    pm_refresh; run $SUDO apt-get install -y "$1" ;;
    dnf)    run $SUDO dnf install -y "$1" ;;
    pacman) pm_refresh; run $SUDO pacman -S --noconfirm --needed "$1" ;;
    *)      return 1 ;;
  esac
}

# Pré-requisitos dos métodos oficiais: curl (downloads), ca-certificates (TLS) e tar (tarball
# do pwsh). Imagens/instalações minimal não trazem esses — garante cedo, via gerenciador. Só age
# quando 'curl' falta (sinal de base crua); senão assume a base já equipada e sai barato.
ensure_base() {
  if [ "$CHECK" = "1" ]; then
    have curl || step INFO "curl faltando (pré-requisito dos downloads)"
    return 0
  fi
  if have curl; then return 0; fi
  step RUN "instalando pré-requisitos (curl, ca-certificates, tar)"
  pm_install ca-certificates || true
  pm_install tar || true
  if pm_install curl; then step OK "pré-requisitos (curl)"; mark_installed
  else step FAIL "curl (pré-requisito)"; mark_failed curl; fi
}

# Instala ferramenta "simples" (1 pacote por gerenciador). Idempotente.
# uso: ensure_simple <cmd> <apt_pkg> <dnf_pkg> <pacman_pkg>   (pkg vazio = não suportado)
ensure_simple() {
  local cmd="$1" apt_p="$2" dnf_p="$3" pac_p="$4" pkg=""
  if have "$cmd"; then step SKIP "$cmd já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "$cmd faltando"; return 0; fi
  case "$PM" in apt) pkg="$apt_p";; dnf) pkg="$dnf_p";; pacman) pkg="$pac_p";; esac
  if [ -z "$pkg" ]; then step WARN "$cmd: sem pacote conhecido p/ $PM"; mark_warn; return 0; fi
  step RUN "instalando $cmd ($pkg via $PM)"
  if pm_install "$pkg"; then step OK "$cmd"; mark_installed
  else step FAIL "$cmd ($pkg)"; mark_failed "$cmd"; fi
}

# --- ferramentas com método especial -------------------------------------

# PowerShell 7 pelo tarball oficial (fallback cross-distro; único caminho no Arch, cujo AUR exige
# makepkg não-root). O download é o de onboarding/posix/lib.sh; aqui só o que é do Linux: o ICU.
install_pwsh_tarball() {
  # ICU é dependência de runtime do pwsh; resolve via gerenciador.
  case "$PM" in
    pacman) pm_install icu || true ;;
    dnf)    pm_install libicu || true ;;
    apt)    pm_install libicu-dev || true ;;
  esac
  posix_install_pwsh_tarball linux /opt/microsoft/powershell/7 /usr/bin
}

ensure_pwsh() {
  if have pwsh; then step SKIP "PowerShell 7 já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "PowerShell 7 faltando"; return 0; fi
  step RUN "instalando PowerShell 7"
  local ok=1
  case "$PM" in
    apt)
      # Repo da Microsoft p/ a versão do Ubuntu/Debian.
      local deb="/tmp/packages-microsoft-prod.deb"
      if run bash -c "curl -fsSL 'https://packages.microsoft.com/config/${OS_ID}/${OS_VERSION_ID}/packages-microsoft-prod.deb' -o '$deb'" \
         && run $SUDO dpkg -i "$deb"; then
        PM_REFRESHED=0; pm_install powershell || ok=0
      else ok=0; fi
      ;;
    dnf)
      # Tenta repo nativo; se falhar, tarball.
      if ! pm_install powershell; then ok=0; fi
      ;;
    pacman)
      ok=0  # força tarball (não há pacote oficial)
      ;;
    *) ok=0 ;;
  esac
  if [ "$ok" != "1" ]; then
    step INFO "pwsh: usando tarball oficial do GitHub (fallback cross-distro)"
    if install_pwsh_tarball; then ok=1; else ok=0; fi
  fi
  if [ "$ok" = "1" ] && { [ "$DRYRUN" = "1" ] || have pwsh; }; then
    step OK "PowerShell 7"; mark_installed
  else
    step FAIL "PowerShell 7"; mark_failed pwsh
  fi
}

# GitHub CLI: Fedora/Arch têm no repo; apt frequentemente não — adiciona o repo oficial.
ensure_gh() {
  if have gh; then step SKIP "gh já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "gh faltando"; return 0; fi
  case "$PM" in
    dnf)    ensure_simple gh "" gh "" ;;
    pacman) ensure_simple gh "" "" github-cli ;;
    apt)
      step RUN "instalando gh (repo oficial GitHub)"
      local key="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
      if run bash -c "$SUDO mkdir -p -m 755 /etc/apt/keyrings \
          && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO tee '$key' >/dev/null \
          && $SUDO chmod go+r '$key' \
          && echo 'deb [arch=$(arch_norm) signed-by=$key] https://cli.github.com/packages stable main' | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null"; then
        PM_REFRESHED=0
        if pm_install gh; then step OK gh; mark_installed; else step FAIL gh; mark_failed gh; fi
      else step FAIL gh; mark_failed gh; fi
      ;;
    *) step WARN "gh: sem método p/ $PM"; mark_warn ;;
  esac
}

# Node.js 22 LTS: Arch entrega 22 no repo; apt/dnf via NodeSource.
ensure_node() {
  if have node; then step SKIP "Node.js já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "Node.js faltando"; return 0; fi
  local ns=""
  case "$PM" in
    pacman)
      ensure_simple node "" "" nodejs
      have npm || pm_install npm || true
      return 0 ;;
    apt) ns="https://deb.nodesource.com/setup_22.x" ;;
    dnf) ns="https://rpm.nodesource.com/setup_22.x" ;;
    *)   step WARN "node: sem método p/ $PM"; mark_warn; return 0 ;;
  esac
  step RUN "instalando Node.js 22 (NodeSource)"
  # O setup do NodeSource precisa rodar como root; '-E' (preserva env) só faz sentido com sudo.
  local runner="bash -"
  [ -n "$SUDO" ] && runner="$SUDO -E bash -"
  if run bash -c "curl -fsSL '$ns' | $runner"; then
    PM_REFRESHED=0
    if pm_install nodejs; then step OK "Node.js"; mark_installed; else step FAIL "Node.js"; mark_failed node; fi
  else
    step FAIL "Node.js"; mark_failed node
  fi
}

# yq (Mike Farah, Go): binário único do GitHub — evita confundir com o yq python de alguns repos.
ensure_yq() {
  if have yq; then step SKIP "yq já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "yq faltando"; return 0; fi
  step RUN "instalando yq (binário GitHub)"
  local a; a="$(arch_norm)"
  if run bash -c "curl -fsSL 'https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${a}' -o /tmp/yq && $SUDO install -m 755 /tmp/yq /usr/bin/yq"; then
    step OK yq; mark_installed
  else step FAIL yq; mark_failed yq; fi
}

# uv (astral-sh): script oficial (instala em ~/.local/bin).
ensure_uv() {
  if have uv; then step SKIP "uv já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "uv faltando"; return 0; fi
  step RUN "instalando uv (script oficial astral.sh)"
  if run bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"; then
    step OK uv; mark_installed
  else step FAIL uv; mark_failed uv; fi
}

# Claude Code: script oficial (equivalente ao install.ps1 do Windows).
ensure_claude() {
  if have claude; then step SKIP "Claude Code já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "Claude Code faltando"; return 0; fi
  step RUN "instalando Claude Code (script oficial)"
  if run bash -c "curl -fsSL https://claude.ai/install.sh | bash"; then
    step OK "Claude Code"; mark_installed
  else step FAIL "Claude Code"; mark_failed claude-code; fi
}

# --- execução -------------------------------------------------------------
main() {
  if [ "$PM" = "unknown" ]; then
    step FAIL "Gerenciador de pacotes não reconhecido (apt/dnf/pacman). Abortando A1."
    return 1
  fi
  step INFO "Gerenciador: $PM | SO: ${OS_ID:-?} ${OS_VERSION_ID:-} | sudo: ${SUDO:-(root)}"
  if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    step WARN "sem root e sem sudo — instalações de pacote vão falhar (rode como root ou instale sudo)"
  fi

  ensure_base

  step INFO "Dependências:"
  ensure_simple git    git    git    git
  ensure_simple python3 python3 python3 python
  ensure_simple rg     ripgrep ripgrep ripgrep
  ensure_simple jq     jq     jq     jq
  ensure_gh
  ensure_node
  ensure_yq
  ensure_pwsh
  ensure_uv

  step INFO "Claude Code:"
  ensure_claude

  print_a1_summary
}

main
