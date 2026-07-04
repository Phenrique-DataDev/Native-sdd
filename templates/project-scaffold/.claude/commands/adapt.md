---
description: "Adota um projeto existente (brownfield) — detecta stack/higiene, propõe contexto e ondas retroativas, delega a curadoria ao /init"
---

# /adapt — adotar um projeto existente (brownfield)

Adapta a metodologia a um repositório que **já estava em desenvolvimento**: **detecta** a
stack e a higiene (testes/CI/docs) a partir do que já existe, **propõe** o contexto do projeto
e as **ondas retroativas** para as lacunas, e **delega a curadoria ao `/init`**. É o contraponto
do greenfield (`onboarding/new-project.ps1` + `/setup` do zero).

> Feature **G5** (EPIC G — curadoria/auto-otimização). O `/adapt` faz **só** o brownfield-
> específico (detecção + diagnóstico + proposta de contexto). A curadoria em si
> (`/audit-agents`→`/train-kb`→`/sync-context`) é do **`/init`** (G1) — não reimplementada aqui.

---

## Uso

```text
/adapt            # diagnóstico → propõe contexto + retro-ondas → delega ao /init
/adapt --report   # só o diagnóstico (stack + higiene + retro-ondas), read-only
```

---

## Passo 1 — Diagnóstico (read-only)

Carregue as funções e gere o relatório de estado:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/adapt.ps1"
$stack   = Get-StackSignals   -Root .
$hygiene = Get-ProjectHygiene -Root .
Format-AdaptReport -Stack $stack -Hygiene $hygiene
```

- `Get-StackSignals` infere a stack por **presença de manifestos** (`pyproject.toml`,
  `package.json`, `dbt_project.yml`, `go.mod`, `*.csproj`, `Dockerfile`, `*.tf`…) — vazio se
  nada reconhecido (**não inventa**).
- `Get-ProjectHygiene` checa as 3 dimensões: **Testes · CI · Docs/convenções** (cada flag =
  existe ≥1 sinal).
- As funções são **read-only** — não tocam o repo.

Se `--report`, **pare aqui**.

---

## Passo 2 — Propor contexto + retro-ondas

1. A partir da **stack inferida**, monte um rascunho do `.claude/rules/project-context.md`
   (linguagem/runtime/dados/infra preenchidos com os sinais detectados; domínio fica para o
   usuário).
2. **Peça confirmação** (`AskUserQuestion`): *"Detectei {stack}. Gravar este contexto?"* →
   (a) aceitar e gravar · (b) ajustar antes · (c) cancelar.
3. Ao aceitar, **grave** o arquivo com o marcador `<!-- status: active -->`. **Nunca** grave
   sem confirmação — a detecção é heurística.
4. Apresente as **retro-ondas** (do relatório) como backlog de higiene das dimensões em falta
   (testes/CI/docs) — são **recomendações**, não correções automáticas.

---

## Passo 3 — Delegar a curadoria ao `/init`

Com o contexto gravado, **conduza o `/init`** (carregue a lógica de [`init.md`](init.md)). Ele é
adaptativo e resumível: roda `/audit-agents` → `/train-kb` → `/sync-context` com gate por etapa,
já lendo o contexto recém-preenchido. Opcional: mostre `Get-CurationStatus` antes/depois para
situar o progresso.

---

## Regras

- **Detecção read-only:** `Get-StackSignals`/`Get-ProjectHygiene` nunca escrevem no repo-alvo.
- **Contexto sob confirmação:** não gravar `project-context.md` sem o usuário aceitar.
- **Não reimplementar a curadoria:** delega ao `/init` (G1).
- **Retro-ondas são recomendações** (testes/CI/docs em falta) — corrigir é outra etapa.
- **Se o repo já tem `.claude/`:** avise e considere `onboarding/new-project.ps1` para
  espelhar/atualizar o scaffold antes de adaptar.
- `--report` é **read-only**: só o diagnóstico, sem gravar nem delegar.
