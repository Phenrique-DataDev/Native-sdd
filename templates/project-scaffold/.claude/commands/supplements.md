---
description: "Repertório de suplementos — lista/instala por tema (escopo user, projeto ou local) e busca no marketplace"
disable-model-invocation: true
metadata:
  effect: machine
---

# /supplements — repertório de suplementos (descobrir + instalar)

Consulta o **repertório curado** de skills/plugins validados (manifesto único em
`tools/supplements.psd1`), **lista por tema** e **instala** sob demanda o que você escolher —
**opt-in**, por padrão **user-scoped** ("global dormente": fica disponível em todo projeto,
auto-ativa só no trabalho da categoria) e, com `--project`/`--local`, **só neste projeto**. Reusa o
**mesmo núcleo** do onboarding (`tools/supplements.ps1`); não duplica lógica.

> Mesma maquinaria do passo A2e do onboarding (`-ExtraPlugins -Themes`). O repertório é **curado**
> (validado à mão) — quem pesquisa o marketplace é o `find`, que é read-only e não o substitui.
> Instalação é **não-bloqueante** (falha = aviso).
>
> **Onboarding instala desabilitado; aqui instala habilitado.** O onboarding põe o repertório no
> disco com os plugins desligados, para o custo não entrar em toda sessão. Aqui o pedido é pontual,
> então o plugin nasce ligado. Plugin que já está instalado (e desabilitado) não se reinstala: ligue
> pelo `/plugin` (aba Installed) ou `/plugin enable <plugin>@<marketplace>`; o que tiver MCP termina
> em `/mcp`.

---

## Uso

```text
/supplements              # lista os temas disponíveis + entradas do repertório
/supplements design       # lista as entradas do tema 'design' e instala sob confirmação
/supplements reporting    # idem p/ 'reporting'
/supplements find dbt     # BUSCA nos marketplaces locais o que o repertório ainda NÃO cobre
/supplements design --project   # instala SÓ neste projeto (declarado no .claude/settings.json)
/supplements design --local     # só na sua máquina, neste projeto (settings.local.json, gitignored)
```

**Escopo — onde o suplemento passa a valer:**

| Escopo | Onde fica declarado | Quem herda |
|---|---|---|
| `user` (padrão) | `~/.claude` | você, em **todo** projeto ("global dormente") |
| `--project` | `.claude/settings.json` — **versionado** | o time, pelo `git pull` |
| `--local` | `.claude/settings.local.json` — gitignored | só você, só aqui |

`--project` é o que resolve *"quero isto neste projeto, não em todos"*: o repositório passa a
**declarar** o que usa, e quem clonar recebe junto.

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

## Passo 2b — `find <termo>`: o que existe fora do repertório (read-only)

O repertório é **curado** (validado à mão) e cobre uma fração do que há nos marketplaces. `find`
mostra a diferença — **lendo os marketplaces já baixados em disco**
(`~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json`), **sem rede**:

```powershell
$termo = $args   # ex.: 'dbt' — vários termos = OR (qualquer um basta)
Find-SupplementCandidate -Term $termo |
    Format-Table Status, Name, Author, Category, Marketplace -AutoSize
```

Cada hit vem classificado — e o `Status` é a resposta de curadoria, não decoração:

| Status | Significa | O que fazer |
|---|---|---|
| `candidato` | passou nos filtros automáticos | **julgar** contra as regras 1, 2 e 4 do `supplements.psd1` |
| `catalogado` | já está no repertório | instalar pelo tema (Passo 3) |
| `recusado` | já reprovado — traz `Rule` + `Reason` | **não repropor**; a decisão já existe |
| `sem-autor` | marketplace não declara `author` | reprova a regra 3 |

- **`candidato` não é aprovado.** As regras 1 (sem credencial), 2 (footprint de skill) e 4 (não
  sobrepor) exigem ler o que o plugin faz. A busca elimina o que já tem veredito; ela não decide.
- Nenhum marketplace em disco → lista vazia (não é erro). Para atualizar o que está em disco:
  `claude plugin marketplace update <id>` — esse passo é do usuário, precisa de rede.

### Instalar um hit do `find` (só no projeto, sob confirmação)

