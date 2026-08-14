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
- **Acceptance Tests** (Given/When/Then) — ver o critério de falsificabilidade abaixo
- **Out of Scope**, **Constraints**, **Assumptions**
- **Clarity Score** (0–3 por: Problema, Usuários, Goals, Success, Scope)

## Acceptance Test precisa ser falsificável

Um AT que **não tem como reprovar** não é critério, é descrição. Ao escrever cada um, responda:
*"o que teria que estar quebrado para este AT falhar?"* — se a resposta for "nada óbvio" ou "o
sistema inteiro", o AT está vago demais para o BUILD ter alvo.

**Predicado — quando isto é obrigatório:** o AT descreve **comportamento executável** (função,
endpoint, script, comando, saída observável). Aí ele carrega o **Falsificador**: a condição concreta
sob a qual reprova. É esse campo que o `/build` reintroduz na verificação por mutação.

**Quando não se aplica:** AT sobre redação, documentação, estrutura de arquivo ou decisão registrada.
Escreva `N/A` no Falsificador e diga o que verifica no lugar (lint que lê o arquivo, revisão humana).
`N/A` **declarado** é honesto; campo vazio é ambíguo.

| ID | Cenário | Given/When/Then | Falsificador — reprova se… |
|----|---------|-----------------|-----------------------------|
| AT-001 | {happy path} | {…} | {ex.: "a validação de `email` for removida"} |
| AT-002 | {doc/redação} | {…} | `N/A` — {o que verifica no lugar} |

## Gate
**Clarity Score mínimo: 12/15.** Abaixo disso, liste as lacunas e peça esclarecimento
antes de avançar — não vá para o DESIGN com requisitos vagos.

**Todo AT de comportamento executável precisa de Falsificador preenchido** (ou `N/A` justificado).
AT sem ele volta para reescrita: sem saber o que o reprova, o `/build` não tem como provar que o
cobriu — e o teste que ele escrever vai passar de qualquer jeito.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "Dá pra escrever os Acceptance Tests depois, no build" | Sem AT verificável agora, o BUILD não tem alvo — "pronto" vira opinião. Eles são o contrato. |
| "Success Criteria sem número é suficiente" | "Mais rápido" não é critério; "p95 < 200ms" é. Sem número não há como provar que atingiu. |
| "Clarity 11/15 é perto o bastante" | O gate é 12. Liste a lacuna e pergunte — não avance com requisito vago. |
| "O Falsificador é óbvio, o BUILD deduz na hora" | Se fosse óbvio, custava 5 segundos escrever. O que o BUILD deduz sozinho é o que o **código** faz — e é exatamente esse o teste que passa com o bug reintroduzido. |
| "Este AT não tem como falhar, é bom sinal" | É o contrário: AT que não reprova sob nenhuma condição não mede nada. Reescreva até ter uma condição concreta de falha. |

## O que NÃO fazer

- Avançar para `/design` com Clarity Score abaixo de 12/15.
- Escrever Success Criteria sem número mensurável.
- Inventar requisito que o usuário não confirmou — pergunte.
- Deixar o **Falsificador** vazio num AT de comportamento executável — `N/A` só vale declarado
  e justificado, para AT de doc/redação/estrutura.

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`):
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase define -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

**Próximo passo:** `/design .claude/sdd/features/DEFINE_<FEATURE>.md`
