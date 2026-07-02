---
description: "Loop bounded até o verde: itera uma meta verificável em sandbox, com circuit-breakers"
argument-hint: "<meta verificável> [--verifier '<cmd>']"
---

# /iterate — laço bounded "até o verde"

Martela uma **meta verificável por máquina** até o sinal objetivo passar — `RODAR → VERIFICAR →
RE-RODAR / PARAR` — **só na classe segura** (determinística + reversível), em **sandbox (`worktree`)**,
com **circuit-breakers** e a **fronteira mutador/outward intacta**. Protocolo na regra
[`iterative-loop.md`](../rules/iterative-loop.md). Sem engine: o **motor é o `Workflow` nativo**; o
**verificador é o `Test-TaskGate` reusado** ([`orchestration.md`](../rules/orchestration.md)).

> Distinto do `/orchestrate` (DAG de tasks com `MaxAttempts=2`): aqui é **uma** meta martelada
> **budget-bounded** num worktree. Distinto dos primitivos do harness `/loop`/`/goal`/`/batch`.

---

## Passo 0 — Resolver a camada `tools/`

Resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md) e carregue o tool (que
dot-source `orchestrate.ps1` para reusar o `Test-TaskGate`):

```powershell
. "$toolsRoot/iterate.ps1"
```

Sem `$toolsRoot` → **degradação consciente** (avisa, não quebra).

---

## Passo 1 — ELEGIBILIDADE

```powershell
$elig = Test-IterateEligible -Goal "<meta>" -Paths @(<globs que a meta toca>)
```

`Eligible = $false` → **STOP**: avise *"classe `$($elig.Class)` não entra no auto-loop — use o fluxo
normal (`/simulate` + humano para schema/IaC/dados; `/orchestrate` ou o loop principal para outward)"*.
**Não** abre loop.

---

## Passo 2 — VERIFICABILIDADE

```powershell
$ver = Test-IterateVerifiable -ProjectRoot . -Verifier "<cmd opcional>"
```

`Verifiable = $false` → **DEGRADA**: *"sem sinal verde/vermelho — adicione testes/lint ou itere à mão"*.
**Nunca** loop cego. Caso contrário, use `$ver.Verifier` (comando) e `$ver.Required` (critérios do gate).

---

## Passo 3 — CONDIÇÃO bem-formada

Monte a meta com os 4 componentes: **estado-final mensurável** + **prova de verificação** (o
`$ver.Verifier`) + **restrições** (out-of-scope) + **`max_iter`**. Grave o STATE inicial em
`.claude/sdd/iterate/STATE_<slug>.yaml` (`goal`/`verifier`/`required`/`max_iter`/`stuck_threshold`/
`streak_required`/`status: running`).

---

## Passo 4 — EMITIR o `Workflow` nativo (o laço)

Emita um **`Workflow`** com **`isolation:'worktree'`** (sandbox) e o **`budget`** do usuário (teto). A
stop-logic vive no **controller** (não editável pelo agente). Por volta:

1. `Agent` (contexto **fresco**) corrige **uma** coisa **dentro do worktree** (uma tarefa por volta).
2. `Get-VerifierResult -Verifier $ver.Verifier -Required $ver.Required` — **roda o verifier e mapeia
   exit-code → bool real** (fail-closed; crash/timeout/`exit 0` advisory → vermelho).
3. `Test-TaskGate -Result $r -Required $ver.Required` (+ `ReviewApproved` via `code-reviewer` se a meta
   toca **superfície sensível**). Grave a volta no STATE (`gate_passed`/`failed`).
4. `Test-StuckCondition` sobre o histórico de `Failed[]`.

Laço: `while !green_streak && !stuck && budget.remaining() && iter < max_iter`. O veredito vem do
**toolchain** (`Get-VerifierResult`), **nunca** do auto-report do modelo.

---

## Passo 5 — DESFECHO

```powershell
$state = Get-IterateState -StatePath .claude/sdd/iterate/STATE_<slug>.yaml
Format-IterateReport -State $state
```

- `success` (gate verde `streak_required`×) → **apresente o diff do worktree**; o **merge/aplicar é
  HUMANO** (fronteira — fora do loop). **Nunca** auto-merge.
- `failed` (stuck / `max_iter`) ou `budget-exceeded` → reporte o STATE e **escale** (não martele cego).

---

## Regras

- **Nunca** muta fora do worktree; **nunca** `push`/PR/schema/IaC/dados no auto-loop (fronteira
  [`max-mode`](../rules/max-mode.md) b/c, herdada).
- Sem sinal verificável → **degrada**; nunca loop cego.
- Veredito do **toolchain** (`Get-VerifierResult`), nunca auto-report do modelo.
- Stop-logic (`max_iter`/`budget`/stuck) no controller, **não** editável pelo agente.
- Sem engine — `Workflow` nativo + `Test-TaskGate` reusado (`tools/iterate.ps1`).
