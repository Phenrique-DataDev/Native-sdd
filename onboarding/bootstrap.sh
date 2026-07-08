#!/usr/bin/env bash
# bootstrap.sh — bootstrap remoto do Native-SDD (Linux): baixa `main` do espelho público e delega
# ao onboarding/install.sh, sem exigir repo clonado nem git/gh (só bash + curl + tar).
#
# Único script do onboarding pensado para rodar SEM nada em disco (curl <raw>/bootstrap.sh | bash):
# a URL do conteúdo fica inline aqui (owner/repo fixos no espelho público — Decisão 6 do
# DESIGN_BOOTSTRAP_REMOTO; trocar o destino exige editar este arquivo, nunca um parâmetro).
#
# Sem flags:  curl -fsSL https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.sh | bash
# Com flags:  curl -fsSL <mesma url> | bash -s -- --check
#
# Erros propagam (set -euo pipefail): falha de download/extração é fatal, sem modo degradado.
# O diretório temporário é removido ao final (trap EXIT), mesmo em falha.
set -euo pipefail

step() { printf '[%-7s] %s\n' "$1" "$2"; }

# Sugestão de instalação por gerenciador de pacotes — best-effort, só para a mensagem de erro
# ficar acionável (achado de revisão adversarial: em imagens minimalistas comuns, como
# ubuntu:24.04/debian:12-slim "de fábrica", `curl` não vem pré-instalado; sem esta checagem o
# usuário só via um "command not found" cru, sem saber o que instalar).
suggest_install() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y $1"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf install -y $1"
    elif command -v yum >/dev/null 2>&1; then echo "yum install -y $1"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman -Sy --noconfirm $1"
    elif command -v apk >/dev/null 2>&1; then echo "apk add $1"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper install -y $1"
    else echo "instale $1 com o gerenciador de pacotes da sua distro"
    fi
}

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        step FAIL "'$cmd' nao encontrado — pre-requisito deste bootstrap (bash + curl + tar)"
        step INFO "tente: $(suggest_install "$cmd")"
        exit 1
    fi
done

echo ''
echo '╔══════════════════════════════════════════╗'
echo '║   Bootstrap remoto · Native-SDD           ║'
echo '╚══════════════════════════════════════════╝'

url="https://codeload.github.com/Phenrique-DataDev/Native-sdd/tar.gz/refs/heads/main"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

step INFO "baixando $url"
curl -fsSL "$url" -o "$tmp/native-sdd.tar.gz"

step INFO "extraindo em $tmp"
tar -xzf "$tmp/native-sdd.tar.gz" -C "$tmp" --strip-components=1

# Guard explícito: sem isso, estrutura inesperada (tar sem o wrapper de pasta-raiz que o codeload
# real sempre gera) vira um "No such file or directory" cru do bash, sem indicar a causa real
# (achado de revisão adversarial).
if [ ! -f "$tmp/onboarding/install.sh" ]; then
  step FAIL "estrutura inesperada apos extrair o tarball — onboarding/install.sh nao encontrado em $tmp"
  exit 1
fi

step INFO 'delegando a onboarding/install.sh (args repassados)'
# Sem `exec`: substituir o processo pularia o trap EXIT e deixaria o temporário para trás
# (Decisão 5: cleanup sempre). O exit code do install.sh propaga via set -e.
bash "$tmp/onboarding/install.sh" "$@"
