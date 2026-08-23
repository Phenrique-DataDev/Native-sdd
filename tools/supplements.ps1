<#
.SYNOPSIS
    Núcleo (puro + I/O fino) do repertório de suplementos opt-in — fonte ÚNICA lida pelo
    onboarding (install-plugins.ps1 / apply.ps1) e pelo command /supplements do scaffold.

.DESCRIPTION
    Lê o manifesto de DADOS (tools/supplements.psd1) e decide/executa a instalação por tema,
    roteando por Type (plugin -> claude plugin; skill -> baseline de lib.ps1). Espelha o molde
    A8/install-mcp: catálogo puro + plano puro + setup NÃO-BLOQUEANTE (falha = WARN, A1/A2 intactos).

      Get-SupplementCatalog  -> [pscustomobject[]]  { Type; Name; Source; Id; Theme; Reason }  (filtrável por -Theme)
      Get-SupplementPlan     -> [pscustomobject]    { Action 'add'|'skip'|'warn'; Route 'plugin'|'baseline'; Steps; Reason }
      Invoke-SupplementsSetup-> (efeito) executa o plano do catálogo filtrado; nunca lança.

    Reusa onboarding/windows/lib.ps1 (Test-CommandExists, Write-Step, Install-BaselineItem,
    Get-BaselineMap) — não reimplementa instalação/espelhamento. Determinismo: ordenação do manifesto
    preservada; sem datas no conteúdo.
#>

Set-StrictMode -Version Latest

# Reuso da infra do instalador (Test-CommandExists/Write-Step/Install-BaselineItem/Get-BaselineMap).
. (Join-Path $PSScriptRoot '..\onboarding\windows\lib.ps1')
# Reuso do I1 (/update-skills) p/ o Route='baseline' (Type=skill) — mesma infra de espelhamento
# usada pra atualizar skills já instaladas, aqui pra INSTALAR pela 1ª vez (Get-SkillUpdatePlan
# devolve diff vs local; skill nova = local ausente = todo o conteúdo entra no plano).
. (Join-Path $PSScriptRoot 'update-skills.ps1')

function Get-SupplementManifestPath {
    <# .SYNOPSIS Caminho do manifesto (DADOS) ao lado deste script. #>
    [CmdletBinding()]
    param([string]$ManifestPath)
    if ($ManifestPath) { return $ManifestPath }
    return (Join-Path $PSScriptRoot 'supplements.psd1')
}

function Get-SupplementCatalog {
    <#
    .SYNOPSIS
        Lê o manifesto e devolve as entradas (opcionalmente filtradas por tema).
    .PARAMETER Theme
        Lista de temas p/ filtrar (case-insensitive). Vazio/ausente = TODAS. Sem match = @().
    .OUTPUTS
        [pscustomobject[]] cada um { Type; Name; Source; Id; Theme; Reason }. Entradas com
        algum dos 6 campos vazio são PULADAS (com Write-Warning) — não derrubam o catálogo.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Theme = @(),
        [string]$ManifestPath
    )

    $path = Get-SupplementManifestPath -ManifestPath $ManifestPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Warning "supplements: manifesto não encontrado em '$path'"
        return @()
    }

    $data = Import-PowerShellDataFile -LiteralPath $path
    $raw = @()
    if ($data.ContainsKey('Supplements')) { $raw = @($data.Supplements) }

    $required = 'Type', 'Name', 'Source', 'Id', 'Theme', 'Reason'
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $raw) {
        # 'Id' pode ser vazio só p/ skill; os demais 5 são sempre obrigatórios.
        $missing = @($required | Where-Object {
                $_ -ne 'Id' -and ([string]::IsNullOrWhiteSpace([string]$e[$_]))
            })
        if ($e['Type'] -eq 'plugin' -and [string]::IsNullOrWhiteSpace([string]$e['Id'])) {
            $missing += 'Id'
        }
        if ($missing.Count -gt 0) {
            Write-Warning "supplements: entrada '$($e['Name'])' pulada — campo(s) vazio(s): $($missing -join ', ')"
            continue
        }
        $out.Add([pscustomobject]@{
                Type   = [string]$e['Type']
                Name   = [string]$e['Name']
                Source = [string]$e['Source']
                Id     = [string]$e['Id']
                Theme  = [string]$e['Theme']
                Reason = [string]$e['Reason']
            })
    }

    $items = $out.ToArray()
    if (-not $Theme -or $Theme.Count -eq 0) { return $items }

    $wanted = @($Theme | ForEach-Object { $_.ToLowerInvariant() })
    return @($items | Where-Object { $wanted -contains $_.Theme.ToLowerInvariant() })
}

