---
description: "Adota um projeto existente (brownfield) — detecta stack/higiene, propõe contexto e ondas retroativas, delega a curadoria ao /curate"
---

# /adapt — adotar um projeto existente (brownfield)

Adapta a metodologia a um repositório que **já estava em desenvolvimento**: **detecta** a
stack e a higiene (testes/CI/docs) a partir do que já existe, **propõe** o contexto do projeto
e as **ondas retroativas** para as lacunas, e **delega a curadoria ao `/curate`**. É o contraponto
do greenfield (`onboarding/new-project.ps1` + `/setup` do zero).

> Feature **G5** (EPIC G — curadoria/auto-otimização). O `/adapt` faz **só** o brownfield-
> específico (detecção + diagnóstico + proposta de contexto). A curadoria em si
> (`/audit-agents`→`/train-kb`→`/sync-context`) é do **`/curate`** (G1) — não reimplementada aqui.

---

## Uso

```text
/adapt            # diagnóstico → propõe contexto + retro-ondas → delega ao /curate
/adapt --report   # só o diagnóstico (stack + higiene + retro-ondas), read-only
```

---

## Passo 1 — Diagnóstico (read-only)

Carregue as funções e gere o relatório de estado:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/adapt.ps1"
$stack     = Get-StackSignals    -Root .
$workspace = Get-WorkspaceLayout -Root .
$hygiene   = Get-ProjectHygiene  -Root .
Format-AdaptReport -Stack $stack -Hygiene $hygiene -Workspace $workspace
```

- `Get-StackSignals` infere a stack por **presença de manifestos** (`pyproject.toml`,
  `package.json`, `dbt_project.yml`, `go.mod`, `*.csproj`, `Dockerfile`, `*.tf`, `schema.prisma`…;
  engine de jogo por `ProjectSettings/ProjectVersion.txt`, `project.godot`, `*.uproject`)
  — vazio se nada reconhecido (**não inventa**). Em repo git, lista pelo git e respeita o
  `.gitignore` (o `Library/` do Unity não vira `node`).
- `Get-WorkspaceLayout` reconhece **monorepo** (`pnpm-workspace.yaml`, `turbo.json` ou `workspaces`
  no `package.json` da raiz) e lista os pacotes um a um, com a stack de cada. Sem marcador, devolve
  `$null` e o relatório fica como antes. Num monorepo, o rascunho do Passo 3 descreve a stack **por
  pacote**, não uma linha só para o repo.
- `Get-ProjectHygiene` checa as 3 dimensões: **Testes · CI · Docs/convenções** (cada flag =
  existe ≥1 sinal).
- As funções são **read-only** — não tocam o repo.

### Se o repo já tem `.claude/` — modo absorção (automático, sem flag)

Quando `Test-AbsorptionApplicable -Root .` for `$true` (o repo-alvo já tem `.claude/` **não-
trivial**: ≥1 arquivo em `skills`/`agents`/`kb`/`rules`/`hooks`/`commands`, ou `settings.json`, ou
`CLAUDE.md`/`AGENTS.md` na raiz), o `/adapt` **não** se limita a avisar — inventaria os ativos
contra o baseline do scaffold, sempre **preservando** o que já existe:

```text
$baseline = Resolve-AdaptBaselineRoot
if ($baseline) {
    $inventory    = Get-ClaudeAssetInventory -Root . -BaselineRoot $baseline
    # os dois lados com o corte do perfil e o command de hook na forma nativa, como o scaffold entrega
    $targetJson   = ConvertTo-AdaptComparableSettings (Get-Content .claude/settings.json -Raw -ErrorAction SilentlyContinue)
    $baselineJson = ConvertTo-AdaptComparableSettings (Get-AdaptBaselineSettingsJson -Root . -BaselineRoot $baseline)
    $settingsDiff = Compare-ClaudeSettingsKeys -TargetJson $targetJson -BaselineJson $baselineJson
    Format-AbsorptionReport -Inventory $inventory -SettingsDiff $settingsDiff
} else {
    # degradação consciente (rules/tooling.md): avisa e segue SEM a seção de absorção
    Write-Warning 'baseline do scaffold indisponível — reinstale o onboarding ou use nsp'
}
```

Cada ativo (`.claude/{skills,agents,kb,rules,hooks,commands}` + `CLAUDE.md`/`AGENTS.md`) entra em
um de 3 buckets — **`Additive`** (só no baseline — candidato a adicionar), **`Own`** (só no projeto —
preservado, nada a fazer) ou **`Conflict`** (nos dois lados, conteúdo diverge — **preservado**,
relatado lado a lado, decisão fica com o usuário depois). Projeto criado pelo `new-project.ps1` tem
`.claude/.scaffold-manifest`: aí o que o perfil cortou ou o usuário removeu vira **`NotDelivered`**
(não é candidato, e não ofereça: quem sincroniza com o template é o `-Update`), e arquivo com os
bytes que o scaffold entregou conta como idêntico. `settings.json` é comparado **por
chave** (`hooks.<Event>`, `permissions.<allow|deny|ask>`) pela mesma lógica, já que é JSON
estruturado, não arquivo solto.

**Commands do projeto.** Para cada command próprio (`Own`) ou homônimo de um do scaffold
(`Conflict`), o relatório traz uma **proposta de mapeamento** (`Get-CommandMappingHint`, pelo nome):
*"aponta para a fase X: /spec"*, *"substituído por /review-diff"* ou *"sem equivalente"*. É só
proposta: o command do projeto **nunca** é reescrito nem apagado. Ao apresentar, diga ao usuário
quais aditivos do scaffold criariam um segundo caminho para o mesmo pedido (o `/review-diff` ao lado
de um `/review` próprio, por exemplo) e deixe-o tirar esses da confirmação do Passo 2.

Se `--report`/`--check`, **pare aqui** (a seção de absorção também é só diagnóstico).

---

## Passo 2 — Confirmar absorção dos itens `Additive` (só se houver algum)

Se o inventário tem ≥1 item `Additive`, peça **uma única confirmação em lote**
(`AskUserQuestion`): *"Detectei N itens do baseline ausentes no seu `.claude/` (liste). Adicionar
todos?"* → (a) adicionar todos · (b) não adicionar agora · (c) revisar manualmente depois.

Se o usuário tirou itens (os commands que duplicariam um do projeto, por exemplo), filtre antes:
`$inventory = @($inventory | Where-Object RelativePath -notin $excluidos)`.

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
   usuário). A seção `## Verificação` segue a regra do passo 4 do [`/setup`](setup.md): só entra
   comando rodado aqui, com a saída mostrada.
