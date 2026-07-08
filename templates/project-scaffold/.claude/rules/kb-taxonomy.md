# Taxonomia da KB — 4 camadas

> Base de conhecimento opcional do projeto, em `.claude/kb/`. Cada arquivo pertence a
> **exatamente uma** camada — a camada responde a um *tipo* de pergunta. (Templates de KB
> e bootstrap entram na feature **B5**; esta regra define a disciplina.)

## As 4 camadas

| Camada | Pergunta principal | O que vive aqui |
|--------|-------------------|-----------------|
| **business/** | *Qual é a regra de negócio / métrica?* | KPIs, glossário, políticas de produto |
| **tools/** | *Como funciona esta tecnologia em geral?* | Docs agnósticas de fornecedor (ex.: SQL, Python, dbt, warehouse) |
| **implementation/** | *O que **nós** construímos/configuramos?* | Schemas, URLs internas, IDs, nomes concretos da nossa instância |
| **operations/** | *Como rodo, reinicio ou recupero?* | Runbooks, playbooks de incidente |

## Disciplina

1. **Identifique a camada primeiro.** Diga a camada explicitamente quando não for óbvia.
2. **Respostas multi-camada:** use cabeçalhos `### Negócio`, `### Ferramenta`,
   `### Implementação`, `### Operação` em vez de misturar tudo num bloco.
3. **Não misture** regra de negócio com detalhe de implementação no mesmo parágrafo.
4. **Pare e cite esta regra** se estiver prestes a pôr conteúdo na camada errada.

## Frontmatter (obrigatório em cada `.md` da KB)

```yaml
---
id: <kebab-case, único no domínio>
layer: business | tools | implementation | operations
domain: <nome-da-pasta-do-domínio>
content_type: concept | pattern | reference | spec | runbook | index | quick-reference
status: active | scaffolded | wip | deprecated | archived | unverified
related: []
size_exempt: true | false            # opcional — true = não sinalizar tamanho (advisory; ver abaixo)
# Proveniência (opcional; preenchida pela curadoria na camada tools/ — ver docs-first.md)
source: context7 | web | manual | null   # origem do conhecimento
lib_id: <id resolvido no context7> | null    # só quando source: context7
url: <URL da doc consultada> | null           # só quando source: web (fallback do docs-first)
checked_at: YYYY-MM-DD | null        # quando a doc foi verificada (context7 ou web)
# Proveniência de consolidação (opcional; preenchida pelo /reflect — ver reflection.md)
consolidates: []                     # ids que ESTA entrada absorveu (MERGE/COMPRESS)
supersedes: []                       # ids que ESTA entrada torna obsoletos (PRUNE)
# Proveniência de promoção (opcional; preenchida pelo /learn — ver lessons.md)
promoted_from: []                    # features (archive/<feature>/) cuja lição recorrente ESTA entrada promoveu
---
```

- `status: unverified` → gerada sem confirmação por doc atual (context7 indisponível **e** o
  fallback `WebSearch`/`WebFetch` também não achou fonte oficial — ver `docs-first.md`);
  reverificar quando alguma das duas fontes estiver disponível.
- `related` (opcional, lista de `id`) liga entradas que se referenciam → aresta `:RELATED_TO` do
  grafo unificado (H9). Cada `id` deve existir — `kb-lint` acusa `dangling-related` (**error**) se
  não (espelha `dangling-connection` do `agent-lint`). Distinto de `consolidates`/`supersedes`
  (apontam a ids removidos de propósito, não verificados como dangling).
- Campos de proveniência são **opcionais/retrocompatíveis**. `source: context7` **exige** `lib_id`
  + `checked_at` (`YYYY-MM-DD`); `source: web` (fallback do `docs-first.md` quando context7 falta
  ou a lib não resolve) **exige** `url` + `checked_at` no lugar de `lib_id`.
- `consolidates`/`supersedes` (listas de `id`) gravados pelo **`/reflect`**: a sobrevivente lista o
  que absorveu/tornou obsoleto — rastro verificado por `Test-ReflectProvenance` ([`reflection.md`](reflection.md)).
- `promoted_from` (lista de feature-slugs) gravado pelo **`/learn`** ao promover uma lição do
  `SHIPPED` a KB `operations` — torna a promoção rastreável e idempotente, verificado por
  `Test-LessonProvenance` ([`lessons.md`](lessons.md)).

## Caminho canônico

`.claude/kb/<camada>/<domínio>/<tipo>/<arquivo>.md` — ex.:
`.claude/kb/tools/sql/patterns/window-functions.md`. Não use layouts planos sem camada.

## Orçamento de tamanho (advisory)

Cada entrada tem um **orçamento de tamanho sugerido** (chars do corpo; ~4 chars/token) que mantém a
KB enxuta e previsível em tokens — uma entrada entra **inteira** no contexto. É **advisory**:
`tools/kb-lint.ps1` apenas **sinaliza** entradas acima (`OverBudget`) e **nunca** bloqueia nada (não
altera `Valid`, gate ou CI).

| `content_type` | Orçamento sugerido |
|----------------|--------------------|
| `quick-reference`, `index` | ~4 800 chars (~1 200 tok) |
| `concept`, `pattern`, `reference` | ~16 000 chars (~4 000 tok) |
| `runbook`, `spec` | ~32 000 chars (~8 000 tok) |

- **Código não conta:** fenced code blocks (```` ``` ````/`~~~`) são **excluídos** da contagem.
- **Acima do orçamento?** três saídas: (1) **dividir** em entradas atômicas; (2) **isentar** com
  `size_exempt: true` no frontmatter; (3) **aceitar** — nada bloqueia.
- Filosofia: **educar, não barrar** — o sinal mostra o custo×benefício; quem cura decide.
- O **mesmo princípio advisory** vale para o **contexto always-on** das `.claude/rules/` (não a KB):
  `tools/rules-budget.ps1` (G8) **mede e mostra** o footprint sempre-ativo (total + ranking por-arquivo),
  **sem teto/`%`** — é um retrato, não uma quota; nunca bloqueia. Distinto desta seção (que orça
  **entradas de KB**, carregadas sob demanda, com teto sugerido).

## Povoamento por ondas

O bootstrap da KB a partir do contexto é feito por **`/train-kb`** (feature **G3**): ele
deriva um **plano de ondas** em `.claude/kb/_waves/<NN>-<camada>-<domínio>.yaml` e executa
cada onda num subagente, gravando entradas conformes a este frontmatter. A camada `tools/`
aplica a regra [`docs-first.md`](docs-first.md). Validação automática do contrato em
`tools/kb-lint.ps1`.