function Get-SupplementPlan {
    <#
    .SYNOPSIS
        Decide (puro) o que fazer com UMA entrada, a partir do ambiente. Roteia por Type.
    .PARAMETER Scope
        'user' (padrão — "global dormente": vale em todo projeto), 'project' (declarado no
        `.claude/settings.json` do projeto, VERSIONADO: o time herda pelo git) ou 'local'
        (`.claude/settings.local.json`, gitignored: só a sua máquina, naquele projeto).
        Escopo é do `claude` desde sempre (`--scope`); o que faltava era este wrapper passar.
        Type=skill não tem escopo 'local' — arquivo de skill é versionado por natureza; pedir
        'local' para skill dá WARN em vez de instalar no lugar errado em silêncio.
    .OUTPUTS
        [pscustomobject] @{ Action='add'|'skip'|'warn'; Route='plugin'|'baseline'; Steps; Reason }
        - plugin/add: Steps = [0] marketplace add <Source> ; [1] install <Name>@<Id> (ambos com --scope).
        - skill/add:  Steps = @() (o Item de baseline é montado pelo Invoke).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Spec,
        [bool]$ClaudePresent = $false,   # gate do Type=plugin
        [bool]$BaselinePresent = $true,  # gate do Type=skill (origem no baseline)
        [bool]$AlreadyInstalled = $false,
        [ValidateSet('user', 'project', 'local')][string]$Scope = 'user'
    )

    if ($Spec.Type -eq 'skill') {
        if ($Scope -eq 'local') {
            return [pscustomobject]@{
                Action = 'warn'; Route = 'baseline'; Steps = @()
                Reason = "skill '$($Spec.Name)' não tem escopo 'local' — arquivo de skill vive em .claude/skills/ e é versionado; use -Scope project (ou user)"
            }
        }
        if (-not $BaselinePresent) {
            return [pscustomobject]@{
                Action = 'warn'; Route = 'baseline'; Steps = @()
                Reason = "origem da skill '$($Spec.Name)' ausente no baseline — pulei (vendorize a skill p/ instalar)"
            }
        }
        if ($AlreadyInstalled) {
            return [pscustomobject]@{
                Action = 'skip'; Route = 'baseline'; Steps = @()
                Reason = "$($Spec.Name) já instalada (skill, $Scope scope)"
            }
        }
        return [pscustomobject]@{
            Action = 'add'; Route = 'baseline'; Steps = @()
            Reason = "instalar skill $($Spec.Name) [$Scope] — $($Spec.Reason)"
        }
    }

    # Type = plugin
    if (-not $ClaudePresent) {
        return [pscustomobject]@{
            Action = 'warn'; Route = 'plugin'; Steps = @()
            Reason = "Claude Code (claude) ausente — pulei $($Spec.Name); instale depois com: claude plugin marketplace add $($Spec.Source) --scope $Scope ; claude plugin install $($Spec.Name)@$($Spec.Id) --scope $Scope"
        }
    }
    if ($AlreadyInstalled) {
        return [pscustomobject]@{
            Action = 'skip'; Route = 'plugin'; Steps = @()
            Reason = "$($Spec.Name) já instalado (plugin, $Scope scope)"
        }
    }
    # O marketplace TAMBÉM leva --scope: sem isso o projeto declara `enabledPlugins` apontando p/ um
    # marketplace que só a máquina de quem instalou conhece, e o clone do colega falha ao resolver.
    $steps = @(
        , @('plugin', 'marketplace', 'add', $Spec.Source, '--scope', $Scope)
        , @('plugin', 'install', "$($Spec.Name)@$($Spec.Id)", '--scope', $Scope)
    )
    return [pscustomobject]@{
        Action = 'add'; Route = 'plugin'; Steps = $steps
        Reason = "instalar $($Spec.Name) [$Scope] — $($Spec.Reason)"
    }
}

