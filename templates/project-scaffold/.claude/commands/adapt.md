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

### Se o repo já tem `.claude/` — modo absorção (automático, sem flag)

Quando `Test-AbsorptionApplicable -Root .` for `$true` (o repo-alvo já tem `.claude/` **não-
trivial**: ≥1 arquivo em `skills`/`agents`/`kb`/`rules`/`hooks`, ou `settings.json`, ou
`CLAUDE.md`/`AGENTS.md` na raiz), o `/adapt` **não** se limita a avisar — inventaria os ativos
contra o baseline do scaffold, sempre **preservando** o que já existe:

```text
$baseline = Resolve-AdaptBaselineRoot
if ($baseline) {
    $inventory    = Get-ClaudeAssetInventory -Root . -BaselineRoot $baseline
    $targetJson   = Get-Content .claude/settings.json -Raw -ErrorAction SilentlyContinue
    $baselineJson = Get-Content (Join-Path $baseline 'settings.json') -Raw -ErrorAction SilentlyContinue
    $settingsDiff = Compare-ClaudeSettingsKeys -TargetJson $targetJson -BaselineJson $baselineJson
    Format-AbsorptionReport -Inventory $inventory -SettingsDiff $settingsDiff
} else {
    # degradação consciente (rules/tooling.md): avisa e segue SEM a seção de absorção
    Write-Warning 'baseline do scaffold indisponível — reinstale o onboarding ou use nsp'
}
```

Cada ativo (`.claude/{skills,agents,kb,rules,hooks}` + `CLAUDE.md`/`AGENTS.md`) entra em um de 3
buckets — **`Additive`** (só no baseline — candidato a adicionar), **`Own`** (só no projeto —
preservado, nada a fazer) ou **`Conflict`** (nos dois lados, conteúdo diverge — **preservado**,
relatado lado a lado, decisão fica com o usuário depois). `settings.json` é comparado **por
chave** (`hooks.<Event>`, `permissions.<allow|deny|ask>`) pela mesma lógica, já que é JSON
estruturado, não arquivo solto.

Se `--report`/`--check`, **pare aqui** (a seção de absorção também é só diagnóstico).

---

## Passo 2 — Confirmar absorção dos itens `Additive` (só se houver algum)

Se o inventário tem ≥1 item `Additive`, peça **uma única confirmação em lote**
(`AskUserQuestion`): *"Detectei N itens do baseline ausentes no seu `.claude/` (liste). Adicionar
todos?"* → (a) adicionar todos · (b) não adicionar agora · (c) revisar manualmente depois.

Ao aceitar, rode `Add-AdditiveAssets -Root . -BaselineRoot $baseline -Inventory $inventory` — a
**única** função que escreve no repo-alvo neste passo, e só nos itens `Additive` (por construção
o destino não existe ainda nesses casos — nunca sobrescreve). **Itens `Own`/`Conflict` nunca são
tocados aqui**; `settings.json` nunca é escrito por este passo (só comparado — aplicar o merge de
`settings.json` é fora de escopo, ver `DEFINE_ABSORVER.md`).

Sem itens `Additive` (ou sem baseline resolvido), pule direto para o Passo 3.

---

## Passo 3 — Propor contexto + retro-ondas

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

## Passo 4 — Delegar a curadoria ao `/init`

Com o contexto gravado, **conduza o `/init`** (carregue a lógica de [`init.md`](init.md)). Ele é
adaptativo e resumível: roda `/audit-agents` → `/train-kb` → `/sync-context` com gate por etapa,
já lendo o contexto recém-preenchido. Opcional: mostre `Get-CurationStatus` antes/depois para
situar o progresso.

---

## Regras

- **Detecção read-only:** `Get-StackSignals`/`Get-ProjectHygiene`/`Get-ClaudeAssetInventory`/
  `Compare-ClaudeSettingsKeys` nunca escrevem no repo-alvo.
- **Contexto sob confirmação:** não gravar `project-context.md` sem o usuário aceitar.
- **Não reimplementar a curadoria:** delega ao `/init` (G1).
- **Retro-ondas são recomendações** (testes/CI/docs em falta) — corrigir é outra etapa.
- **Se o repo já tem `.claude/` não-trivial:** entra em modo absorção automaticamente (Passo 1),
  sem flag extra — inventaria e preserva, nunca sobrescreve em silêncio (ver seção acima).
- **Conflito nunca é resolvido automaticamente:** `Additive` só entra após confirmação em lote
  (Passo 2); `Own`/`Conflict` nunca são escritos por este comando.
- **`settings.json` nunca é escrito** por esta feature — só comparado por chave e reportado.
- `--report`/`--check` é **read-only**: só o diagnóstico (stack/higiene + absorção), sem gravar
  nem delegar.
