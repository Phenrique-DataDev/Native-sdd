---
description: "Loop bounded até o verde: itera uma meta verificável em sandbox, com circuit-breakers"
argument-hint: "<meta verificável> [--verifier '<cmd>']"
---

# /iterate — laço bounded "até o verde"

Martela uma **meta verificável por máquina** até o sinal objetivo passar — `RODAR → VERIFICAR →
RE-RODAR / PARAR` — **só na classe segura** (determinística + reversível), em **sandbox (`worktree`)**,
com **circuit-breakers** e a **fronteira mutador/outward intacta**. Sem engine: o **motor é o
`Workflow` nativo**; o **verificador é o `Test-TaskGate` reusado**
([`orchestration.md`](../rules/orchestration.md)).

> Distinto do `/orchestrate` (DAG de tasks com `MaxAttempts=2`): aqui é **uma** meta martelada
> **budget-bounded** num worktree.
>
> **Este command é a fonte única da postura** — não há rule sempre-ativa correspondente. O protocolo
> inteiro está aqui e carrega **sob demanda**.

---

## Princípio

O agente é *"deterministicamente medíocre num mundo indeterminístico"*: ruim por iteração, mas
**centenas de voltas × feedback verificável → convergem para a spec**. A potência inteira vem do
**sinal objetivo**: *"a saída é verificável por máquina? então faça loop"* — **sem** sinal,
persistência só **acelera o erro**. Por isso o `/orchestrate` limita `MaxAttempts=2` no caso geral;
aqui **relaxamos esse teto** — mas **só** na classe segura, e a segurança vem de **elegibilidade +
sandbox + circuit-breakers**, não de soltar guardas.

## Classes elegíveis (e o que NUNCA entra)

| Elegível (auto-loop) | NUNCA no auto-loop (fica no fluxo normal/humano) |
|----------------------|---------------------------------------------------|
| lint / format / type-fix | mudança de **schema** / migração de dados |
| "deixar a suíte verde" / corrigir testes | **IaC** (`terraform`/`helm`/k8s/cloudformation) |
| subir cobertura a X% | operação de **dados** (`DELETE`/`TRUNCATE`/prod) |
| migração guiada por erro de **compilador** | **outward**: `git push`/PR/release/deploy/browser/deep-research |

`Test-IterateEligible` (Passo 1) decide por **exclusão** (rejeita a classe proibida, nomeando-a). É uma
guarda **coarse** e honesta: a defesa real é **em camadas** — guarda + **humano confirma** a invocação +
mesmo um escape só muta um **worktree** descartável.

## Fora da classe elegível — use o primitivo nativo

O `/iterate` **é** um goal-based loop, restrito à classe segura e sandboxed; não substitui o `/goal`:

| Precisa de... | Primitivo nativo (fora do `/iterate`) |
|----------------|----------------------------------------|
| Só uma condição de parada verificável, sem exigir sandbox | `/goal` |
| Rodar num intervalo/cronograma (ex.: checar CI a cada 5 min) | `/loop` (local) ou `/schedule` (nuvem) |
| Recorrente + critério + fan-out, sem humano em tempo real | **proativo**: `/schedule` + `/goal` + `Workflow` |

## Circuit-breakers (o freio mecânico)

| Freio | Quem aplica |
|-------|-------------|
| **`budget`** (custo) | o **`Workflow` nativo** (hard ceiling do usuário) — **não** se inventa quota |
| **`max_iter`** | o controller do laço (teto de voltas) |
| **Stuck detection** | `Test-StuckCondition`: mesmo critério reprova N× consecutivas → **para e escala** |

> **Stop-logic no controller, NÃO editável pelo agente durante o loop** — senão o agente afrouxa o
> próprio critério. Estados terminais explícitos: `success` / `failed` / `budget-exceeded`.

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
  [`max-mode`](../postures/max-mode.md) b/c, herdada — **fonte única**, não recopiar).
- Sem sinal verificável → **degrada**; nunca loop cego (persistência sem verificação acelera o erro).
- Veredito do **toolchain** (`Get-VerifierResult`), nunca auto-report do modelo.
- Stop-logic (`max_iter`/`budget`/stuck) no controller, **não** editável pelo agente durante o laço.
- **Nunca auto-merge** ao final — apresente o diff; aplicar é decisão humana.
- **Não** relaxe o `MaxAttempts` **fora** da classe elegível — o teto de 2 do `/orchestrate` vale lá.
- **Não** comece num objetivo grande/vago — parta do critério mais simples e amplie após ver 1 rodada
  convergir ("começar complexo demais" é o erro mais comum em loop).
- **Não** force o `/iterate` para objetivo fora da classe segura só porque "parece" um loop — use o
  primitivo nativo certo (`/goal`/`/loop`/`/schedule`).
- Sem engine — `Workflow` nativo + `Test-TaskGate` reusado (`tools/iterate.ps1`).
