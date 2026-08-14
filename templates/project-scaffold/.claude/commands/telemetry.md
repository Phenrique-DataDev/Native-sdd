---
description: "Relatório de telemetria por fase SDD (iterações; duração quando medida)"
argument-hint: "(sem argumentos)"
---

# /telemetry — telemetria por fase (piloto B6)

Mostra o consolidado de **iterações por fase** do SDD — onde o re-trabalho se concentra. É
**read-only**: só lê o histórico e imprime o painel.

## Uso

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/telemetry.ps1"
Format-PhaseReport -Path .claude/sdd/telemetry.jsonl
```

## Como os dados entram

Cada fase SDD (`/brainstorm` … `/ship`) registra, **ao fechar**, as iterações que custou — via
`Add-PhaseIteration` num passo **opcional e não bloqueante** de cada comando. É o sinal mais
barato/útil; a **duração** é gravada só quando de fato medida
(`Add-PhaseMetric -DurationSeconds`). Apenas metadados (fase/feature/iterações) — **nunca**
conteúdo.

## Como ler

- `TotalIterations` / `AvgIterations` por fase = concentração de re-trabalho.
- **Pico no `/build`** costuma apontar `/define`/`/design` vagos → revisar a clareza *upstream*
  (o Clarity Score do `/define`, o gate do `/design`).
- Fases comparáveis ao longo de várias features = onde investir esforço de processo.

## Notas

- Arquivo: `.claude/sdd/telemetry.jsonl` (append-only). Ausente → painel "(sem dados)".
- Funções puras em `tools/telemetry.ps1` (`Get-PhaseReport` / `Format-PhaseReport`),
  determinísticas e read-only.
