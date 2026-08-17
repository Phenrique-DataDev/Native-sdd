"""
Servidor MCP que expõe um modelo local (via Ollama) como ferramentas para o Claude Code.

O Claude orquestra; este servidor é o "trabalhador" local. Cada tool encaminha o
pedido ao Ollama (http://localhost:11434) e devolve a resposta do modelo escolhido.

Modelos são roteados por tarefa via variáveis de ambiente (default: gpt-oss:20b em tudo):
  CODE_MODEL      -> code review / análise de código
  SECURITY_MODEL  -> análise de segurança / raciocínio
  GENERAL_MODEL   -> uso genérico
  OLLAMA_HOST     -> endpoint do Ollama (default: http://localhost:11434)

ECONOMIA DE TOKENS: toda tool aceita `save_to`. Quando preenchido, a análise COMPLETA
é gravada nesse arquivo e o Claude recebe de volta apenas um RESUMO curto + o caminho —
o conteúdo extenso não entra no contexto do Claude.
"""

import os
from pathlib import Path

import httpx
from mcp.server.fastmcp import FastMCP

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/")
DEFAULT_MODEL = "gpt-oss:20b"
CODE_MODEL = os.environ.get("CODE_MODEL", DEFAULT_MODEL)
SECURITY_MODEL = os.environ.get("SECURITY_MODEL", DEFAULT_MODEL)
GENERAL_MODEL = os.environ.get("GENERAL_MODEL", DEFAULT_MODEL)

# Modelos locais podem demorar; timeout generoso.
TIMEOUT = httpx.Timeout(900.0, connect=10.0)

# Instrução anexada quando vamos salvar em arquivo: pedimos um resumo delimitado no topo.
SUMMARY_DIRECTIVE = (
    "\n\nIMPORTANTE: comece a resposta com um bloco delimitado exatamente assim:\n"
    "<resumo>\n"
    "(2 a 5 frases: veredito geral e a contagem de achados por severidade — "
    "ex.: 2 Críticas, 1 Alta, 1 Média)\n"
    "</resumo>\n"
    "Logo após o bloco, escreva a análise completa e detalhada."
)

mcp = FastMCP("local-ai")


async def _chat(model: str, system: str, prompt: str) -> str:
    """Envia uma conversa de um turno ao Ollama e devolve o texto da resposta."""
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "options": {"temperature": 0.2},
    }
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            r = await client.post(f"{OLLAMA_HOST}/api/chat", json=payload)
            r.raise_for_status()
            data = r.json()
            return data.get("message", {}).get("content", "").strip()
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            return (
                f"[erro] Modelo '{model}' não está baixado no Ollama. "
                f"Rode: ollama pull {model}"
            )
        return f"[erro] Ollama respondeu {e.response.status_code}: {e.response.text[:300]}"
    except httpx.ConnectError:
        return (
            "[erro] Não foi possível conectar ao Ollama em "
            f"{OLLAMA_HOST}. O serviço está rodando? (ollama serve)"
        )


def _extract_summary(content: str) -> str:
    """Extrai o bloco <resumo>...</resumo>; se ausente, usa as primeiras linhas."""
    lo = content.lower()
    i = lo.find("<resumo>")
    j = lo.find("</resumo>")
    if i != -1 and j != -1 and j > i:
        return content[i + len("<resumo>"):j].strip()
    # fallback: primeiras ~6 linhas não vazias
    linhas = [ln for ln in content.splitlines() if ln.strip()][:6]
    return "\n".join(linhas).strip()


def _deliver(content: str, save_to: str) -> str:
    """Se save_to for fornecido, grava o conteúdo completo e retorna só o resumo +
    caminho + tamanho. Caso contrário, retorna o conteúdo inteiro."""
    if content.startswith("[erro]"):
        return content
    if not save_to:
        return content
    path = Path(save_to).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    resumo = _extract_summary(content)
    n_linhas = content.count("\n") + 1
    return (
        f"Análise completa gravada em: {path}\n"
        f"({len(content)} caracteres, {n_linhas} linhas)\n\n"
        f"RESUMO:\n{resumo}\n\n"
        f"(Conteúdo completo no arquivo — leia-o se precisar dos detalhes.)"
    )


