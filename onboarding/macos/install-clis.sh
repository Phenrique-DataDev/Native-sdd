#!/usr/bin/env bash
# install-clis.sh (macOS) — instala as dependências do ambiente dev/dados via Homebrew + métodos
# oficiais (tarball do PowerShell, script do Claude Code). Idempotente. Equivalente do
# onboarding/linux/install-clis.sh e do onboarding/windows/install-clis.ps1.
#
# Pode ser executado direto ou via onboarding/macos/apply.sh. Honra:
#   --check     só relata o que falta (não instala/escreve)
#   --dry-run   mostra cada ação, sem executar
# Variáveis de ambiente equivalentes: CHECK=1 / DRYRUN=1.
#
# Validado nos runners arm64 macos-15 e macos-26 do GitHub Actions (não há Mac local). O runner já
# traz Homebrew, git, gh, node, jq, yq e pwsh — então a INSTALAÇÃO DO HOMEBREW do zero não é
# exercida lá, nem o sudo_prime (o sudo do runner não pede senha). Declarado, não esquecido.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# sudo só quando não-root e disponível (o tarball do pwsh vai para /usr/local).
SUDO=""
if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo"; fi

export HOMEBREW_NO_ENV_HINTS=1

# Prefixo padrão do Homebrew por arquitetura (doc do Homebrew): Apple Silicon usa /opt/homebrew;
# Intel usa /usr/local. Nenhum dos dois entra no PATH de um processo novo sem `brew shellenv`.
brew_prefix() {
  case "$(uname -m)" in
    arm64) echo /opt/homebrew ;;
    *)     echo /usr/local ;;
  esac
}

# Carrega o brew no PATH DESTE processo, se ele existir no prefixo padrão.
load_brew() {
  local b
  b="$(brew_prefix)/bin/brew"
  if [ -x "$b" ]; then eval "$("$b" shellenv)"; fi
}

# Autentica o sudo UMA vez, antes de tudo, e mantém a credencial viva até o fim do A1.
# Por quê: com NONINTERACTIVE=1 o instalador do Homebrew só chama `sudo -n` e ABORTA sem credencial
# em cache ("Need sudo access on macOS"); a instalação das Command Line Tools pode passar dos 5 min do
# timestamp do sudo, e o tarball do pwsh usa sudo depois dela. O teste é o TERMINAL DE CONTROLE
# (/dev/tty), não o stdin: no `curl … | bash` do bootstrap o stdin é o pipe (`[ -t 0 ]` falso), mas o
# sudo pede a senha no /dev/tty mesmo assim. Keep-alive no molde do mathiasbynens/dotfiles (.macos),
# com saída em /dev/null — senão o `$(…)` de quem captura a saída esperaria o loop.
# Sem terminal e sem cache (CI sem NOPASSWD), não pede nada: quem precisar de sudo falha visível.
SUDO_KEEPALIVE_PID=""
sudo_prime() {
  { [ -n "$SUDO" ] && [ "$CHECK" != "1" ] && [ "$DRYRUN" != "1" ]; } || return 0
  if ! sudo -n true 2>/dev/null; then
    ( : </dev/tty ) 2>/dev/null || return 0
    step INFO "o Homebrew e o PowerShell precisam de sudo — informe a senha de administrador"
    sudo -v </dev/tty || { step INFO "sudo não autenticado — o que depende dele vai falhar"; return 0; }
  fi
  ( while sudo -n true 2>/dev/null; do sleep 60; kill -0 "$$" 2>/dev/null || exit 0; done ) >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

ensure_brew() {
  load_brew
  if have brew; then step SKIP "Homebrew já instalado ($(brew --prefix))"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "Homebrew faltando (pré-requisito das demais deps)"; return 0; fi
  step RUN "instalando Homebrew (script oficial; instala as Command Line Tools se faltarem)"
  # NONINTERACTIVE=1 dispensa as confirmações, mas NÃO a senha: a credencial vem do sudo_prime.
  if run /bin/bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; then
    load_brew
    if [ "$DRYRUN" = "1" ] || have brew; then step OK "Homebrew"; mark_installed; return 0; fi
  fi
  step FAIL "Homebrew"
  step INFO "instale à mão (https://brew.sh) e rode de novo — as demais deps dependem dele"
  mark_failed brew
}

# Instala uma ferramenta por fórmula do Homebrew. Idempotente (pula o que o PATH já resolve).
# uso: ensure_formula <cmd> <formula>
ensure_formula() {
  local cmd="$1" f="$2"
  if have "$cmd"; then step SKIP "$cmd já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "$cmd faltando"; return 0; fi
  if ! have brew && [ "$DRYRUN" != "1" ]; then
    step FAIL "$cmd: Homebrew indisponível"; mark_failed "$cmd"; return 0
  fi
  step RUN "instalando $cmd (brew install $f)"
  if run brew install "$f"; then step OK "$cmd"; mark_installed
  else step FAIL "$cmd ($f)"; mark_failed "$cmd"; fi
}

# PowerShell 7: runtime do framework. Tarball oficial — o método "binary archive" da doc da
# Microsoft para macOS: /usr/local/microsoft/powershell/7 + link em /usr/local/bin (no PATH padrão).
# A fórmula `powershell` do brew é community-built (compila do fonte) — fica de fora.
ensure_pwsh() {
  if have pwsh; then step SKIP "PowerShell 7 já instalado"; mark_skipped; return 0; fi
  if [ "$CHECK" = "1" ]; then step INFO "PowerShell 7 faltando"; return 0; fi
  step RUN "instalando PowerShell 7 (tarball oficial osx-$(arch_norm | sed 's/amd64/x64/'))"
  if posix_install_pwsh_tarball osx /usr/local/microsoft/powershell/7 /usr/local/bin \
     && { [ "$DRYRUN" = "1" ] || have pwsh; }; then
    step OK "PowerShell 7"; mark_installed
  else
    step FAIL "PowerShell 7"; mark_failed pwsh
  fi
}

# Claude Code: script oficial (a doc cobre macOS). Instala em ~/.local/bin.
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
  if [ "$(uname -s)" != "Darwin" ]; then
    step FAIL "este instalador é do macOS (uname: $(uname -s)) — use onboarding/install.sh"
    return 2
  fi
  step INFO "macOS $(sw_vers -productVersion 2>/dev/null || echo ?) | arch: $(uname -m) | sudo: ${SUDO:-(root)}"

  # Só pede senha se algo que usa sudo vai ser instalado (Homebrew ou pwsh) — re-rodar não incomoda.
  load_brew
  if ! have brew || ! have pwsh; then sudo_prime; fi

  ensure_brew

  step INFO "Dependências:"
  ensure_formula git     git
  ensure_formula python3 python
  ensure_formula rg      ripgrep
  ensure_formula jq      jq
  ensure_formula gh      gh
  ensure_formula node    node
  ensure_formula yq      yq
  ensure_formula uv      uv
  ensure_pwsh

  step INFO "Claude Code:"
  ensure_claude

  print_a1_summary
}

main
