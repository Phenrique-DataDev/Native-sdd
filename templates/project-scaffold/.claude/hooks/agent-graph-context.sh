#!/usr/bin/env bash
# Degradacao CONSCIENTE do agent-graph-context sem pwsh (molde J4/curation-nudge.sh). NAO porta
# a leitura do grafo: ela depende de tools/graph-export.ps1 (fora do escopo do J4).
#
# Acionado pela dispatch-line do settings.json SO quando nao ha pwsh. Diferente do
# curation-nudge.sh (que avisa 1x por SessionStart), este hook dispara em TODO SubagentStart —
# avisar a cada subagente seria ruido, entao aqui a degradacao e SILENCIOSA (sem additionalContext).
# Read-only, nunca bloqueia.

main() {
  cat >/dev/null 2>&1 || true   # drena o stdin do hook sem processar
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