function Get-SupplementSkillsBaselineRoot {
    <# .SYNOPSIS Raiz vendorizada das skills de suplemento (Type=skill) — SEPARADA de
       templates/global-claude (essa é espelhada por INTEIRO em todo install.ps1; a de
       suplemento só entra via este módulo, opt-in). #>
    [CmdletBinding()]
    param()
    return (Join-Path $PSScriptRoot '..\templates\supplements\skills')
}

function Invoke-SupplementsSetup {
    <#
    .SYNOPSIS
        Executa o plano de cada entrada do catálogo filtrado (wrapper com efeito colateral).
        Nunca lança; qualquer falha = WARN (não bloqueante, A1/A2 intactos).
    .PARAMETER Themes
        Filtro de temas (vazio = todos).
    .PARAMETER HomePath
        Raiz do HOME do usuário (destino de Type=skill em -Scope user: <HomePath>/.claude/skills).
        Parametrizável p/ teste (Pester aponta a um TestDrive em vez de $env:USERPROFILE real).
    .PARAMETER Scope
        'user' (padrão, comportamento histórico), 'project' ou 'local'. Em project/local o destino
        de Type=skill passa a ser <ProjectPath>/.claude/skills.
    .PARAMETER ProjectPath
        Raiz do projeto (usada só quando -Scope project|local). Padrão: diretório atual.
    .PARAMETER Spec
        Entradas a instalar EM VEZ do catálogo — o caminho de um hit do `find` convertido por
        ConvertTo-SupplementSpec. Existe para o command não reimplementar a execução (marketplace
        add + install + escopo + idempotência) só porque a origem da entrada é outra.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [string[]]$Themes = @(),
        [string]$ManifestPath,
        [string]$HomePath = $env:USERPROFILE,
        [ValidateSet('user', 'project', 'local')][string]$Scope = 'user',
        [string]$ProjectPath = (Get-Location).Path,
        [pscustomobject[]]$Spec,
        [switch]$Check,
        [switch]$DryRun
    )

    $claudePresent = Test-CommandExists 'claude'
    $scopeIsProject = ($Scope -ne 'user')

    # Guarda ANTES de qualquer plano — e vale também em -DryRun/-Check de propósito. `--scope
    # project|local` grava no CWD do processo: sem projeto real, o pré-visualizado ("instalaria
    # aqui") seria mentira, e a execução gravaria onde o script estivesse rodando. Foi assim que a
    # suíte, durante uma mutação em 2026-08-11, instalou um plugin no repositório do framework.
    if ($scopeIsProject -and -not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        Write-Step WARN "supplements: projeto '$ProjectPath' não existe — escopo '$Scope' precisa de um diretório de projeto real; nada feito"
        $Summary.Warn++
        return
    }

    $catalog = if ($Spec) { @($Spec) } else { Get-SupplementCatalog -Theme $Themes -ManifestPath $ManifestPath }
    if (@($catalog).Count -eq 0) {
        Write-Step INFO "supplements: nenhum suplemento para o(s) tema(s) '$($Themes -join ', ')'"
        return
    }

    # Route='baseline' (Type=skill): plano ÚNICO p/ todas as skills do catálogo (reuso do I1),
    # filtrado por skill dentro do loop — evita recomputar o Get-BaselineMap por entrada.
    $skillsBaselineRoot = Get-SupplementSkillsBaselineRoot
    # Destino da skill segue o escopo: user = HOME (global dormente); project = a pasta que o
    # scaffold JÁ usa p/ skills do projeto (.claude/skills, versionada).
    $skillsLocalRoot = if ($Scope -eq 'user') { Join-Path $HomePath '.claude\skills' }
    else { Join-Path $ProjectPath '.claude\skills' }
    $skillsPlan = @(Get-SkillUpdatePlan -BaselineRoot $skillsBaselineRoot -LocalRoot $skillsLocalRoot)

    foreach ($spec in $catalog) {
        # "Já instalado?" (read-only) — plugin via 'claude plugin details'; skill via SKILL.md local.
        $already = $false
        $baselinePresent = $true
        if ($spec.Type -eq 'plugin' -and $scopeIsProject) {
            # `claude plugin details` NÃO distingue escopo: medido em 2026-08-11, ele responde 0 num
            # diretório limpo para um plugin instalado só em USER. Usá-lo aqui daria 'skip' e o
            # projeto nunca declararia nada — a instalação de projeto sumiria em silêncio. A
            # pergunta certa em escopo de projeto é outra: "este projeto DECLARA o plugin?", e a
            # resposta está no settings do próprio projeto (é o que o git carrega p/ o time).
            $already = Test-PluginDeclaredInProject -ProjectPath $ProjectPath -Name $spec.Name -Id $spec.Id -Scope $Scope
        }
        elseif ($spec.Type -eq 'plugin' -and $claudePresent) {
            try {
                claude plugin details $spec.Name 2>&1 | Out-Null
                $already = ($LASTEXITCODE -eq 0)
            }
            catch { $already = $false }
        }
        elseif ($spec.Type -eq 'skill') {
            $baselinePresent = Test-Path -LiteralPath (Join-Path $skillsBaselineRoot $spec.Source) -PathType Container
            $already = Test-Path -LiteralPath (Join-Path $skillsLocalRoot $spec.Name 'SKILL.md') -PathType Leaf
        }

        $plan = Get-SupplementPlan -Spec $spec -ClaudePresent $claudePresent -BaselinePresent $baselinePresent -AlreadyInstalled $already -Scope $Scope

        switch ($plan.Action) {
            'skip' { Write-Step SKIP "suplemento: $($plan.Reason)"; $Summary.Skipped++ }
            'warn' { Write-Step WARN "suplemento: $($plan.Reason)"; $Summary.Warn++ }
            'add' {
                if ($plan.Route -eq 'plugin') {
                    if ($Check) {
                        Write-Step INFO "suplemento [$($spec.Theme)]: $($plan.Reason)"
                    }
                    elseif ($DryRun) {
                        foreach ($step in $plan.Steps) { Write-Step DRY "claude $($step -join ' ')" }
                    }
                    else {
                        $ok = $true
                        # `--scope project|local` grava no CWD DO PROCESSO, não num caminho que o
                        # comando receba. Sem entrar no diretório, o e2e de 2026-08-11 gravou o
                        # settings.json no repositório do framework e ainda assim reportou
                        # "instalado (project scope)" — sucesso relatado, projeto vazio. Por isso o
                        # Push-Location: é a diferença entre instalar e parecer que instalou.
                        $entrou = $false
                        if ($scopeIsProject) {
                            Push-Location -LiteralPath $ProjectPath   # existência já garantida na entrada
                            $entrou = $true
                        }
                        try {
                            foreach ($step in $plan.Steps) {
                                try {
                                    claude @step 2>&1 | Out-Null
                                    if ($LASTEXITCODE -ne 0) {
                                        Write-Step WARN "suplemento: 'claude $($step -join ' ')' retornou $LASTEXITCODE — instale manualmente depois"
                                        $ok = $false; break
                                    }
                                }
                                catch {
                                    Write-Step WARN "suplemento: falha ao instalar $($spec.Name) — $($_.Exception.Message)"
                                    $ok = $false; break
                                }
                            }
                        }
                        finally { if ($entrou) { Pop-Location } }
                        if ($ok) {
                            Write-Step OK "suplemento instalado: $($spec.Name) [$($spec.Theme)] ($Scope scope)"
                            $Summary.Installed++
                        }
                        else { $Summary.Warn++ }
                    }
                }
                else {
                    # Route='baseline' (Type=skill): copia os arquivos da skill (Get-SkillUpdatePlan
                    # já filtra p/ os que diferem do local — skill nova = tudo) via Install-BaselineItem,
                    # que já sabe fazer Check/DryRun/backup por arquivo (I1) — sem motor novo aqui.
                    $items = @($skillsPlan | Where-Object { $_.Skill -eq $spec.Name })
                    if ($items.Count -eq 0) {
                        Write-Step WARN "suplemento: skill $($spec.Name) sem arquivos a copiar do baseline — pulei"
                        $Summary.Warn++
                    }
                    else {
                        foreach ($item in $items) { Install-BaselineItem -Item $item -Summary $Summary -Check:$Check -DryRun:$DryRun }
                        if (-not $Check -and -not $DryRun) {
                            Write-Step OK "suplemento instalado: $($spec.Name) [$($spec.Theme)] ($Scope scope, skill)"
                        }
                    }
                }
            }
        }
    }
}

