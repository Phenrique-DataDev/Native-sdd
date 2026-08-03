---
description: "Líder/orquestrador — decompõe um objetivo em tasks, delega a subagentes via Agent nativo e valida cada resultado"
---

# /orchestrate — líder/orquestrador (handoff a subagentes com validação)

Dado um **objetivo** (ou um **plano aprovado**), o líder o decompõe em tasks, dá contexto a
subagentes via **`Agent` nativo**, **valida** cada resultado contra um gate e encadeia/paraleliza —
com estado **resumível**. Sem engine: `invocar/aguardar/paralelizar/resume` é o nativo.

> Feature **H2** (EPIC H — multi-agente & orquestração). O protocolo do líder vive na regra
> sempre-ativa [`orchestration.md`](../rules/orchestration.md); este comando o **aciona**. O gate e o
> estado são funções puras em `tools/orchestrate.ps1` (molde do `/init`, G1).

---

## Uso

```text
/orchestrate <objetivo>              # decompor → conduzir (invocar+validar+encadear) → estado resumível
/orchestrate --plan-only <objetivo>  # só decompor + relatório do estado (NÃO invoca Agent), read-only
```

---

## Passo 0 — Carregar o roteamento avançado (sob demanda)

O **grafo unificado** (`:USES_SKILL`/`:PRESUPPOSES`/`:IN_DOMAIN`) e o **contrato de hub** não estão no
contexto: vivem em [`.claude/postures/agent-routing-advanced.md`](../postures/agent-routing-advanced.md),
**fora** do always-on (custam 0 token em sessões que nunca orquestram). **Leia esse arquivo agora** —
é o que permite montar o pacote de contexto com o **expert + skill + KB certos** do domínio, em vez de
improvisar.

> Ausente/ilegível? **Avise** e siga com o núcleo (`rules/agent-routing.md` — catálogo de experts e
> política de modelo, sempre no ar): o roteamento **básico** não depende do avançado. Degradação
> **consciente e anunciada**, nunca silenciosa.

## Passo 1 — Decompor

Quebre o objetivo/plano aprovado em **tasks** (`id`, `title`, `dod`, `deps`, `model` sugerido) e grave
o **STATE** em `.claude/sdd/orchestration/STATE_<slug>.yaml` (schema na `orchestration.md`). Mostre o
painel:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/orchestrate.ps1"
$status = Get-OrchestrationStatus -StatePath ".claude/sdd/orchestration/STATE_<slug>.yaml"
Format-OrchestrationReport -Status $status
```

Se **`--plan-only`**, **pare aqui** (só o relatório — nada é invocado).

---

## Passo 2 — Conduzir (loop)

Enquanto `NextTask` não for `done`/`blocked`, para cada **`ReadyTask`** (deps todas `passed`):

1. **Pacote de contexto** — artefato da fase (passe o artefato anterior, `workflow-sdd`) + arquivos +
   o **DoD** como critério + o **modelo** sugerido.
2. **Invocar** — `Agent` com `subagent_type`, `prompt` = pacote, `model`. Tasks independentes prontas
   → **várias chamadas `Agent` na mesma mensagem** (paralelo). Para plano grande/independente, emita o
   **handoff externo**: *"plano aprovado, rode em novo chat com Opus 4.8"* (instrução ao humano, não
   chamada de ferramenta).

---

## Passo 3 — Validar (gate)

Monte o `Result` da task a partir de verificação **real** (testes/lint/conformidade) e, se quiser o
gate semântico, do veredito do **`code-reviewer`** (`ReviewApproved`):

```text
$gate = Test-TaskGate -Result @{ TestsGreen = $true; LintClean = $true; ArtifactConforms = $true; ReviewApproved = $true } `
                      -Required @('TestsGreen','LintClean','ArtifactConforms','ReviewApproved')
```

- **Passou** (`$gate.Passed`) → marque a task `passed` no STATE.
- **Falhou** → **re-invoque** o subagente com `$gate.Failed` como feedback, até `MaxAttempts = 2`;
  esgotado → marque `failed`.

---

## Passo 4 — Encadear / estado

Atualize o STATE e repita do Passo 2. Recalcule `Get-OrchestrationStatus`: dispare as novas
`ReadyTasks` (paralelo), até `NextTask = done` (ou `blocked`, se a cadeia travar). Retomar é
idempotente — tasks `passed` não são refeitas.

---

## Regras

- **Sem engine:** `invocar/aguardar/paralelizar/resume` é o `Agent` nativo — não construa motor.
- **Líder no nível principal:** sem subagente→subagente.
- **Gate read-only e conservador:** critério obrigatório ausente conta como falha; só avança se passa.
- **`--plan-only` não invoca `Agent`:** read-only, só o relatório.
- **Não inventar resultados:** o `Result` do gate vem de verificação real.
- **Destino:** subagente na sessão por padrão; handoff externo p/ plano grande/independente ou troca de chat.
