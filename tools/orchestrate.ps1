<#
.SYNOPSIS
    Gate + estado do H2 (/orchestrate): valida o resultado de uma task (gate determinístico) e
    deriva o estado resumível da orquestração a partir de um arquivo STATE. Sem engine — invocar/
    aguardar/paralelizar/resume é a ferramenta Agent nativa, conduzida pelo líder em runtime.

.DESCRIPTION
    Funções puras (read-only, determinísticas) usadas pela validação automática do H2 e pelo
    comando em runtime. Espelham o PADRÃO do G1 (tools/init.ps1: Get-CurationStatus /
    Test-CurationReadiness / Format-CurationReport) — molde, não dot-source.

      ConvertFrom-OrchestrationState -> [pscustomobject[]]  { Id; Title; Dod; Model; Deps[]; Status }
      Get-OrchestrationStatus       -> [pscustomobject]     { Objective; Total; Passed; Failed; Pending; Tasks[]; ReadyTasks[]; NextTask }
      Test-TaskGate                 -> [pscustomobject]     { Passed=[bool]; Failed[]; Checked[] }
      Format-OrchestrationReport    -> [string]             painel determinístico (sem timestamp)

    Determinismo: ordenação estável por Id; nenhuma data/timestamp na saída; quebras LF. Nada
    escreve em disco — a escrita do STATE e a invocação de Agent são runtime, conduzidas pelo líder.
#>

Set-StrictMode -Version Latest

# Critérios obrigatórios default do gate (extensível via -Required).
$script:DefaultGateCriteria = @('TestsGreen', 'LintClean', 'ArtifactConforms')

function ConvertFrom-OrchestrationState {
    <#
    .SYNOPSIS
        Mini-parser do STATE (yaml): lê os itens sob a chave de topo `tasks:` (layout fixo,
        ver orchestration.md). Item sem `id` é ignorado. `deps` inline `[a, b]`. Read-only.
        -StatePath ausente/inexistente -> @() (não lança).
    .OUTPUTS
        [pscustomobject[]] { Id; Title; Dod; Model; Deps[]; Status } — ordenado por Id.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$StatePath)

    if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return @()
    }

    $lines = Get-Content -LiteralPath $StatePath -ErrorAction SilentlyContinue
    $inTasks = $false
    $cur = $null
    $tasks = [System.Collections.Generic.List[object]]::new()

    function New-TaskObject($t) {
        [pscustomobject]@{
            Id     = $t.Id
            Title  = $t.Title
            Dod    = $t.Dod
            Model  = $t.Model
            Deps   = @($t.Deps)
            Status = if ($t.Status) { $t.Status } else { 'pending' }
        }
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }

        # Chave de topo (sem indentação) → abre/fecha o bloco tasks.
        if ($line -match '^\S') {
            if ($cur -and $cur.Id) { $tasks.Add((New-TaskObject $cur)); $cur = $null }
            $inTasks = ($line -match '^\s*tasks\s*:')
            continue
        }

        if (-not $inTasks) { continue }

        # Novo item da lista: "- id: <x>"
        if ($line -match '^\s*-\s*id\s*:\s*(.+?)\s*$') {
            if ($cur -and $cur.Id) { $tasks.Add((New-TaskObject $cur)) }
            $cur = @{ Id = $Matches[1].Trim().Trim('"').Trim("'"); Title = ''; Dod = ''; Model = ''; Deps = @(); Status = 'pending' }
        }
        elseif ($cur) {
            if ($line -match '^\s*title\s*:\s*(.+?)\s*$')      { $cur.Title  = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*dod\s*:\s*(.+?)\s*$')    { $cur.Dod    = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*model\s*:\s*(.+?)\s*$')  { $cur.Model  = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*status\s*:\s*(.+?)\s*$') { $cur.Status = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*deps\s*:\s*\[(.*)\]\s*$') {
                $inner = $Matches[1].Trim()
                $depList = @()
                if ($inner) { $depList = @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ }) }
                $cur.Deps = $depList
            }
        }
    }
    if ($cur -and $cur.Id) { $tasks.Add((New-TaskObject $cur)) }

    return @($tasks | Sort-Object Id)
}