@mcp.tool()
async def ask_local_model(
    prompt: str, system: str = "", model: str = "", save_to: str = ""
) -> str:
    """Faz uma pergunta livre ao modelo local. Use para delegar qualquer tarefa ao
    modelo local em vez de fazer você mesmo.

    Args:
        prompt: A pergunta ou instrução para o modelo local.
        system: (Opcional) System prompt para orientar o comportamento do modelo.
        model: (Opcional) Nome exato do modelo no Ollama. Vazio = modelo geral padrão.
        save_to: (Opcional) Caminho de arquivo. Se fornecido, a resposta COMPLETA é
            gravada nele e você recebe apenas um resumo curto + o caminho (economiza
            contexto). Prefira passar um caminho absoluto.
    """
    sys = system + (SUMMARY_DIRECTIVE if save_to else "")
    out = await _chat(model or GENERAL_MODEL, sys, prompt)
    return _deliver(out, save_to)


@mcp.tool()
async def local_code_review(
    code: str, language: str = "", focus: str = "", save_to: str = ""
) -> str:
    """Pede ao modelo local para revisar um trecho de código, apontando bugs,
    problemas de design, legibilidade e melhorias.

    Args:
        code: O código a ser revisado.
        language: (Opcional) Linguagem do código (ex.: python, typescript).
        focus: (Opcional) Foco específico (ex.: "performance", "concorrência").
        save_to: (Opcional) Caminho de arquivo. Se fornecido, a revisão COMPLETA é
            gravada nele e você recebe apenas um resumo curto + o caminho.
    """
    system = (
        "Você é um revisor de código sênior, rigoroso e objetivo. Aponte bugs reais, "
        "riscos de correção, problemas de design e melhorias concretas. Seja direto, "
        "cite linhas/trechos e priorize por severidade. Responda em pt-BR."
    ) + (SUMMARY_DIRECTIVE if save_to else "")
    parts = []
    if language:
        parts.append(f"Linguagem: {language}")
    if focus:
        parts.append(f"Foco solicitado: {focus}")
    parts.append("Revise o código a seguir:\n\n```\n" + code + "\n```")
    out = await _chat(CODE_MODEL, system, "\n".join(parts))
    return _deliver(out, save_to)


@mcp.tool()
async def local_security_review(
    code: str, language: str = "", context: str = "", save_to: str = ""
) -> str:
    """Pede ao modelo local uma análise de segurança defensiva de um trecho de código:
    vulnerabilidades, vetores de ataque e como mitigar.

    Args:
        code: O código a ser analisado.
        language: (Opcional) Linguagem do código.
        context: (Opcional) Contexto de uso (ex.: "endpoint público", "parser de upload").
        save_to: (Opcional) Caminho de arquivo. Se fornecido, a análise COMPLETA é
            gravada nele e você recebe apenas um resumo curto + o caminho.
    """
    system = (
        "Você é um analista de segurança de aplicações (AppSec) defensivo. Identifique "
        "vulnerabilidades (injeção, authz/authn, deserialização, path traversal, segredos "
        "expostos, SSRF, etc.), classifique por severidade (Crítica/Alta/Média/Baixa) e "
        "proponha mitigações concretas. Foco defensivo. Responda em pt-BR."
    ) + (SUMMARY_DIRECTIVE if save_to else "")
    parts = []
    if language:
        parts.append(f"Linguagem: {language}")
    if context:
        parts.append(f"Contexto: {context}")
    parts.append("Analise a segurança do código a seguir:\n\n```\n" + code + "\n```")
    out = await _chat(SECURITY_MODEL, system, "\n".join(parts))
    return _deliver(out, save_to)


@mcp.tool()
async def list_local_models() -> str:
    """Lista os modelos disponíveis no Ollama local e mostra qual modelo está
    mapeado para cada tarefa (código / segurança / geral)."""
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            r = await client.get(f"{OLLAMA_HOST}/api/tags")
            r.raise_for_status()
            models = [m["name"] for m in r.json().get("models", [])]
    except Exception as e:  # noqa: BLE001
        return f"[erro] Não foi possível listar modelos: {e}"

    installed = "\n".join(f"  - {m}" for m in models) or "  (nenhum modelo baixado)"
    return (
        f"Modelos instalados no Ollama ({OLLAMA_HOST}):\n{installed}\n\n"
        f"Roteamento atual:\n"
        f"  código    -> {CODE_MODEL}\n"
        f"  segurança -> {SECURITY_MODEL}\n"
        f"  geral     -> {GENERAL_MODEL}"
    )


if __name__ == "__main__":
    mcp.run()