# ── Descoberta (read-only) — o marketplace que o catálogo NÃO enxerga ─────────────────────────────
# O catálogo acima é CURADO (15 entradas). O marketplace oficial tinha 285 plugins em 2026-08-10 e
# cresce sozinho: nada aqui olhava para ele, então ampliar a curadoria era `jq` na mão. As funções
# abaixo leem os marketplaces JÁ BAIXADOS pelo Claude Code (~/.claude/plugins/marketplaces/*) — é
# leitura de DISCO, não de rede: offline, determinística e testável com fixture. Ausência do
# diretório (nunca rodou `claude plugin marketplace add`) NÃO é erro: devolve vazio e quem chama avisa.
# Atualizar o que está em disco continua sendo do usuário: `claude plugin marketplace update <id>`.

function Get-MarketplaceRoot {
    <# .SYNOPSIS Raiz dos marketplaces baixados pelo Claude Code (parametrizável p/ teste). #>
    [CmdletBinding()]
    param([string]$HomePath = $env:USERPROFILE)
    return (Join-Path $HomePath '.claude\plugins\marketplaces')
}

function Get-MarketplacePluginIndex {
    <#
    .SYNOPSIS
        Índice (I/O fino, read-only) dos plugins de TODOS os marketplaces locais.
    .DESCRIPTION
        Lê <root>/<id>/.claude-plugin/marketplace.json. Raiz ausente = @() (sem erro): a máquina
        pode nunca ter adicionado marketplace nenhum. JSON ilegível = Write-Warning e segue para o
        próximo — um marketplace corrompido não derruba a busca inteira.
    .OUTPUTS
        [pscustomobject[]] { Name; Description; Author; Category; Marketplace } — ordenado por
        Marketplace, Name (determinismo: a ordem não depende do filesystem).
    #>
    [CmdletBinding()]
    param(
        [string]$HomePath = $env:USERPROFILE,
        [string]$MarketplaceRoot
    )

    $root = if ($MarketplaceRoot) { $MarketplaceRoot } else { Get-MarketplaceRoot -HomePath $HomePath }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $json = Join-Path $dir.FullName '.claude-plugin\marketplace.json'
        if (-not (Test-Path -LiteralPath $json -PathType Leaf)) { continue }
        # -AsHashtable NÃO é preferência de estilo: o marketplace oficial real (285 plugins) NÃO
        # desserializa sem ele — a chave 'renames' tem entradas que só diferem no casing ('.c'/'.C')
        # e o ConvertFrom-Json em modo objeto lança ("keys with different casing"). Medido em
        # 2026-08-10 no primeiro uso contra o arquivo real; fixture nenhuma teria pego isso.
        try { $data = Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
        catch {
            Write-Warning "supplements: marketplace '$($dir.Name)' ilegível — $($_.Exception.Message)"
            continue
        }
        if (-not ($data -is [System.Collections.IDictionary]) -or -not $data.Contains('plugins')) { continue }
        foreach ($p in @($data['plugins'])) {
            if (-not ($p -is [System.Collections.IDictionary])) { continue }
            $author = ''
            if ($p.Contains('author') -and $p['author']) {
                $a = $p['author']
                $author = if ($a -is [string]) { $a }
                elseif (($a -is [System.Collections.IDictionary]) -and $a.Contains('name')) { [string]$a['name'] }
                else { '' }
            }
            $out.Add([pscustomobject]@{
                    Name        = [string]$p['name']
                    Description = if ($p.Contains('description')) { [string]$p['description'] } else { '' }
                    Author      = $author
                    Category    = if ($p.Contains('category')) { [string]$p['category'] } else { '' }
                    Marketplace = $dir.Name
                })
        }
    }
    return @($out | Sort-Object Marketplace, Name)
}