Um plugin que **está** no marketplace mas **não** no repertório pode entrar **neste projeto** —
nunca no global. `ConvertTo-SupplementSpec` aplica as três recusas que mantêm a curadoria de pé:

```powershell
$hit  = @(Find-SupplementCandidate -Term 'airflow')[0]
$conv = ConvertTo-SupplementSpec -Hit $hit -Scope project
if (-not $conv.Ok) { Write-Warning $conv.Reason; return }   # a recusa DIZ o porquê — leia p/ o usuário
$conv.Reason                                                 # o que NÃO foi julgado por ninguém
$summary = @{ Installed = 0; Skipped = 0; Warn = 0 }
# -Spec instala ESTA entrada em vez do catálogo — mesma execução (escopo, idempotência, não-bloqueante):
Invoke-SupplementsSetup -Summary $summary -Spec $conv.Spec -Scope project -ProjectPath (Get-Location).Path -DryRun
```

| Recusa | Por quê |
|---|---|
| `-Scope user` | o global é do repertório curado — para valer em todo projeto, entra no manifesto |
| hit `recusado` | já tem veredito (regra + motivo); reverter é editar o manifesto, não contornar aqui |
| hit `catalogado` | está no repertório: instale pelo tema, que carrega o `Reason` da curadoria |
| origem desconhecida | sem `owner/repo` o colega que clonar não resolve o marketplace |

> **Confirme com o usuário mostrando o `Reason` da conversão** — ele diz explicitamente que as
> regras 1, 2 e 4 **não foram verificadas por ninguém**. Instalar no projeto é assumir isso; é uma
> decisão de quem mantém o projeto, e por isso ela não escapa para o escopo global.

---

## Passo 3 — Instalar o escolhido (sob confirmação)

Confirme com o usuário **o que** instalar (um tema inteiro ou o repertório todo); só então execute.
A instalação é **não-bloqueante** (falha vira aviso) e **idempotente** (já instalado → pula):

```powershell
$scope   = 'user'          # 'project' com --project; 'local' com --local
$summary = @{ Installed = 0; Skipped = 0; Warn = 0 }
# Pré-visualize sem instalar:
Invoke-SupplementsSetup -Summary $summary -Themes $theme -Scope $scope -DryRun
# Após confirmação, instale de fato:
Invoke-SupplementsSetup -Summary $summary -Themes $theme -Scope $scope
"instalados=$($summary.Installed) pulados=$($summary.Skipped) avisos=$($summary.Warn)"
```

- `plugin` → `claude plugin marketplace add <Source> --scope <s>` + `claude plugin install <Name>@<Id> --scope <s>`.
  O marketplace **também** leva escopo: sem isso o projeto declararia um plugin cujo marketplace só
  a sua máquina conhece, e o clone do colega falha ao resolver.
- `skill` → caminho de baseline (`Install-BaselineItem`); em `-Scope project` o destino é
  `.claude/skills/` **do projeto**. Skill não tem escopo `local` (arquivo versionado) → aviso.
- Em `project`/`local`, "já instalado?" é lido do **settings do projeto**, não do `claude plugin
  details` — este responde "sim" para um plugin que está só no seu escopo `user`, e o projeto
  acabaria sem declarar nada.
- Requer o `claude` no PATH p/ entradas `plugin`; ausente → aviso com o comando manual (com escopo).

---

## O que NÃO fazer

- **Não** instalar sem confirmação do usuário (é outward: baixa de marketplace) — liste, confirme, instale.
- **Não** rodar `-Scope project` de outro diretório: o `claude` grava no **diretório atual** do
  processo. Sem entrar na raiz do projeto, a instalação vai para o lugar errado **e ainda reporta
  sucesso** (medido). O núcleo entra sozinho via `-ProjectPath`; se você chamar o `claude` na mão,
  entre você.
- **Não** duplicar o catálogo aqui — a fonte única é `tools/supplements.psd1`.
- **Não** dot-source cru `tools/...` — use a cascata `$toolsRoot` (`rules/tooling.md`).
- **Não** confundir `find` com o repertório: o repertório é **curado**; `find` é exploração
  read-only do marketplace. Novas entradas entram pelo manifesto, com o julgamento escrito junto.
- **Não** instalar direto o que o `find` achou — nem repropor um hit `recusado`: ele já tem veredito.
