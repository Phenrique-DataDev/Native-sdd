# Orquestração — quando decompor

> O líder é o agente principal seguindo um protocolo, não um motor: delegar é a ferramenta `Agent`
> nativa. O protocolo (ciclo, gate, STATE, invariantes) e o **registro das medições** que sustentam
> os números abaixo vivem em [`../postures/orchestration.md`](../postures/orchestration.md), fora do
> always-on.

## Gatilho

**O default é não orquestrar.** Antes de decompor um objetivo, meça o regime:

```powershell
. "$toolsRoot/orchestrate.ps1"   # $toolsRoot pela cascata (rules/tooling.md)
Get-OrchestrationMode -Disciplines @('code','data') -FitsSingleContext $false
```

| `Mode` | O que fazer |
|--------|-------------|
| `solo` | Faça você, ou `Agent` direto ([`agent-routing.md`](agent-routing.md)). Sem STATE, sem gate. |
| `minimo` | Executor + 1 revisor fresh-context. Custa ~2,4× (~4× se o revisor também corrigir), por isso é **opt-in**: diga o preço e pergunte. O default sem resposta é `solo`. |
| `minimo+worktree` | Idem, com cada task concorrente no seu worktree e merge no fim. |
| `minimo+checkpoint` | Idem, com uma parada para o humano antes de cada ação outward (push, PR, deploy, envio). |
| `completo` | Rode o ciclo inteiro da postura. Só sai com `-ReductionAttempted $true`: o material não cabe num contexto **e** você escreveu a ferramenta que o reduziria e ela falhou. |

`-FitsSingleContext $false` sozinho é auto-relato, e a função devolve o modo barato com a instrução
na `Reason`: o que conta é a irredutibilidade, não o volume. Contar disciplinas não é fronteira.
Isolamento também não é: pede worktree, não máquina de estado.

Os sufixos compõem (`minimo+worktree+checkpoint`). Fora do `solo`, **leia a postura** antes do
primeiro passo; leia-a também ao retomar um `.claude/sdd/orchestration/STATE_*.yaml` (a retomada lê o
STATE, não a conversa). O `/orchestrate` roda este predicado no Passo 0. Pedido com a palavra
`ultracode` → `Workflow` nativo ([`../postures/max-mode.md`](../postures/max-mode.md) §(a)).