function Get-SupplementRejection {
    <#
    .SYNOPSIS
        Recusas já decididas (chave 'Rejected' do manifesto) — para a busca não propor de novo.
    .OUTPUTS
        [pscustomobject[]] { Name; Rule; Reason }. Manifesto sem a chave = @().
    #>
    [CmdletBinding()]
    param([string]$ManifestPath)

    $path = Get-SupplementManifestPath -ManifestPath $ManifestPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }

    $data = Import-PowerShellDataFile -LiteralPath $path
    if (-not $data.ContainsKey('Rejected')) { return @() }

    return @(@($data.Rejected) | ForEach-Object {
            [pscustomobject]@{
                Name   = [string]$_['Name']
                Rule   = [int]$_['Rule']
                Reason = [string]$_['Reason']
            }
        })
}

function Find-SupplementCandidate {
    <#
    .SYNOPSIS
        Busca (PURA) nos marketplaces locais e classifica cada hit contra o catálogo e as recusas.
    .DESCRIPTION
        Casa o termo (case-insensitive, substring) em Name + Description + Category. Vários termos
        = OR (qualquer um basta). Cada hit recebe um Status, que é a resposta de curadoria:

          catalogado  já está em supplements.psd1 — nada a fazer
          recusado    já reprovado (traz Rule + Reason da recusa) — NÃO propor de novo
          sem-autor   marketplace não declara author: reprova a regra 3 do critério de admissão
          candidato   passou nos filtros automáticos — falta o julgamento humano (regras 1, 2 e 4)

        'candidato' NÃO quer dizer aprovado: as regras 1 (credencial), 2 (footprint) e 4 (sobreposição)
        exigem ler o que o plugin faz. A busca elimina o que já tem veredito; ela não decide.
    .PARAMETER Term
        Termos a procurar. Sem termo = todos os plugins do índice (útil p/ inventário).
    .OUTPUTS
        [pscustomobject[]] { Status; Name; Author; Category; Marketplace; Description; Rule; Reason }
        ordenado por Status (candidato → sem-autor → recusado → catalogado) e Name.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Term = @(),
        [pscustomobject[]]$Index,
        [pscustomobject[]]$Catalog,
        [pscustomobject[]]$Rejected,
        [string]$HomePath = $env:USERPROFILE,
        [string]$ManifestPath
    )

    if ($null -eq $Index) { $Index = @(Get-MarketplacePluginIndex -HomePath $HomePath) }
    if ($null -eq $Catalog) { $Catalog = @(Get-SupplementCatalog -ManifestPath $ManifestPath) }
    if ($null -eq $Rejected) { $Rejected = @(Get-SupplementRejection -ManifestPath $ManifestPath) }

    $catalogados = @{}
    foreach ($c in @($Catalog)) { $catalogados[$c.Name.ToLowerInvariant()] = $true }
    $recusados = @{}
    foreach ($r in @($Rejected)) { $recusados[$r.Name.ToLowerInvariant()] = $r }

    $termos = @(@($Term) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() })

    $ordem = @{ 'candidato' = 0; 'sem-autor' = 1; 'recusado' = 2; 'catalogado' = 3 }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($Index)) {
        if ($termos.Count -gt 0) {
            $agulha = "$($p.Name) $($p.Description) $($p.Category)".ToLowerInvariant()
            $bate = $false
            foreach ($t in $termos) { if ($agulha.Contains($t)) { $bate = $true; break } }
            if (-not $bate) { continue }
        }

        $chave = $p.Name.ToLowerInvariant()
        $status = 'candidato'; $rule = 0; $reason = ''
        if ($catalogados.ContainsKey($chave)) {
            $status = 'catalogado'; $reason = 'já está no catálogo curado'
        }
        elseif ($recusados.ContainsKey($chave)) {
            $status = 'recusado'; $rule = $recusados[$chave].Rule; $reason = $recusados[$chave].Reason
        }
        elseif ([string]::IsNullOrWhiteSpace($p.Author)) {
            $status = 'sem-autor'; $rule = 3; $reason = 'marketplace não declara author — reprova a regra 3'
        }

        $out.Add([pscustomobject]@{
                Status      = $status
                Name        = $p.Name
                Author      = $p.Author
                Category    = $p.Category
                Marketplace = $p.Marketplace
                Description = $p.Description
                Rule        = $rule
                Reason      = $reason
            })
    }
    return @($out | Sort-Object @{ Expression = { $ordem[$_.Status] } }, Name)
}

