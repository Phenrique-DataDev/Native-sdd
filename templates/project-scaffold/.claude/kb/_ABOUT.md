# KB — Base de conhecimento do projeto

> Conhecimento reutilizável do projeto, em **4 camadas**. Disciplina e frontmatter
> obrigatório em [`../rules/kb-taxonomy.md`](../rules/kb-taxonomy.md). O bootstrap automático
> a partir do contexto vem da curadoria (`/train-kb`, feature **G3**): ela deriva um plano de
> ondas em `_waves/` e popula as camadas; na `tools/`, usa docs atuais via context7
> ([`../rules/docs-first.md`](../rules/docs-first.md)), gravando proveniência no frontmatter.

## Camadas

| Pasta | Responde |
|-------|----------|
| `business/` | Regra de negócio / métrica (KPIs, glossário, políticas de produto) |
| `tools/` | Como a tecnologia funciona em geral (agnóstico de fornecedor) |
| `implementation/` | O que **nós** construímos/configuramos (schemas, IDs, URLs internas) |
| `operations/` | Como rodar / reiniciar / recuperar (runbooks, playbooks) |

## Caminho canônico

`.claude/kb/<camada>/<domínio>/<tipo>/<arquivo>.md`
— ex.: `.claude/kb/tools/sql/patterns/window-functions.md`.

## Criar uma entrada

Copie [`_TEMPLATE.md`](_TEMPLATE.md), preencha o frontmatter e salve na camada certa.
A KB começa **vazia** de propósito — o scaffold é *context-free*; ela se enche na curadoria.

## Consolidação (quando cresce)

A KB só **cresce** com `/train-kb`. Quando fica grande/redundante, **`/reflect`** (feature **G6**)
faz uma passada de consolidação (**MERGE/COMPRESS/PRUNE**) **preservando regras + casos**, de forma
**nunca-destrutiva** (plano → aprova → aplica) — disciplina em [`../rules/reflection.md`](../rules/reflection.md).
O plano e o ledger ficam em `_reflections/`; a proveniência (`consolidates`/`supersedes`) garante que
nada some sem rastro (verificado por `tools/reflect.ps1`). O `curation-nudge` avisa quando vale rodar.

## Lições aprendidas (loop de boas práticas)

A camada `operations/` também recebe **práticas promovidas** do acervo de `SHIPPED` pelo **`/learn`**
(feature **G7**): quando uma lição se **repete** entre features (marcada `[candidata]` no `/ship`), o
`/learn` a promove a uma entrada `operations` (**nunca-destrutivo**, plano → aprova → aplica), gravando
`promoted_from: [features]` como proveniência (verificado por `tools/learn.ps1`). O plano/ledger ficam em
`_lessons/`; disciplina em [`../rules/lessons.md`](../rules/lessons.md). O `curation-nudge` avisa quando o
acervo acumula candidatas.
