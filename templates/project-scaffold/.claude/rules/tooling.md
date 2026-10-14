# Tooling — resolver a camada `tools/` no projeto

> Vários commands (e o hook `curation-nudge`) usam scripts determinísticos da camada **`tools/`**
> (`kb-lint`, `agent-lint`, `init`, `sync-context`, `telemetry`…). Eles **não** são copiados para o
> projeto; vivem no **framework**. Antes de dot-source de um `tools/*.ps1`, **resolva a raiz** pela
> cascata abaixo. O detalhe (StrictMode, como aplicar, o que não fazer) vive em
> [`../postures/tooling.md`](../postures/tooling.md), lido sob demanda.

## A cascata (`$toolsRoot`)

Ordem de resolução — para na 1ª que existir:

| Ordem | Origem | Quando resolve |
|-------|--------|----------------|
| 1 | `tools/` **relativo** ao `cwd` | rodando na **base** do framework, ou num projeto que vendorizou `tools/` |
| 2 | `$env:SDD_WORKFLOW_HOME/tools` | **projeto-alvo** típico (o onboarding grava a var no `$PROFILE`/rc **e** no `env` do `~/.claude/settings.json`) |
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

Depois, **com guarda**: `if ($toolsRoot) { . "$toolsRoot/<script>.ps1"; ... } else { <à mão, e avise> }`.
Nunca `. tools/<script>.ps1` cru — não resolve no projeto-alvo.

> **O dot-source liga o `Set-StrictMode` no escopo do chamador** — no seu shell, até o fim da sessão.
> Variável não atribuída passa a **lançar**. Se um passo quebrar logo depois de um dot-source,
> suspeite disto primeiro; **nunca** use `Set-StrictMode -Off`; para escopo limpo, subprocesso
> (`pwsh -NoProfile -File`). Detalhe na postura.