# ── Escopo de projeto — o que o projeto usa é decisão do projeto ─────────────────────────────────
# O catálogo é curado e user-scoped de propósito ("global dormente"). Isso não responde por quem
# precisa de algo só num projeto: até 2026-08-11 o wrapper instalava SEMPRE em user, sem parâmetro.
# A trava era nossa — `claude plugin install|marketplace add` tem `--scope user|project|local` desde
# antes. Medido em 2026-08-11: project grava `.claude/settings.json` (VERSIONADO — o time herda pelo
# git); local grava `.claude/settings.local.json` (gitignored). Ambos com `enabledPlugins` +
# `extraKnownMarketplaces`. Não é preciso manifesto de projeto nenhum: o registro do que o projeto
# usa já é o settings dele, lido pelo próprio harness — e `Merge-JsonObject` (instalador) usa o
# destino como base, então reinstalar/resync NÃO apaga o que só o projeto declara.

function Get-ProjectSettingsPath {
    <# .SYNOPSIS Arquivo de settings do escopo: project = settings.json; local = settings.local.json. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [ValidateSet('project', 'local')][string]$Scope = 'project'
    )
    $nome = if ($Scope -eq 'local') { 'settings.local.json' } else { 'settings.json' }
    return (Join-Path $ProjectPath (Join-Path '.claude' $nome))
}

