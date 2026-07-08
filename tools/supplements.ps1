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
    .OUTPUTS
        [pscustomobject] @{ Action='add'|'skip'|'warn'; Route='plugin'|'baseline'; Steps; Reason }
        - plugin/add: Steps = [0] marketplace add <Source> ; [1] install <Name>@<Id>.
        - skill/add:  Steps = @() (o Item de baseline é montado pelo Invoke).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Spec,
        [bool]$ClaudePresent = $false,   # gate do Type=plugin
        [bool]$BaselinePresent = $true,  # gate do Type=skill (origem no baseline)
        [bool]$AlreadyInstalled = $false
    )

    if ($Spec.Type -eq 'skill') {
        if (-not $BaselinePresent) {
            return [pscustomobject]@{
                Action = 'warn'; Route = 'baseline'; Steps = @()
                Reason = "origem da skill '$($Spec.Name)' ausente no baseline — pulei (vendorize a skill p/ instalar)"
            }
        }
        if ($AlreadyInstalled) {
            return [pscustomobject]@{
                Action = 'skip'; Route = 'baseline'; Steps = @()
                Reason = "$($Spec.Name) já instalada (skill, user scope)"
            }
        }
        return [pscustomobject]@{
            Action = 'add'; Route = 'baseline'; Steps = @()
            Reason = "instalar skill $($Spec.Name) — $($Spec.Reason)"
        }
    }

    # Type = plugin
    if (-not $ClaudePresent) {
        return [pscustomobject]@{
            Action = 'warn'; Route = 'plugin'; Steps = @()
            Reason = "Claude Code (claude) ausente — pulei $($Spec.Name); instale depois com: claude plugin marketplace add $($Spec.Source) ; claude plugin install $($Spec.Name)@$($Spec.Id)"
        }
    }
    if ($AlreadyInstalled) {
        return [pscustomobject]@{
            Action = 'skip'; Route = 'plugin'; Steps = @()
            Reason = "$($Spec.Name) já instalado (plugin, user scope)"
        }
    }
    $steps = @(
        , @('plugin', 'marketplace', 'add', $Spec.Source)
        , @('plugin', 'install', "$($Spec.Name)@$($Spec.Id)")
    )
    return [pscustomobject]@{
        Action = 'add'; Route = 'plugin'; Steps = $steps
        Reason = "instalar $($Spec.Name) — $($Spec.Reason)"
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
        Raiz do HOME do usuário (destino de Type=skill: <HomePath>/.claude/skills). Parametrizável
        p/ teste (Pester aponta a um TestDrive em vez de $env:USERPROFILE real).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [string[]]$Themes = @(),
        [string]$ManifestPath,
        [string]$HomePath = $env:USERPROFILE,
        [switch]$Check,
        [switch]$DryRun
    )

    $claudePresent = Test-CommandExists 'claude'
    $catalog = Get-SupplementCatalog -Theme $Themes -ManifestPath $ManifestPath
    if (@($catalog).Count -eq 0) {
        Write-Step INFO "supplements: nenhum suplemento para o(s) tema(s) '$($Themes -join ', ')'"
        return
    }

    # Route='baseline' (Type=skill): plano ÚNICO p/ todas as skills do catálogo (reuso do I1),
    # filtrado por skill dentro do loop — evita recomputar o Get-BaselineMap por entrada.
    $skillsBaselineRoot = Get-SupplementSkillsBaselineRoot
    $skillsLocalRoot = Join-Path $HomePath '.claude\skills'
    $skillsPlan = @(Get-SkillUpdatePlan -BaselineRoot $skillsBaselineRoot -LocalRoot $skillsLocalRoot)

    foreach ($spec in $catalog) {
        # "Já instalado?" (read-only) — plugin via 'claude plugin details'; skill via SKILL.md local.
        $already = $false
        $baselinePresent = $true
        if ($spec.Type -eq 'plugin' -and $claudePresent) {
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

        $plan = Get-SupplementPlan -Spec $spec -ClaudePresent $claudePresent -BaselinePresent $baselinePresent -AlreadyInstalled $already

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
                        if ($ok) {
                            Write-Step OK "suplemento instalado: $($spec.Name) [$($spec.Theme)] (user scope)"
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
                            Write-Step OK "suplemento instalado: $($spec.Name) [$($spec.Theme)] (user scope, skill)"
                        }
                    }
                }
            }
        }
    }
}
