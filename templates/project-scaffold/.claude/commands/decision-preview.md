---
description: "Artifact comparando 2-4 variantes de uma decisão ainda aberta, com escolha explícita"
argument-hint: "<a decisão + as variantes a comparar>"
---

# /decision-preview — comparar variantes antes de construir

Gatilho **explícito** para a skill interna
[`decision-preview`](../skills/decision-preview/SKILL.md). Este arquivo é só o gatilho: **a fonte
única do procedimento é o `SKILL.md`** — ele não é repetido aqui.

> **Por que o command existe.** Medido no scaffold (20 queries × 3 execuções, projeto isolado): a
> skill é consultada por julgamento do modelo em **~10%** das vezes em que deveria. A postura
> [`artifact-first`](../rules/artifact-first.md) ensina *quando* vale o Artifact; o `/` garante que
> querer não dependa de o modelo lembrar.

## Processo
1. Carregue a skill `decision-preview` (tool `Skill`) e siga o workflow dela.
2. Decisão e variantes: `$ARGUMENTS`. Se vierem menos de 2 variantes, pergunte antes de gerar.
3. Grounding é **sempre real** (dados/tokens/código do projeto) — nunca placeholder inventado.

## Quando NÃO usar
- Explicar/revisar algo **já decidido** (diff, plano pronto) → `visual-explainer`, se instalada.
- **1 mockup** só, sem comparação → `artifact-design` direto.
