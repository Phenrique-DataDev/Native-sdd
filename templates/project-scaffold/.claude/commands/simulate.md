---
description: "Simular uma mudança/fix antes de aplicar (isolado, nunca-destrutivo)"
argument-hint: "<mudança ou fix a simular>"
---

# /simulate — simular antes de aplicar

Projeta o **resultado esperado** de uma mudança/fix **antes** de aplicá-la, num ambiente **isolado**,
e compara contra o baseline. **Nunca-destrutivo, nunca toca produção, nunca aplica.** Protocolo na
regra [`simulation.md`](../rules/simulation.md); a simulação real é um **simulador de domínio** gerado
pelo `/audit-agents` (G2).

> Distinto do `-DryRun` mecânico dos scripts: aqui o foco é o **resultado de domínio** (ex.: "como
> ficariam os dados pós-fix dbt"), não só "o que o script faria".

---

## Passo 0 — Capacidade

Resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md) e verifique se há um
simulador de domínio:

```powershell
. "$toolsRoot/simulate.ps1"
$cap = @(Get-SimulationCapability -Dir .claude/agents/domain)
```

**Sem capacidade** (`$cap` vazio) → **degradação consciente**: avise *"nenhum simulador para este
domínio — rode `/audit-agents` para gerar um (ex.: `dbt-simulator`)"* e **encerre**. **Não invente
números.**

---

## Passo 1 — PROPOR

Capture do usuário a **mudança/fix** concreto e o **alvo** (qual modelo/schema/recurso). Monte o
contexto: `project-context.md` + a KB do domínio (camadas `tools/`+`operations/`), se existir.

---

## Passo 2 — SIMULAR (fan-out)

**Fan-out** via ferramenta **`Agent`**: invoque o simulador de domínio (de `$cap`), passando a regra
`simulation.md` + o fix + o contexto. O simulador roda a ferramenta de **dry-run isolada** do domínio
(ex.: `dbt build --empty`/`--defer`/data-diff, `EXPLAIN`, `terraform plan`) — **nunca** produção.

---

## Passo 3 — COMPARAR + relatório

O simulador escreve `.claude/sdd/simulations/<data>-<slug>.md` com as **6 seções obrigatórias**
(`Baseline`/`Proposta`/`Resultado`/`Diff`/`Premissas`/`Isolamento`). O `Diff` carrega a comparação
resultado×baseline.

---

## Passo 4 — Conformidade

```powershell
$findings = @(Test-SimulationReportConforms -Text (Get-Content -Raw .claude/sdd/simulations/<arquivo>.md))
```

Há finding (`missing-section`/`isolation-not-declared`) → o relatório está **incompleto**; **avise e
não apresente os números** (resultado sem isolamento declarado não é confiável).

---

## Passo 5 — REPORTAR + DECIDIR

Apresente o **diff + resultados esperados + premissas**. **Encerre aqui — o `/simulate` nunca aplica.**
Aplicar a mudança é decisão humana, por outro fluxo (`/build` ou manual).

---

## Regras

- **Nunca aplica** a mudança; **nunca** toca produção/dado real (só dry-run/sandbox).
- Sem simulador → **degrada** (`/audit-agents`); nunca inventa números.
- Sempre declara **premissas** e **isolamento** no relatório.
- Sem engine — `Agent` nativo + conformidade determinística (`tools/simulate.ps1`).
