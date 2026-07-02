#!/usr/bin/env bash
# install-local-ai.sh — provisiona o MCP "local-ai" (modelo local via Ollama) no macOS/Linux.
# Autônomo de propósito: os apply.sh de macOS/Linux ainda são stubs, então este script não
# depende deles. Idempotente e NÃO bloqueante (falha vira aviso, nunca aborta no meio).
# Equivalente ao onboarding/windows/install-local-ai.ps1.
#
# Uso:
#   ./install-local-ai.sh                      # modelo default (gpt-oss:20b)
#   ./install-local-ai.sh qwen2.5-coder:7b     # modelo mais leve (pouca VRAM/RAM)
#   MODEL=llama3.1:8b ./install-local-ai.sh    # idem, via env var
#   CHECK=1 ./install-local-ai.sh              # "doctor": só relata o que falta, não instala
#
# Passos (todos não-bloqueantes): uv sync -> ollama pull -> claude mcp add (user scope).
set -uo pipefail

MODEL="${1:-${MODEL:-gpt-oss:20b}}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
CHECK="${CHECK:-0}"

# Diretório deste script = onde vive o server.py versionado.
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- logging padronizado (espelha Write-Step do lado Windows) ---------------
log() { printf '[%-7s] %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

warn_count=0
warn() { log WARN "$1"; warn_count=$((warn_count + 1)); }

host_note=""
[ "$OLLAMA_HOST" != "http://localhost:11434" ] && host_note=" · host: $OLLAMA_HOST"
log INFO "local-ai: server em $SERVER_DIR (modelo: $MODEL$host_note)"

if [ ! -f "$SERVER_DIR/server.py" ]; then
  warn "local-ai: server.py não encontrado em $SERVER_DIR — repo incompleto?"
  exit 0
fi

# --- aviso de hardware (best-effort, NVIDIA) — só avisa, nunca bloqueia ------
# Estima a VRAM sugerida pelo nº de bilhões de parâmetros no nome (~0.7 GB/bilhão, Q4).
if command -v nvidia-smi >/dev/null 2>&1; then
  vram_mb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9')"
  params_b="$(printf '%s' "$MODEL" | grep -oiE '[0-9]+(\.[0-9]+)?b' | head -n1 | tr -dc '0-9.')"
  if [ -n "$vram_mb" ] && [ -n "$params_b" ]; then
    vram_gb=$(( vram_mb / 1024 ))
    min_gb=$(awk -v p="$params_b" 'BEGIN{ m=int(p*0.7+0.5); if(m<4)m=4; print m }')
    if [ "$vram_gb" -lt "$min_gb" ]; then
      warn "local-ai: GPU com ~${vram_gb} GB de VRAM < ~${min_gb} GB sugeridos p/ '$MODEL'. O modelo será baixado, mas pode rodar lento ou falhar — considere um modelo menor (ex.: qwen2.5-coder:7b)."
    fi
  fi
fi

# --- pré-checagens ----------------------------------------------------------
have claude || warn "claude ausente — instale o Claude Code (sem ele não dá p/ registrar o MCP)"
have uv     || warn "uv ausente — instale (curl -LsSf https://astral.sh/uv/install.sh | sh)"
if have ollama; then
  log OK "Ollama presente"
else
  warn "Ollama ausente — instale (curl -fsSL https://ollama.com/install.sh | sh) e rode 'ollama serve'"
fi

# --- doctor / dry: só relata, não instala -----------------------------------
if [ "$CHECK" = "1" ]; then
  if have ollama && ollama list 2>/dev/null | grep -q "$MODEL"; then
    log INFO "local-ai: modelo $MODEL já baixado"
  else
    log INFO "local-ai: modelo $MODEL ausente (seria baixado)"
  fi
  if have claude && claude mcp get local-ai >/dev/null 2>&1; then
    log INFO "local-ai: MCP já registrado"
  else
    log INFO "local-ai: MCP não registrado (seria registrado)"
  fi
  log INFO "local-ai: doctor — $warn_count aviso(s). Nada foi instalado (CHECK=1)."
  exit 0
fi

# --- uv sync (deps do server) ----------------------------------------------
if have uv; then
  if (cd "$SERVER_DIR" && uv sync >/dev/null 2>&1); then
    log OK "local-ai: deps do server instaladas (uv sync)"
  else
    warn "local-ai: 'uv sync' falhou — rode manualmente em $SERVER_DIR"
  fi
else
  warn "local-ai: sem uv — pulei o preparo do server e o registro do MCP"
  log INFO "local-ai: $warn_count aviso(s)."
  exit 0
fi

# --- ollama pull (modelo) — pesado, GBs ------------------------------------
if have ollama; then
  if ollama list 2>/dev/null | grep -q "$MODEL"; then
    log SKIP "local-ai: modelo $MODEL já baixado"
  else
    log RUN "local-ai: baixando modelo $MODEL (pode demorar — GBs)..."
    if ollama pull "$MODEL"; then
      log OK "local-ai: modelo $MODEL baixado"
    else
      warn "local-ai: 'ollama pull $MODEL' falhou — baixe manualmente depois"
    fi
  fi
fi

# --- claude mcp add (registro user-scoped) ---------------------------------
if have claude; then
  if claude mcp get local-ai >/dev/null 2>&1; then
    log SKIP "local-ai: MCP já registrado — reinicie o Claude Code p/ recarregar"
  else
    if claude mcp add local-ai --scope user \
        -e "CODE_MODEL=$MODEL" \
        -e "SECURITY_MODEL=$MODEL" \
        -e "GENERAL_MODEL=$MODEL" \
        -e "OLLAMA_HOST=$OLLAMA_HOST" \
        -- uv run --directory "$SERVER_DIR" server.py >/dev/null 2>&1; then
      log OK "local-ai registrado (reinicie o Claude Code para carregar o MCP)"
    else
      warn "local-ai: 'claude mcp add' falhou — registre manualmente depois"
    fi
  fi
else
  warn "local-ai: sem claude — pulei o registro do MCP"
fi

log INFO "local-ai: concluído — $warn_count aviso(s)."
