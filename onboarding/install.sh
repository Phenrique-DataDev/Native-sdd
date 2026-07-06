#!/usr/bin/env bash
# install.sh — entrypoint POSIX do instalador (Linux/macOS). Espelha o papel do install.ps1.
# Detecta o SO e delega ao apply.sh correspondente. Precisa do repositório clonado (usa os
# templates versionados); não é um curl|bash standalone.
#
# Uso: ./onboarding/install.sh [flags]   (as flags são repassadas ao apply.sh; veja --help dele)
#   máquina recém-formatada: bash ./onboarding/install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
step() { printf '[%-7s] %s\n' "$1" "$2"; }

echo ''
echo '╔══════════════════════════════════════════╗'
echo '║   Instalador de ambiente · SDD workflow   ║'
echo '╚══════════════════════════════════════════╝'

OS="$(uname -s)"
case "$OS" in
  Linux)
    exec bash "$SCRIPT_DIR/linux/apply.sh" "$@"
    ;;
  Darwin)
    step INFO 'macOS ainda não implementado. Ver onboarding/macos/apply.sh (stub).'
    exec bash "$SCRIPT_DIR/macos/apply.sh" "$@"
    ;;
  *)
    step FAIL "SO não suportado por este entrypoint: $OS"
    step INFO 'No Windows use: powershell -ExecutionPolicy Bypass -NoProfile -File .\onboarding\install.ps1'
    exit 2
    ;;
esac
