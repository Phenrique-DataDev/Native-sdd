# Semantic-search — busca semântica opt-in sobre KB/docs/archive

> **Otimização, quando o MCP `semantic-kb` estiver instalado** (opt-in via
> `install.ps1 -WithSemanticKb`/`install.sh` — ver
> [`onboarding/semantic-kb/README.md`](../../../onboarding/semantic-kb/README.md)). Complementa
> `Grep`/`Glob`, **nunca** os substitui: quando a pergunta é linguagem natural sobre prosa
> acumulada (KB/`docs/`/histórico `archive/`), prefira `semantic_search`; quando é símbolo/
> arquivo/estrutura exata, `Grep`/`Glob` continuam melhores.

## Princípio

Grep/glob são ótimos quando você sabe o termo exato. Prosa acumulada ao longo de muitos ciclos SDD
cresce em volume e vocabulário — uma pergunta como *"onde decidimos usar X em vez de Y?"* pode não
bater em nenhuma palavra-chave previsível. O MCP `semantic-kb` (Ollama local + `sqlite-vec`,
**opt-in**, índice regenerado por reindexação incremental, nunca um processo em segundo plano)
existe para esse caso: busca por significado, não por string exata.

## Quando aplica

| Sinal | Exemplo |
|-------|---------|
| Pergunta em **linguagem natural** sobre uma decisão/contexto passado, sem termo exato conhecido | *"por que escolhemos não usar X aqui?"*, *"onde já discutimos Y?"* |
| Busca **parafraseada** — o termo da pergunta não é o termo usado no texto original | Pergunta usa "cache" mas o documento fala em "artefato gerado" |
| Corpus **grande e heterogêneo** onde grep já devolveu ruído demais | Muitos `archive/*/SHIPPED_*.md` acumulados, dezenas de entradas de KB |

## Quando NÃO aplica (siga com `Grep`/`Glob`)

| Sinal | Exemplo |
|-------|---------|
| Você sabe o **nome exato** do arquivo/símbolo/função | `Get-KbInventory`, `adapt.md`, um `id` de KB |
| Busca em **código-fonte** (`tools/*.ps1`, `.claude/commands/`) | `semantic-kb` não indexa código de propósito — fora de escopo |
| Consulta por **campo estruturado** da KB (`layer`/`domain`) | Já resolvido por filtro exato (`Get-KbInventory`), mais preciso que ranking semântico |
| MCP `semantic-kb` **não está instalado** | Degrada em silêncio — nem tente a tool, ela não vai existir |

## Como aplicar

1. **Verifique se a tool está disponível** (`mcp__semantic-kb__semantic_search`) — se não estiver
   conectada, o MCP não foi instalado; siga direto com `Grep`/`Glob` (degradação graciosa, molde
   `docs-first.md`/`context7`).
2. **Chame `semantic_search(query, project_root=".")`** com a pergunta em linguagem natural.
3. **Leia o retorno como ponteiro, não como resposta:** path + score + trecho curto por
   resultado — **nunca** o arquivo inteiro (economia de contexto, molde `local-ai`). Use `Read`
   no path retornado se precisar do conteúdo completo.
4. **Índice pode estar desatualizado** — a reindexação é incremental e disparada em pontos
   pontuais do fluxo (`/train-kb`, `/sync-context`, `/document`, `/ship`), nunca em tempo real.
   Se o resultado parecer obsoleto, chame `reindex(project_root=".")` antes de buscar de novo.

## O que NÃO fazer

- **Não** tente `semantic_search` sem antes confirmar que o MCP está conectado — sem ele
  instalado, a tool simplesmente não existe; use `Grep`/`Glob` direto.
- **Não** trate o resultado como o conteúdo final — é um **ponteiro** (path + trecho curto);
  leia o arquivo você mesmo se precisar de detalhe.
- **Não** use para código-fonte, nome de arquivo/símbolo conhecido, ou campo estruturado da KB —
  nesses casos `Grep`/`Glob`/filtro por `layer`+`domain` são mais precisos e mais rápidos.
- **Não** espere resultado em tempo real de uma mudança que acabou de acontecer — a reindexação é
  incremental e pontual, não instantânea; rode `reindex` explicitamente se precisar do estado mais
  recente.
