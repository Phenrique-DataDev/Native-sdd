# Iterative loop — laço bounded "até o verde" (postura · pull-only, opt-in)

> Para a classe **determinística + reversível + machine-verifiable** (lint/format/type-fix, "deixar a
> suíte verde", subir cobertura, migração guiada por compilador), **martelar a meta até o sinal
> objetivo passar** converge — e é desperdício parar em 2 tentativas. Esta postura captura o ganho
> "Ralph" **só onde o risco é baixo**, em **sandbox (`worktree`)**, com **circuit-breakers** e a
> **fronteira mutador/outward intacta**. Acionado por **`/iterate <meta>`**. Sem engine: o **motor é o
> `Workflow` nativo** (loop-until-green + `budget` + `isolation:'worktree'`); o **verificador é o
> `Test-TaskGate` reusado** ([`orchestration.md`](orchestration.md)). Molde
> [`simulation.md`](simulation.md)/[`max-mode.md`](max-mode.md).

## Princípio

O agente é *"deterministicamente medíocre num mundo indeterminístico"*: ruim por iteração, mas
**centenas de voltas × feedback verificável → convergem para a spec**. A potência inteira vem do
**sinal objetivo**: *"a saída é verificável por máquina? então faça loop"* — **sem** sinal, persistência
só **acelera o erro**. Por isso o `/orchestrate` limita `MaxAttempts=2` no caso geral; aqui **relaxamos
esse teto** — mas **só** na classe segura, e a segurança vem de **elegibilidade + sandbox +
circuit-breakers**, não de soltar guardas.

## Onde o `/iterate` fica na taxonomia de loops do harness

O Claude Code reconhece 4 tipos de loop, por como disparam e como param (Anthropic, *"Getting started
with loops"*, 2026-06): **turn-based** (manual, o próprio agente decide quando parar), **goal-based**
(`/goal`, para quando a condição de sucesso passa ou o teto de tentativas estoura), **time-based**
(`/loop`/`/schedule`, dispara por intervalo/cron) e **proactive** (combina os anteriores + `Workflow` +
auto mode, sem humano em tempo real por rodada).

O `/iterate` **é** um goal-based loop — só que **restrito à classe segura** (determinística/reversível/
machine-verifiable, ver abaixo) e **sandboxed** (`isolation:'worktree'`). Não substitui o `/goal` nativo
de propósito geral; é a instância **com guardrails extras** para "martelar até o verde". Quando o
objetivo **não** cabe na classe elegível — precisa de ação outward, precisa rodar em cronograma, ou
atravessa sessões — **não force** o `/iterate`; use o primitivo nativo direto:

| Precisa de... | Primitivo nativo (fora do `/iterate`) |
|----------------|----------------------------------------|
| Só uma condição de parada verificável, sem exigir sandbox | `/goal` |
| Rodar num intervalo/cronograma (ex.: checar CI a cada 5 min) | `/loop` (local) ou `/schedule` (nuvem) |
| Recorrente + critério + fan-out, sem humano em tempo real | **proativo**: `/schedule` + `/goal` + `Workflow` + auto mode |

A **fronteira de segurança** (mutador/outward fica no loop principal, sob humano — ver abaixo) vale
igual para os primitivos nativos: usar `/goal`/`/loop` direto **não dispensa** a mesma cautela para
ação outward/mutadora; o `/iterate` só formaliza essa fronteira **dentro** da classe segura.

## Classes elegíveis (e o que NUNCA entra)

| Elegível (auto-loop) | NUNCA no auto-loop (fica no fluxo normal/humano) |
|----------------------|---------------------------------------------------|
| lint / format / type-fix | mudança de **schema** / migração de dados |
| "deixar a suíte verde" / corrigir testes | **IaC** (`terraform`/`helm`/k8s/cloudformation) |
| subir cobertura a X% | operação de **dados** (`DELETE`/`TRUNCATE`/prod) |
| migração guiada por erro de **compilador** | **outward**: `git push`/PR/release/deploy/browser/deep-research |

`tools/iterate.ps1` `Test-IterateEligible` decide por **exclusão** (rejeita a classe proibida, nomeando-a).
É uma guarda **coarse** e honesta: a defesa real é **em camadas** — guarda + **humano confirma** a
invocação + mesmo um escape só muta um **worktree** descartável.

## Pré-condição (sinal verde/vermelho presente)

A postura **só vale quando há um verificador** (suíte/lint que produz verde/vermelho).
`Test-IterateVerifiable` detecta o sinal (ou aceita `-Verifier` explícito); **sem** ele → **degradação
total**: o `/iterate` **não abre loop** (orienta adicionar testes ou iterar à mão). Loop sem verificação
é o anti-padrão que esta postura existe para evitar.

## O ciclo RODAR → VERIFICAR → RE-RODAR / PARAR

| Passo | O que acontece |
|-------|----------------|
| **RODAR** | `Agent` (contexto **fresco**) corrige **uma** coisa **dentro do worktree** (uma tarefa por volta). |
| **VERIFICAR** | `Get-VerifierResult` **roda** o verifier e **mapeia exit-code → bool real** (fail-closed) → `Test-TaskGate -Required <crit>`. O veredito vem do **toolchain**, **nunca** do auto-report do modelo. |
| **RE-RODAR** | gate reprovou → re-invoca com o `Failed[]` como feedback (igual `/orchestrate`). |
| **PARAR** | gate verde **N× consecutivos** (quality streak) → `success`; ou **stuck**/`max_iter`/`budget` → `failed`/`budget-exceeded` + escala. |

## Circuit-breakers (o freio mecânico)

| Freio | Quem aplica |
|-------|-------------|
| **`budget`** (custo) | o **`Workflow` nativo** (hard ceiling derivado da diretiva do usuário) — **não** se inventa quota |
| **`max_iter`** | o controller do laço (teto de voltas) |
| **Stuck detection** | `Test-StuckCondition`: mesmo critério reprova N× consecutivas → **para e escala** (não martela cego) |

> **Stop-logic no controller, NÃO editável pelo agente durante o loop** — senão o agente afrouxa o
> próprio critério. Estados terminais explícitos: `success` / `failed` / `budget-exceeded`.

## Fronteira de segurança (link vivo — não recopiar)

O auto-loop **herda a fronteira do [`max-mode`](max-mode.md) (b)/(c)**: muta **só dentro do
`isolation:'worktree'`** (sandbox); **fora** do worktree o fan-out segue **não-mutador/não-outward**. O
**merge** do worktree de volta à branch de trabalho — e qualquer `git push`/PR — **fica no loop
principal, sob olhar humano**. Assim o laço converge no **sandbox** e o **irreversível continua humano**.
(`max-mode` é a fonte única da fronteira — esta regra **referencia**, não copia, para não divergir.)

## O que NÃO fazer

- **Não** rodar loop **sem sinal verificável** (degrada) — persistência sem verificação acelera o erro.
- **Não** mutar **fora** do worktree; **nunca** `push`/PR/schema/IaC/dados no auto-loop (fronteira intacta).
- **Não** deixar o **modelo auto-reportar** "está verde" — o veredito é do `Get-VerifierResult`/toolchain.
- **Não** deixar a stop-logic (`max_iter`/`budget`/stuck) **editável pelo agente** durante o laço.
- **Não** **auto-merge** ao final — apresentar o diff; aplicar é decisão humana.
- **Não** construir engine/daemon — o motor é o `Workflow` nativo; o gate é o `Test-TaskGate` reusado.
- **Não** relaxar o `MaxAttempts` **fora** da classe elegível — o teto de 2 do `/orchestrate` continua valendo lá.
- **Não** comece o `/iterate` num objetivo grande/vago — parta do critério mais simples possível e só
  amplie após ver 1 rodada convergir (o próprio harness aponta "começar complexo demais" como o erro
  mais comum em loop).
- **Não** force o `/iterate` para objetivo fora da classe segura só porque "parece" um loop — use o
  primitivo nativo certo (`/goal`/`/loop`/`/schedule`, ver taxonomia acima).
