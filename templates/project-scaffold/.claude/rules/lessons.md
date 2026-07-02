# Lessons — promover a lição recorrente à KB (postura · pull-only, opt-in)

> Boas práticas descobertas no **uso real** só viram valor quando **promovidas** a conhecimento
> reaplicável. O [`/ship`](../commands/ship.md) arquiva "Lições aprendidas" em `SHIPPED_*.md` — acervo que ninguém relê;
> a regra [`reflection.md`](reflection.md) (`/reflect`) **consolida** o que já está na KB (não capta novo). O `/learn` fecha o
> **loop de boas práticas**: relê o acervo, deixa o LLM detectar a lição **recorrente** (que se repete
> entre features) e a **promove** a uma entrada de KB `operations`. Acionado por **`/learn`**;
> **nunca-destrutivo** (plano → aprova → aplica), com **proveniência** (`promoted_from`). Sem engine: o
> base define o **contrato**; o julgamento é do LLM, o **gatilho** e a **verificação** são
> determinísticos (`tools/learn.ps1`, reusa o `kb-lint`/B7). Molde [`reflection.md`](reflection.md).

## Princípio

Validar a metodologia **só na cabeça de quem operou** não escala: a mesma prática é redescoberta a cada
ciclo. O `/learn` inverte isso — transforma o **aprendizado recorrente** em **prática consultável**: uma
lição vira *prática* quando se **repete** (≥2 features). O que decide *qual* lição é recorrente é
julgamento (LLM); o que torna a promoção **segura e rastreável** é o protocolo abaixo + a verificação de
proveniência. Destino é a KB camada `operations` (**não** uma rule sempre-ativa — mantém `rules/` enxuta
e reusa a infra de KB).

## O que é promovível

| Promove (sinal durável, reaplicável) | NÃO promove |
|--------------------------------------|-------------|
| **prática recorrente** (mesma lição em ≥2 features) | lição **pontual**/one-off de um ciclo só |
| "sempre rode X antes de Y" / "valide Z assim" (processo) | aprendizado já coberto pela KB factual (`/train-kb`) |
| armadilha técnica que se repete e tem mitigação clara | wording/nota efêmera sem padrão |

Insumo: cada lição no `SHIPPED` é marcada `[candidata]` (promovível) ou `[pontual]` (one-off) no
[`/ship`](../commands/ship.md). O gatilho conta as `[candidata]` **ainda não promovidas**.

## Pré-condição (acervo com candidatas)

A postura **só vale quando há lições candidatas acumuladas**. `tools/learn.ps1`
`Test-LessonsReady -ArchiveDir .claude/sdd/archive -KbDir .claude/kb` conta as `[candidata]` cujo
`feature` ainda **não** consta em nenhum `promoted_from` da KB; sob o limiar
(`$script:LearnMinCandidates`) → **no-op/silêncio** ("nada a promover"). Nunca age sozinho: é
**pull-only**, acionado por `/learn` (o `curation-nudge` só **avisa** quando o acervo acumula).

## Como aplicar (ciclo do `/learn`)

1. **Gatilho** — `Test-LessonsReady`: sob o limiar → **no-op**. Acima → segue.
2. **Por domínio** — agrupe as candidatas pendentes por domínio; fan-out via `Agent` (1 subagente por
   domínio, DNA das ondas do [`/train-kb`](../commands/train-kb.md)), contexto limitado.
3. **Detecção de recorrência** — o subagente identifica a lição que se **repete** (≥2 features) e propõe
   **1 entrada** `operations` (`content_type: runbook`), com `promoted_from: [features]`.
4. **Plano, não ação** — proponha um **plano** (`.claude/kb/_lessons/<data>-plan.md`): prática · entrada-alvo
   · `promoted_from` · rationale. Apresente e **peça aprovação**.
5. **Backup antes de gravar** — só após aprovação; faça backup de qualquer entrada afetada.
6. **Proveniência** — grave `promoted_from` na entrada criada (features de origem).
7. **Verifique** — `Test-LessonProvenance` (toda entrada promovida aponta feature existente) **e** o
   `kb-lint` (entrada `Valid`: frontmatter/camada/`content_type`/budget). Órfão/inválida → **reverter do
   backup** e avisar (não deixe pela metade).
8. **Reindexe** — rode `/sync-context` (G4) para o índice/ponteiros refletirem a nova entrada.

## O que NÃO fazer

- **Não** promover lição **pontual** (só o recorrente, ≥2 features) — vira ruído na KB.
- **Não** promover a **rule sempre-ativa** (`.claude/rules/`) — o destino é a KB `operations`.
- **Não** gravar sem `promoted_from`, sem **backup** ou sem **plano aprovado** — a postura é
  nunca-destrutiva; nada entra na KB **sem rastro** de origem.
- **Não** **repromover** o já promovido (feature em `promoted_from` é idempotente).
- **Não** escrever de volta no `SHIPPED`/`archive` — é histórico imutável (a proveniência mora na KB).
- **Não** promover entre **domínios** diferentes (MVP promove dentro do domínio).
- **Não** inventar recorrência sem ≥2 fontes; **não** construir engine/scoring — `Agent` nativo + a
  verificação determinística bastam.