function Test-PluginDeclaredInProject {
    <#
    .SYNOPSIS
        O projeto DECLARA este plugin? (lê `enabledPlugins` do settings do escopo)
    .DESCRIPTION
        Substitui `claude plugin details` quando o escopo é project/local. Medido em 2026-08-11:
        `details` responde 0 para plugin instalado só em USER, mesmo num diretório limpo — usá-lo
        aqui daria 'skip' e o projeto nunca declararia nada, a instalação sumiria em silêncio.
        Arquivo ausente/ilegível = $false (não declarado), nunca exceção.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Name,
        [string]$Id,
        [ValidateSet('project', 'local')][string]$Scope = 'project'
    )

    $path = Get-ProjectSettingsPath -ProjectPath $ProjectPath -Scope $Scope
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try { $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
    catch { return $false }
    if (-not ($cfg -is [System.Collections.IDictionary]) -or -not $cfg.Contains('enabledPlugins')) { return $false }

    $decl = $cfg['enabledPlugins']
    if (-not ($decl -is [System.Collections.IDictionary])) { return $false }
    $chave = if ($Id) { "$Name@$Id" } else { $Name }
    foreach ($k in $decl.Keys) {
        if ([string]$k -eq $chave -and $decl[$k]) { return $true }
    }
    return $false
}

