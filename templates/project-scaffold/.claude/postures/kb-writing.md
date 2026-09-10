# KB — contrato de escrita (sob demanda)

> **Carregada sob demanda**, não always-on. A rule [`../rules/kb-taxonomy.md`](../rules/kb-taxonomy.md)
> guarda as **4 camadas** e o caminho canônico (o que vale para *ler* e *rotear*); este arquivo tem o
> contrato de quem **escreve** na KB — frontmatter obrigatório, orçamento de tamanho e povoamento por
> ondas. Leia-o antes de criar ou editar qualquer entrada. Numa sessão que não escreve na KB o custo
> é **0 token**.

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
# Proveniência de consolidação (opcional; preenchida pelo /reflect — ver commands/reflect.md)
consolidates: []                     # ids que ESTA entrada absorveu (MERGE/COMPRESS)
supersedes: []                       # ids que ESTA entrada torna obsoletos (PRUNE)
# Proveniência de promoção (opcional; preenchida pelo /learn — ver commands/learn.md)
promoted_from: []                    # features (archive/<feature>/) cuja lição recorrente ESTA entrada promoveu
enforced_by: none                    # o que REPROVA sem esta prática: lista de mecanismos, ou `none` DECLARADO
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
  que absorveu/tornou obsoleto — rastro verificado por `Test-ReflectProvenance` ([`/reflect`](../commands/reflect.md)).
- `promoted_from` (lista de feature-slugs) gravado pelo **`/learn`** ao promover uma lição do
  `SHIPPED` a KB `operations` — torna a promoção rastreável e idempotente, verificado por
  `Test-LessonProvenance` ([`/learn`](../commands/learn.md)).
- `enforced_by` gravado pelo **`/learn`** junto com `promoted_from`: **o que reprova sem a
  prática**. Uma entrada de KB é **prosa** — sem este campo, a prática coberta por teste e a que
  ninguém cobra ficam indistinguíveis para quem lê a KB seis meses depois. É a falha que esta
  metodologia batiza (*regra sem mecanismo*) aplicada ao próprio command que promove práticas.
  Verificado por `Test-LessonEnforcement` **só nas entradas recém-gravadas** — entrada antiga sem
  o campo continua válida (retrocompat por escopo, não por severidade abaixada).

  | Valor | Semântica |
  |-------|-----------|
  | lista de mecanismos (`[tools/tests/x.Tests.ps1, hooks/guard.ps1]`) | teste, lint, hook ou gate que **falha** sem a prática — nomeie o mecanismo, não "a suíte" |
  | `none` | **declarado**: nada cobra; a entrada é prosa e o leitor sabe disso |
  | chave ausente · `[]` | ❌ finding — a diferença entre *nada cobra* e *ninguém perguntou* é o valor inteiro do campo |

  > **`none` não é derrota.** Recusar a promoção sem mecanismo transformaria um command
  > nunca-destrutivo em gate — e faria o curador **inventar** um mecanismo para passar. Um `none`
  > honesto vale mais que um teste fabricado (mesma lógica do **`N/A` declarado** da seção
  > `Verificação por mutação` do `BUILD_REPORT_TEMPLATE`).

## Orçamento de tamanho (advisory)

Cada entrada tem um **orçamento de tamanho sugerido** (chars do corpo) que mantém a KB enxuta e
previsível em tokens — uma entrada entra **inteira** no contexto, e o hub do `/max` **injeta as
entradas do domínio** no pacote de cada task. É **advisory**: `tools/kb-lint.ps1` apenas **sinaliza**
entradas acima (`OverBudget`) e **nunca** bloqueia nada (não altera `Valid`, gate ou CI).

| `content_type` | Orçamento sugerido | Custo real |
|----------------|--------------------|------------|
| `quick-reference`, `index` | ~4 800 chars | **~2 200 tok** |
| `concept`, `pattern`, `reference` | ~16 000 chars | **~7 300 tok** |
| `runbook`, `spec` | ~32 000 chars | **~14 500 tok** — é MUITO; prefira dividir |

> **A conversão é ~2,2 chars/token, não os ~4 do senso comum** — este arquivo dizia 4 até 2026-07-13
> e **subestimava o custo real em ~1,8x**. Os 4 chars/token valem para **prosa em inglês**; conteúdo
> em português + markdown denso (tabelas, backticks, acentos) tokeniza muito pior. O valor foi
> **calibrado contra o `/context` real** de uma sessão e vive em **fonte única** (`ConvertTo-KbTokens`,
> em `tools/kb-lint.ps1`) — não o duplique em lugar nenhum.
>
> **Os tetos em chars não mudaram** — só o rótulo, que era falso. Um `runbook` no teto custa
> **~14 500 tok**: mais que várias rules always-on somadas. Se a entrada chegar perto disso,
> **dividir** costuma ser melhor que isentar.

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
aplica a regra [`docs-first.md`](../rules/docs-first.md). Validação automática do contrato em
`tools/kb-lint.ps1`.
