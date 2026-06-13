# /init — especializar o scaffold (orquestra a curadoria)

Conduz, num **fluxo único e guiado**, a cadeia de especialização do projeto:
**(0) `/setup`** (se ainda não inicializado) → **`/audit-agents`** (G2) → **`/train-kb`** (G3)
→ **`/sync-context`** (G4). Pede **aprovação entre cada etapa** e é **resumável**: pula o que
já foi feito.

> Feature **G1** (EPIC G — curadoria/auto-otimização). Distinção importante: o **`/setup`**
> preenche o **contexto** do projeto (`project-context.md`); o **`/init`** **especializa** o
> scaffold genérico nesse contexto, orquestrando os comandos da curadoria. O `/init` **não
> reimplementa** nada dos sub-comandos — ele os **conduz**, na ordem certa, com gates.

---

## Uso

```text
/init             # fluxo completo: status → (setup?) → audit-agents → train-kb → sync-context
/init --status    # só o painel de prontidão, sem executar nada
```

---

## Passo 0 — Painel de prontidão

Carregue as funções de status e mostre o estado atual:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/init.ps1"
Format-CurationReport (Get-CurationStatus -Root .)
```

`Get-CurationStatus` é **read-only** e reusa `Get-AgentInventory` (G2) e `Get-KbInventory`
(G3). O painel lista cada etapa (✓ concluída · • próxima · – pendente) e o **`NextStep`**.
Se `--status`, **pare aqui**.

---

## Passo 1 — Etapa 0 (condicional): `/setup`

Se `Status.ProjectInitialized` é **falso** (`project-context.md` ainda é `template`/tem
placeholders), **conduza o `/setup` primeiro** — carregue a lógica de
[`setup.md`](setup.md) e execute o wizard. Sem contexto não há o que especializar.

Ao terminar, **recompute** o status (`Get-CurationStatus`) antes de seguir. Se o projeto já
está inicializado, pule direto ao Passo 2.

---

## Passo 2 — G2: `/audit-agents`

1. **Prontidão:** `Test-CurationReadiness -Stage audit-agents -Status <status>` deve ser
   `$true` (exige projeto inicializado).
2. **Resumível:** se `Status.DomainAgents > 0`, ofereça **pular** (a curadoria de agentes já
   gerou algo) ou rodar de novo (`/audit-agents` é idempotente; `--regen` reconsidera os já
   gerados).
3. **Conduza** o [`/audit-agents`](audit-agents.md) (analisa o contexto, gera agentes de
   domínio nas lacunas).
4. **Gate** (`AskUserQuestion`): *"G2 concluído. Seguir para o `/train-kb`?"* →
   (a) seguir · (b) revisar/ajustar antes · (c) parar aqui.

---

## Passo 3 — G3: `/train-kb`

1. **Prontidão:** `Test-CurationReadiness -Stage train-kb -Status <status>` deve ser `$true`.
2. **Resumível:** se `Status.KbDomains > 0`, ofereça pular ou continuar (`/train-kb` é
   idempotente — não duplica entradas; só preenche lacunas).
3. **Conduza** o [`/train-kb`](train-kb.md) (deriva ondas e povoa a KB; camada `tools/` aplica
   `docs-first`/context7).
4. **Gate** (`AskUserQuestion`): *"G3 concluído. Seguir para o `/sync-context`?"* →
   (a) seguir · (b) revisar · (c) parar aqui.

---

## Passo 4 — G4: `/sync-context`

Sem gate rígido (G4 reflete o estado atual). **Conduza** o [`/sync-context`](sync-context.md)
para **fechar o loop**: regenera `AGENT_MAP.md` + `kb/_index.yaml` e atualiza as regiões
marcadas em `AGENTS.md`/`CLAUDE.md`. Depois, **gate** final: *"Curadoria sincronizada. Conferir
`git diff` (deve mostrar só índices/refs)?"*

---

## Passo 5 — Painel final

Recompute e mostre o estado:

```text
Format-CurationReport (Get-CurationStatus -Root .)
```

O ideal é `NextStep: done` (projeto inicializado + agentes de domínio + KB povoada + índices
sincronizados). Aponte o que ficou pendente, se houver.

---

## Idempotência e regras

- **Resumável:** o `/init` deriva o estado do repo a cada execução (`Get-CurationStatus`) e
  **não refaz** o que já está concluído — herda a idempotência de cada sub-comando.
- **Uma etapa por vez, na ordem** (`audit-agents` → `train-kb` → `sync-context`); o G4 depende
  do que G2/G3 produzem.
- **Aprovação entre etapas** (seguir / revisar / parar) — o usuário controla o ritmo e pode
  parar a qualquer momento sem deixar o projeto inconsistente.
- O `/init` **delega** aos comandos da curadoria; **não** reimplementa varredura, geração nem
  idempotência — só orquestra e reporta o estado.
- `--status` é **read-only**: só mostra o painel, não executa etapa nenhuma.