function Get-OrchestrationStatus {
    <#
    .SYNOPSIS
        Deriva o estado resumível da orquestração a partir do STATE. Read-only, determinística.
        ReadyTasks = tasks 'pending' cujas deps estão TODAS 'passed' (disparo paralelo). Idempotente
        (não rebaixa 'passed'). STATE ausente -> estado vazio (NextTask='done').
    .OUTPUTS
        [pscustomobject] { Objective; Total; Passed; Failed; Pending; Tasks[]; ReadyTasks[]; NextTask }
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$StatePath)

    $objective = ''
    if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        foreach ($line in (Get-Content -LiteralPath $StatePath -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*objective\s*:\s*(.+?)\s*$') { $objective = $Matches[1].Trim().Trim('"').Trim("'"); break }
        }
    }

    $tasks = @(ConvertFrom-OrchestrationState -StatePath $StatePath)
    $passedIds = @($tasks | Where-Object { $_.Status -eq 'passed' } | ForEach-Object { $_.Id })

    $ready = foreach ($t in $tasks) {
        if ($t.Status -ne 'pending') { continue }
        $depsMet = $true
        foreach ($d in @($t.Deps)) { if ($passedIds -notcontains $d) { $depsMet = $false; break } }
        if ($depsMet) { $t.Id }
    }
    $ready = @($ready | Sort-Object)

    $passed  = @($tasks | Where-Object { $_.Status -eq 'passed' }).Count
    $failed  = @($tasks | Where-Object { $_.Status -eq 'failed' }).Count
    $pending = @($tasks | Where-Object { $_.Status -eq 'pending' }).Count

    $next =
        if ($ready.Count -gt 0)              { $ready[0] }
        elseif ($pending -gt 0 -or $failed -gt 0) { 'blocked' }
        else                                 { 'done' }

    return [pscustomobject]@{
        Objective  = [string]$objective
        Total      = [int]$tasks.Count
        Passed     = [int]$passed
        Failed     = [int]$failed
        Pending    = [int]$pending
        Tasks      = $tasks
        ReadyTasks = @($ready)
        NextTask   = [string]$next
    }
}

function Test-TaskGate {
    <#
    .SYNOPSIS
        Gate determinístico do resultado de uma task: passa só se TODOS os critérios obrigatórios
        forem $true no -Result. Critério obrigatório ausente no -Result conta como FALHA (nunca passa
        por omissão). O gate semântico entra como mais um critério booleano (ex.: ReviewApproved) ao
        ser incluído em -Required. Puro.
    .OUTPUTS
        [pscustomobject] { Passed=[bool]; Failed=[string[]]; Checked=[string[]] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Result,
        [string[]]$Required = $script:DefaultGateCriteria
    )

    function Get-CriterionValue($obj, [string]$key) {
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($key)) { return [bool]$obj[$key] }
            return $null
        }
        $prop = $obj.PSObject.Properties[$key]
        if ($prop) { return [bool]$prop.Value }
        return $null
    }

    $checked = @($Required | Sort-Object -Unique)
    $failed = foreach ($c in $checked) {
        $v = Get-CriterionValue $Result $c
        if ($v -ne $true) { $c }   # ausente ($null) ou $false -> falha
    }
    $failed = @($failed)

    return [pscustomobject]@{
        Passed  = [bool]($failed.Count -eq 0)
        Failed  = $failed
        Checked = $checked
    }
}

function Format-OrchestrationReport {
    <#
    .SYNOPSIS
        Painel determinístico do estado da orquestração (sem timestamp). Marca por task:
        ✓ passed · ✗ failed · • ready · – pending.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Status)

    $ready = @($Status.ReadyTasks)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    [void]$sb.Append("ORCHESTRATE — $($Status.Objective)`n")
    foreach ($t in @($Status.Tasks)) {
        $mark =
            if ($t.Status -eq 'passed')      { '✓' }
            elseif ($t.Status -eq 'failed')  { '✗' }
            elseif ($ready -contains $t.Id)  { '•' }
            else                             { '–' }
        $deps = if (@($t.Deps).Count -gt 0) { ($t.Deps -join ', ') } else { '—' }
        $state = if ($t.Status -eq 'pending' -and $ready -contains $t.Id) { 'ready' } else { $t.Status }
        [void]$sb.Append("  [$mark] $($t.Id)   (deps: $deps)   $state`n")
    }
    [void]$sb.Append("Progresso: $($Status.Passed)/$($Status.Total) passed · $($ready.Count) ready · $($Status.Pending) pending · $($Status.Failed) failed`n")
    [void]$sb.Append("Próximo: $($Status.NextTask)`n")
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}
