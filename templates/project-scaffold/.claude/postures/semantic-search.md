# Busca semântica — disciplina completa (sob demanda)

> **Carregada sob demanda**, não always-on. A rule [`../rules/semantic-search.md`](../rules/semantic-search.md)
> guarda o **predicado** (o MCP `semantic-kb` está conectado?) e manda ler este arquivo antes da
> primeira busca semântica da sessão. Custo numa sessão que não faz nenhuma: **0 token**.

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
| Tool **conectada** mas **Ollama fora do ar / modelo não baixado** | Retorno começa com `[indisponivel]` — **degradação esperada, não pendência do projeto** (ver abaixo) |

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

## Retorno `[indisponivel]` — degradação esperada, não pendência do projeto

O MCP é registrado **user-scope** no onboarding: a tool aparece **conectada em todo projeto da
máquina**, inclusive nos que nunca vão usar busca semântica. Por isso "conectada" **não** significa
"utilizável aqui" — o Ollama (dependência **local e opcional** do scaffold) pode estar fora do ar ou
sem o modelo baixado. Nesses casos `reindex`/`semantic_search` **degrada sozinho** e devolve uma
string começando com **`[indisponivel]`** (não trava, não custa os ~35s de antes — há fail-fast).

**Quando ver `[indisponivel]` no retorno:** é degradação **esperada** de infra opcional — **nada do
projeto quebra**. **Não** repita a chamada, **não** reporte como pendência do projeto ao usuário, e
**não** peça para "resolver o Ollama" a menos que ele **queira** busca semântica. Siga o trabalho:
`Grep`/`Glob` cobrem o caso. A própria mensagem já distingue a causa (Ollama fora do ar × modelo não
baixado) e traz o comando exato — repasse-a **só** se o usuário perguntar como ligar.

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
- **Não** trate um retorno `[indisponivel]` (Ollama fora do ar / modelo não baixado) como pendência
  do projeto: é infra **local e opcional**, degrada sozinha; **não repita, não reporte, siga** com
  `Grep`/`Glob`. Repasse a mensagem só se o usuário perguntar como habilitar.
