---
description: "Fase 1 SDD — capturar requisitos e critérios de aceite"
argument-hint: "<caminho do BRAINSTORM ou descrição>"
---

# /define — Fase 1 (Define)

Transformar a exploração em **requisitos verificáveis**.

## Antes de começar
- Leia o BRAINSTORM em `$ARGUMENTS` (se existir) e o template
  `.claude/sdd/templates/DEFINE_TEMPLATE.md`.
- Se não houver BRAINSTORM e os requisitos não estiverem claros, sugira `/brainstorm`.

## Produza
Gere `.claude/sdd/features/DEFINE_<FEATURE>.md` com:
- **Problema** (1–2 frases: quem sofre, qual o impacto)
- **Usuários-alvo** e suas dores
- **Goals** priorizados (`MUST` / `SHOULD` / `COULD`)
- **Success Criteria** mensuráveis (com números)
- **Acceptance Tests** (Given/When/Then)
- **Out of Scope**, **Constraints**, **Assumptions**
- **Clarity Score** (0–3 por: Problema, Usuários, Goals, Success, Scope)

## Gate
**Clarity Score mínimo: 12/15.** Abaixo disso, liste as lacunas e peça esclarecimento
antes de avançar — não vá para o DESIGN com requisitos vagos.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "Dá pra escrever os Acceptance Tests depois, no build" | Sem AT verificável agora, o BUILD não tem alvo — "pronto" vira opinião. Eles são o contrato. |
| "Success Criteria sem número é suficiente" | "Mais rápido" não é critério; "p95 < 200ms" é. Sem número não há como provar que atingiu. |
| "Clarity 11/15 é perto o bastante" | O gate é 12. Liste a lacuna e pergunte — não avance com requisito vago. |

## O que NÃO fazer

- Avançar para `/design` com Clarity Score abaixo de 12/15.
- Escrever Success Criteria sem número mensurável.
- Inventar requisito que o usuário não confirmou — pergunte.

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`):
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase define -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

**Próximo passo:** `/design .claude/sdd/features/DEFINE_<FEATURE>.md`
