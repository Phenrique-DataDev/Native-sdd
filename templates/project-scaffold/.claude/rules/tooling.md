# Tooling — resolver a camada `tools/` no projeto

> **Otimização / portabilidade.** Vários commands (e o hook `curation-nudge`) usam scripts
> determinísticos da camada **`tools/`** (`kb-lint`, `agent-lint`, `init`, `sync-context`,
> `telemetry`…). Eles **não** são copiados para o projeto; vivem no **framework**. Antes de
> dot-source de um `tools/*.ps1`, **resolva a raiz** pela cascata abaixo — assim os passos
> funcionam tanto na base quanto num projeto scaffolded, sem reimplementar a lógica.

## Princípio

A camada `tools/` é a metade **determinística** da metodologia (parsing de frontmatter,
inventários, gates) — o oposto de pedir ao modelo para improvisar. Mas no **projeto-alvo** o
`cwd` é o projeto e `tools/` não está presente por path relativo. Em vez de cada command adivinhar
onde estão os scripts, há **uma** cascata de resolução, definida aqui e referenciada por todos.

## A cascata (`$toolsRoot`)

Ordem de resolução — para na 1ª que existir:

| Ordem | Origem | Quando resolve |
|-------|--------|----------------|
| 1 | `tools/` **relativo** ao `cwd` | rodando na **base** do framework, ou num projeto que vendorizou `tools/` |
| 2 | `$env:SDD_WORKFLOW_HOME/tools` | **projeto-alvo** típico (a var é embutida pelo onboarding no `$PROFILE`) |
| 3 | — (nenhuma) | **degradação consciente**: avise e siga (o LLM faz à mão); **nunca** quebre |

Snippet canônico (use no início do bloco antes de dot-source de `tools/`):

```powershell
# Resolve a camada tools/ pela cascata (rules/tooling.md). Devolve $toolsRoot ou $null.
$toolsRoot =
  if     (Test-Path 'tools' -PathType Container)                                                             { 'tools' }
  elseif ($env:SDD_WORKFLOW_HOME -and (Test-Path (Join-Path $env:SDD_WORKFLOW_HOME 'tools') -PathType Container)) { Join-Path $env:SDD_WORKFLOW_HOME 'tools' }
  else   { $null }
if (-not $toolsRoot) { Write-Warning 'camada tools/ indisponivel — degradacao consciente (ver rules/tooling.md)' }
```

Depois, **com guarda**:

```powershell
if ($toolsRoot) {
    . "$toolsRoot/kb-lint.ps1" ; Get-KbInventory -Dir .claude/kb
} else {
    # degradação: faça a leitura/validação à mão e AVISE que foi sem a camada determinística
}
```

## Como aplicar

1. **Resolva `$toolsRoot`** com o snippet acima (a cascata, não um path fixo).
2. **Dot-source pela raiz resolvida:** `. "$toolsRoot/<script>.ps1"`. Os scripts ancoram as próprias
   dependências em `$PSScriptRoot` — resolver o entry-point basta; o resto segue junto.
3. **Sem `$toolsRoot`** (degrau 3) → **avise** o usuário ("camada `tools/` indisponível — reinstale o
   onboarding ou use `nsp`") e faça o passo à mão; **não** reimplemente em silêncio nem quebre.
4. **Não hardcode** `$env:SDD_WORKFLOW_HOME/tools` direto — a var pode faltar (spawn sem `$PROFILE`);
   é por isso que a cascata tenta o relativo primeiro e degrada por último.

## O que NÃO fazer

- Não escrever `. tools/<script>.ps1` **cru** (path relativo fixo) — não resolve no projeto-alvo.
  (Verificado por `tools/command-lint.ps1`: dot-source cru de `tools/` **bloqueia o CI**.)
- Não confundir com a **camada de KB `tools/`** (4ª camada da taxonomia, em `kb-taxonomy.md`) — é
  homônima, mas é conhecimento, não script.
- Não falhar quando a camada não resolve — a degradação consciente é o caminho normal fora do framework.
