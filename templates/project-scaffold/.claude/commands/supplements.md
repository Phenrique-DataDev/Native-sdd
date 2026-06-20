---
description: "Repertório de suplementos — lista skills/plugins validados por tema e instala o escolhido (opt-in, user scope)"
---

# /supplements — repertório de suplementos (descobrir + instalar)

Consulta o **repertório curado** de skills/plugins validados (manifesto único em
`tools/supplements.psd1`), **lista por tema** e **instala** sob demanda o que você escolher —
**opt-in**, **user-scoped** ("global dormente": fica disponível em todo projeto, auto-ativa só no
trabalho da categoria). Reusa o **mesmo núcleo** do onboarding (`tools/supplements.ps1`); não
duplica lógica.

> Mesma maquinaria do passo A2e do onboarding (`-ExtraPlugins -Themes`). O repertório é **curado**
> (validado à mão), não um índice pesquisável. Instalação é **não-bloqueante** (falha = aviso).

---

## Uso

```text
/supplements              # lista os temas disponíveis + entradas do repertório
/supplements design       # lista as entradas do tema 'design' e instala sob confirmação
/supplements reporting    # idem p/ 'reporting'
```

---

## Passo 1 — Resolver o núcleo (cascata)

Resolva `$toolsRoot` pela cascata (`rules/tooling.md`): `tools/` relativo → `$env:SDD_WORKFLOW_HOME/tools`
→ degradação consciente. **Nunca** dot-source cru de `tools/` (o `command-lint` bloqueia o CI).

```powershell
$toolsRoot =
  if     (Test-Path 'tools' -PathType Container)                                                                  { 'tools' }
  elseif ($env:SDD_WORKFLOW_HOME -and (Test-Path (Join-Path $env:SDD_WORKFLOW_HOME 'tools') -PathType Container)) { Join-Path $env:SDD_WORKFLOW_HOME 'tools' }
  else   { $null }
if (-not $toolsRoot) { Write-Warning 'camada tools/ indisponível — reinstale o onboarding (rules/tooling.md)'; return }
. "$toolsRoot/supplements.ps1"     # já dot-source onboarding/windows/lib.ps1 via $PSScriptRoot
```

---

## Passo 2 — Listar o repertório (read-only)

Sem tema, mostre **os temas** e as entradas; com tema, filtre:

```powershell
$theme   = $args   # ex.: 'design' (vazio = todos)
$catalog = Get-SupplementCatalog -Theme $theme
$catalog | Sort-Object Theme, Name | Format-Table Theme, Type, Name, Reason -AutoSize
```

- `Get-SupplementCatalog` lê o manifesto único e devolve `{ Type; Name; Source; Id; Theme; Reason }`.
- Tema inexistente → **lista vazia** (sem erro): avise e mostre os temas disponíveis
  (`(Get-SupplementCatalog).Theme | Sort-Object -Unique`).

---

## Passo 3 — Instalar o escolhido (sob confirmação)

Confirme com o usuário **o que** instalar (um tema inteiro ou o repertório todo); só então execute.
A instalação é **não-bloqueante** (falha vira aviso) e **idempotente** (já instalado → pula):

```powershell
$summary = @{ Installed = 0; Skipped = 0; Warn = 0 }
# Pré-visualize sem instalar:
Invoke-SupplementsSetup -Summary $summary -Themes $theme -DryRun
# Após confirmação, instale de fato:
Invoke-SupplementsSetup -Summary $summary -Themes $theme
"instalados=$($summary.Installed) pulados=$($summary.Skipped) avisos=$($summary.Warn)"
```

- `plugin` → `claude plugin marketplace add <Source>` + `claude plugin install <Name>@<Id>`.
- `skill` → caminho de baseline (`Install-BaselineItem`) — projetado; populado quando houver skill
  standalone vendorizada.
- Requer o `claude` no PATH p/ entradas `plugin`; ausente → aviso com o comando manual.

---

## O que NÃO fazer

- **Não** instalar sem confirmação do usuário (é outward: baixa de marketplace) — liste, confirme, instale.
- **Não** duplicar o catálogo aqui — a fonte única é `tools/supplements.psd1`.
- **Não** dot-source cru `tools/...` — use a cascata `$toolsRoot` (`rules/tooling.md`).
- **Não** tratar como índice pesquisável — o repertório é **curado**; novas entradas entram no manifesto.
