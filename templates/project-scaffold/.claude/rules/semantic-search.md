# Semantic-search — busca por significado na KB/docs (opt-in, condicional)

> **Regra condicional.** O MCP `semantic-kb` (Ollama local + `sqlite-vec`) é **opt-in** do
> onboarding: na maioria dos projetos ele não está lá, e nesses a disciplina inteira é inerte. Por
> isso ela **não é always-on** — vive em [`../postures/semantic-search.md`](../postures/semantic-search.md)
> e é lida quando o predicado abaixo é verdadeiro.

## Predicado observável

**A tool `mcp__semantic-kb__semantic_search` está disponível nesta sessão?**

| Resposta | O que fazer |
|----------|-------------|
| **Não** | **Nada.** O MCP não foi instalado; a tool não existe. Use `Grep`/`Glob` normalmente — é o caminho padrão, não um fallback degradado. **Pare aqui.** |
| **Sim**, e a pergunta é em **linguagem natural** sobre prosa acumulada (KB/`docs/`/`archive/`), sem termo exato conhecido | **Leia** `.claude/postures/semantic-search.md` antes da primeira busca da sessão. |
| **Sim**, mas você sabe o **nome exato** (arquivo/símbolo/`id`), busca **código-fonte**, ou filtra campo estruturado (`layer`/`domain`) | Use `Grep`/`Glob`/filtro exato — são mais precisos aqui. A busca semântica **não** substitui os dois. |

## O mínimo que vale mesmo sem ler a postura

- **O retorno é ponteiro, não resposta:** path + score + trecho curto. `Read` o arquivo se precisar
  do conteúdo — nunca trate o trecho como o todo.
- **Retorno começando com `[indisponivel]`** (Ollama fora do ar / modelo não baixado) é **degradação
  esperada de infra opcional**, não pendência do projeto: **não repita a chamada, não reporte ao
  usuário, siga com `Grep`/`Glob`**. Repasse a mensagem só se ele perguntar como habilitar.

> **Por que esta rule é curta:** ela custava ~2 400 tokens em **toda** sessão, inclusive nas
> incontáveis em que o MCP nem está instalado. A disciplina não foi removida — foi movida para onde
> é lida por quem de fato vai buscar.
