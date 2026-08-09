#!/usr/bin/env bash
# install-semantic-kb.sh — provisiona o MCP "semantic-kb" (busca semântica local via Ollama +
# sqlite-vec) no macOS/Linux. Autônomo de propósito (molde install-local-ai.sh): não depende dos
# apply.sh de macOS/Linux, que ainda são stubs. Idempotente e NÃO bloqueante (falha vira aviso,
# nunca aborta no meio). Equivalente ao onboarding/windows/install-semantic-kb.ps1.
#
# Opt-in INDEPENDENTE do local-ai — ambos usam Ollama, mas baixam modelos diferentes (embedding
# vs. chat) e são registrados como MCPs separados (responsabilidade única, ver
# .claude/sdd/features/DESIGN_RAG_HIBRIDO.md).
#
# Uso:
#   ./install-semantic-kb.sh                        # modelo default (nomic-embed-text)
#   ./install-semantic-kb.sh outro-modelo-embedding  # outro modelo de embedding
#   OLLAMA_HOST=http://192.168.0.10:11434 ./install-semantic-kb.sh  # Ollama remoto
#   CHECK=1 ./install-semantic-kb.sh                 # "doctor": só relata o que falta
#
# Passos (todos não-bloqueantes): uv sync -> ollama pull -> claude mcp add (user scope).
set -uo pipefail

MODEL="${1:-${EMBED_MODEL:-nomic-embed-text}}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
CHECK="${CHECK:-0}"

# Diretório deste script = onde vive o server.py versionado.
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- logging padronizado (espelha install-local-ai.sh) ----------------------
log() { printf '[%-7s] %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

warn_count=0
warn() { log WARN "$1"; warn_count=$((warn_count + 1)); }

host_note=""
[ "$OLLAMA_HOST" != "http://localhost:11434" ] && host_note=" · host: $OLLAMA_HOST"
log INFO "semantic-kb: server em $SERVER_DIR (modelo: $MODEL$host_note)"

if [ ! -f "$SERVER_DIR/server.py" ]; then
  warn "semantic-kb: server.py não encontrado em $SERVER_DIR — repo incompleto?"
  exit 0
fi

# --- pré-checagens ------------------------------------------------------------
have claude || warn "claude ausente — instale o Claude Code (sem ele não dá p/ registrar o MCP)"
have uv     || warn "uv ausente — instale (curl -LsSf https://astral.sh/uv/install.sh | sh)"
if have ollama; then
  log OK "Ollama presente"
else
  warn "Ollama ausente — instale (curl -fsSL https://ollama.com/install.sh | sh) e rode 'ollama serve'"
fi

# --- doctor / dry: só relata, não instala -------------------------------------
if [ "$CHECK" = "1" ]; then
  if have ollama && ollama list 2>/dev/null | grep -q "$MODEL"; then
    log INFO "semantic-kb: modelo $MODEL já baixado"
  else
    log INFO "semantic-kb: modelo $MODEL ausente (seria baixado)"
  fi
  if have claude && claude mcp get semantic-kb >/dev/null 2>&1; then
    log INFO "semantic-kb: MCP já registrado"
  else
    log INFO "semantic-kb: MCP não registrado (seria registrado)"
  fi
  log INFO "semantic-kb: doctor — $warn_count aviso(s). Nada foi instalado (CHECK=1)."
  exit 0
fi

# --- uv sync (deps do server) -------------------------------------------------
if have uv; then
  if (cd "$SERVER_DIR" && uv sync >/dev/null 2>&1); then
    log OK "semantic-kb: deps do server instaladas (uv sync)"
  else
    warn "semantic-kb: 'uv sync' falhou — rode manualmente em $SERVER_DIR"
  fi
else
  warn "semantic-kb: sem uv — pulei o preparo do server e o registro do MCP"
  log INFO "semantic-kb: $warn_count aviso(s)."
  exit 0
fi

# --- ollama pull (modelo de embedding — leve, ~274MB) -------------------------
if have ollama; then
  if ollama list 2>/dev/null | grep -q "$MODEL"; then
    log SKIP "semantic-kb: modelo $MODEL já baixado"
  else
    log RUN "semantic-kb: baixando modelo $MODEL..."
    if ollama pull "$MODEL"; then
      log OK "semantic-kb: modelo $MODEL baixado"
    else
      warn "semantic-kb: 'ollama pull $MODEL' falhou — baixe manualmente depois"
    fi
  fi
fi

# --- claude mcp add (registro user-scoped) ------------------------------------
if have claude; then
  if claude mcp get semantic-kb >/dev/null 2>&1; then
    log SKIP "semantic-kb: MCP já registrado — reinicie o Claude Code p/ recarregar"
  else
    if claude mcp add semantic-kb --scope user \
        -e "EMBED_MODEL=$MODEL" \
        -e "OLLAMA_HOST=$OLLAMA_HOST" \
        -- uv run --directory "$SERVER_DIR" server.py >/dev/null 2>&1; then
      log OK "semantic-kb registrado (reinicie o Claude Code para carregar o MCP)"
    else
      warn "semantic-kb: 'claude mcp add' falhou — registre manualmente depois"
    fi
  fi
else
  warn "semantic-kb: sem claude — pulei o registro do MCP"
fi

log INFO "semantic-kb: concluído — $warn_count aviso(s)."