function Get-MarketplaceSource {
    <#
    .SYNOPSIS
        Origem (owner/repo) de um marketplace já em disco — de `~/.claude/plugins/known_marketplaces.json`.
    .DESCRIPTION
        O índice da busca sabe o ID do marketplace, não a origem; e `marketplace add --scope project`
        precisa da ORIGEM para o colega que clonar o repo conseguir resolver o plugin. Ausente/
        ilegível/sem entrada = '' (quem chama avisa em vez de montar um comando que falharia).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Marketplace,
        [string]$HomePath = $env:USERPROFILE,
        [string]$KnownPath
    )

    $path = if ($KnownPath) { $KnownPath } else { Join-Path $HomePath '.claude\plugins\known_marketplaces.json' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { $known = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
    catch { return '' }
    if (-not ($known -is [System.Collections.IDictionary]) -or -not $known.Contains($Marketplace)) { return '' }

    $entry = $known[$Marketplace]
    if (-not ($entry -is [System.Collections.IDictionary]) -or -not $entry.Contains('source')) { return '' }
    $src = $entry['source']
    if (-not ($src -is [System.Collections.IDictionary])) { return '' }
    if ($src.Contains('repo')) { return [string]$src['repo'] }
    if ($src.Contains('url')) { return [string]$src['url'] }
    return ''
}

function ConvertTo-SupplementSpec {
    <#
    .SYNOPSIS
        Converte um hit de Find-SupplementCandidate em Spec instalável — com as recusas que
        mantêm a curadoria de pé.
    .DESCRIPTION
        A busca é read-only por princípio: instalar o que ninguém julgou é exatamente o que a
        curadoria evita. O escopo de projeto muda a assimetria, não o princípio — o global
        (`user`) continua sendo do catálogo; o projeto é de quem o mantém. Daí as três recusas,
        que são a regra e não uma checagem defensiva qualquer:

          -Scope user      RECUSA. Instalar fora do catálogo em escopo global é fazer curadoria
                           por acidente. Quer no global? Entre no manifesto, com o julgamento escrito.
          Status recusado  RECUSA. Já existe veredito, com regra e motivo — repropor é apagar decisão.
          Status catalogado RECUSA. Está no repertório: instale pelo tema (o caminho que carrega o
                           Reason curado junto).

        Sobra o hit 'candidato'/'sem-autor', que instala no projeto SOB CONFIRMAÇÃO de quem pediu —
        e assumindo o que a busca não julgou (regras 1, 2 e 4 do critério de admissão).
    .OUTPUTS
        [pscustomobject] { Ok; Spec; Reason }. Ok=$false traz o motivo da recusa em Reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Hit,
        [ValidateSet('user', 'project', 'local')][string]$Scope = 'project',
        [string]$HomePath = $env:USERPROFILE,
        [string]$KnownPath
    )

    if ($Scope -eq 'user') {
        return [pscustomobject]@{
            Ok = $false; Spec = $null
            Reason = "escopo 'user' é do catálogo curado — para valer em todo projeto, '$($Hit.Name)' entra no manifesto (tools/supplements.psd1) com o julgamento escrito; aqui use -Scope project|local"
        }
    }
    if ($Hit.Status -eq 'recusado') {
        return [pscustomobject]@{
            Ok = $false; Spec = $null
            Reason = "'$($Hit.Name)' já foi recusado pela regra $($Hit.Rule): $($Hit.Reason) — a decisão existe; reverter é editar o manifesto, não contornar aqui"
        }
    }
    if ($Hit.Status -eq 'catalogado') {
        return [pscustomobject]@{
            Ok = $false; Spec = $null
            Reason = "'$($Hit.Name)' está no repertório curado — instale pelo tema (/supplements <tema>), que carrega o Reason da curadoria junto"
        }
    }

    $source = Get-MarketplaceSource -Marketplace $Hit.Marketplace -HomePath $HomePath -KnownPath $KnownPath
    if (-not $source) {
        return [pscustomobject]@{
            Ok = $false; Spec = $null
            Reason = "origem do marketplace '$($Hit.Marketplace)' não encontrada em known_marketplaces.json — sem ela o projeto declararia um marketplace que o colega não resolve; rode 'claude plugin marketplace add <owner/repo> --scope $Scope' e repita"
        }
    }

    $motivo = if ($Hit.Description) { $Hit.Description } else { 'sem descrição no marketplace' }
    if ($motivo.Length -gt 160) { $motivo = $motivo.Substring(0, 157) + '...' }

    return [pscustomobject]@{
        Ok = $true
        Spec = [pscustomobject]@{
            Type   = 'plugin'
            Name   = $Hit.Name
            Source = $source
            Id     = $Hit.Marketplace
            Theme  = 'fora-do-catalogo'
            Reason = $motivo
        }
        Reason = "hit '$($Hit.Status)' — as regras 1 (credencial), 2 (footprint) e 4 (sobreposição) NÃO foram verificadas por ninguém; instalar em '$Scope' é assumir isso"
    }
}