2. **Peça confirmação** (`AskUserQuestion`): *"Detectei {stack}. Gravar este contexto?"* →
   (a) aceitar e gravar · (b) ajustar antes · (c) cancelar.
3. Ao aceitar, **grave** o arquivo com o marcador `<!-- status: active -->`. **Nunca** grave
   sem confirmação — a detecção é heurística.
4. Apresente as **retro-ondas** (do relatório) como backlog de higiene das dimensões em falta
   (testes/CI/docs) — são **recomendações**, não correções automáticas.
   **Exceção do CI:** com `$hygiene.HasCI` falso, siga o passo 6 do [`/setup`](setup.md): ele mede
   com `Test-CiOfferApplicable` se a oferta cabe (remote no GitHub, fora de monorepo, stack sem
   credencial) e só então pergunta. Onde não cabe, a lacuna fica como recomendação, com o motivo.

---

## Passo 4 — Delegar a curadoria ao `/curate`

Com o contexto gravado, **conduza o `/curate`** (carregue a lógica de [`curate.md`](curate.md)). Ele é
adaptativo e resumível: roda `/audit-agents` → `/train-kb` → `/sync-context` com gate por etapa,
já lendo o contexto recém-preenchido. Opcional: mostre `Get-CurationStatus` antes/depois para
situar o progresso.

---

## Regras

- **Detecção read-only:** `Get-StackSignals`/`Get-ProjectHygiene`/`Get-ClaudeAssetInventory`/
  `Compare-ClaudeSettingsKeys` nunca escrevem no repo-alvo.
- **Contexto sob confirmação:** não gravar `project-context.md` sem o usuário aceitar.
- **Não reimplementar a curadoria:** delega ao `/curate` (G1).
- **Retro-ondas são recomendações** (testes/CI/docs em falta) — corrigir é outra etapa.
- **Se o repo já tem `.claude/` não-trivial:** entra em modo absorção automaticamente (Passo 1),
  sem flag extra — inventaria e preserva, nunca sobrescreve em silêncio (ver seção acima).
- **Conflito nunca é resolvido automaticamente:** `Additive` só entra após confirmação em lote
  (Passo 2); `Own`/`Conflict` nunca são escritos por este comando.
- **`settings.json` nunca é escrito** por esta feature — só comparado por chave e reportado.
- `--report`/`--check` é **read-only**: só o diagnóstico (stack/higiene + absorção), sem gravar
  nem delegar.
