<#
.SYNOPSIS
    Status/prontidão do G1 (/init): deriva o estado da curadoria do repo e decide a etapa
    seguinte da cadeia de especialização (setup? -> audit-agents -> train-kb -> sync-context).

.DESCRIPTION
    Funções puras (read-only, determinísticas) usadas pela validação automática do G1 e pelo
    comando em runtime. Reusam os inventários do G2 (Get-AgentInventory) e do G3
    (Get-KbInventory) por dot-source — não reimplementam varredura.

      Test-ProjectInitialized -> bool: project-context.md com 'status: active' e sem placeholders
      Get-CurationStatus      -> estado do repo (flags por etapa + NextStep)
      Test-CurationReadiness  -> pré-condição de uma etapa (a partir do status)
      Format-CurationReport   -> painel determinístico (sem timestamp)

    Determinismo: sem datas/timestamps na saída; contagens via Group-Object|Sort-Object.
    Nada escreve em disco — a escrita real é dos sub-comandos conduzidos pelo /init.
#>

Set-StrictMode -Version Latest

# Reuso dos inventários do G2/G3 (dot-source idempotente).
. (Join-Path $PSScriptRoot 'agent-lint.ps1')
. (Join-Path $PSScriptRoot 'kb-lint.ps1')

# Etapas da cadeia, na ordem.
$script:CurationStages = @('setup', 'audit-agents', 'train-kb', 'sync-context')

# Regiões marcadas que o /sync-context (G4) preenche — usadas para aferir RegionsSynced.
$script:SyncRegions = @(
    @{ Doc = 'AGENTS.md'; Name = 'rules' }
    @{ Doc = 'AGENTS.md'; Name = 'kb' }
    @{ Doc = 'CLAUDE.md'; Name = 'commands' }
)

function Test-ProjectInitialized {
    <#
    .SYNOPSIS
        $true quando .claude/rules/project-context.md tem 'status: active' e nenhum
        placeholder <...> por preencher. Arquivo/dir ausente -> $false.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path $Root '.claude/rules/project-context.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }

    $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ($text -notmatch 'status:\s*active') { return $false }
    # placeholders do template: <NOME>, <DOMÍNIO>, <ex.: ...> etc. (maiúscula/acentuada após '<')
    if ($text -match '<[A-Za-zÀ-Ý]') { return $false }
    return $true
}

function Test-RegionFilled {
    <#
    .SYNOPSIS
        $true se a região <!-- sync-context:start:NAME --> ... :end:NAME --> existe no arquivo
        e tem conteúdo não-vazio entre os marcadores. Read-only e fail-safe.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

    $startMark = "<!-- sync-context:start:$Name -->"
    $endMark   = "<!-- sync-context:end:$Name -->"
    $si = $text.IndexOf($startMark)
    $ei = $text.IndexOf($endMark)
    if ($si -lt 0 -or $ei -lt 0 -or $ei -lt $si) { return $false }

    $inner = $text.Substring($si + $startMark.Length, $ei - ($si + $startMark.Length))
    return -not [string]::IsNullOrWhiteSpace($inner)
}

function Get-CurationStatus {
    <#
    .SYNOPSIS
        Deriva o estado da curadoria do repo em -Root. Read-only e determinístico.
    .OUTPUTS
        [pscustomobject] ProjectInitialized/DomainAgents/KbDomains/KbEntries/IndexExists/
                         RegionsSynced/NextStep
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $initialized = Test-ProjectInitialized -Root $Root

    # Agentes de domínio: gerados pela curadoria (.Generated) e válidos.
    $agents = @(Get-AgentInventory -Dir (Join-Path $Root '.claude/agents'))
    $domainAgents = @($agents | Where-Object { $_.Generated -and $_.Valid }).Count

    # KB: domínios distintos e total de entradas válidas.
    $kb = @(Get-KbInventory -Dir (Join-Path $Root '.claude/kb'))
    $validKb = @($kb | Where-Object { $_.Valid -and $_.Domain })
    $kbDomains = @($validKb | Group-Object Domain).Count
    $kbEntries = $validKb.Count

    # Índice da KB gerado pelo G4.
    $indexExists = Test-Path -LiteralPath (Join-Path $Root '.claude/kb/_index.yaml') -PathType Leaf

    # AGENT_MAP gerado + todas as regiões marcadas preenchidas (checagem estrutural).
    $mapPath = Join-Path $Root '.claude/agents/AGENT_MAP.md'
    $mapGenerated = (Test-Path -LiteralPath $mapPath -PathType Leaf) -and
        ((Get-Content -LiteralPath $mapPath -Raw -ErrorAction SilentlyContinue) -match 'Gerado por')
    $regionsFilled = $true
    foreach ($r in $script:SyncRegions) {
        if (-not (Test-RegionFilled -Path (Join-Path $Root $r.Doc) -Name $r.Name)) {
            $regionsFilled = $false
            break
        }
    }
    $regionsSynced = [bool]($mapGenerated -and $regionsFilled -and $indexExists)

    # NextStep: regra única ordenada espelhando a cadeia.
    $next =
        if (-not $initialized)                       { 'setup' }
        elseif ($domainAgents -eq 0)                 { 'audit-agents' }
        elseif ($kbDomains -eq 0)                    { 'train-kb' }
        elseif (-not ($indexExists -and $regionsSynced)) { 'sync-context' }
        else                                         { 'done' }

    return [pscustomobject]@{
        ProjectInitialized = [bool]$initialized
        DomainAgents       = [int]$domainAgents
        KbDomains          = [int]$kbDomains
        KbEntries          = [int]$kbEntries
        IndexExists        = [bool]$indexExists
        RegionsSynced      = [bool]$regionsSynced
        NextStep           = [string]$next
    }
}

function Test-CurationReadiness {
    <#
    .SYNOPSIS
        Pré-condição de uma etapa, a partir de um status já computado.
        audit-agents/train-kb exigem ProjectInitialized; setup/sync-context -> sempre $true.
        -Stage desconhecido -> $false.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][psobject]$Status
    )

    switch ($Stage) {
        'setup'         { return $true }
        'sync-context'  { return $true }
        'audit-agents'  { return [bool]$Status.ProjectInitialized }
        'train-kb'      { return [bool]$Status.ProjectInitialized }
        default         { return $false }
    }
}

function Format-CurationReport {
    <#
    .SYNOPSIS
        Painel determinístico do estado da curadoria (sem timestamp).
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Status)

    # marca por etapa: ✓ concluída · • próxima sugerida (NextStep) · – pendente
    function Get-Mark([string]$stage, [bool]$done) {
        if ($done) { return '✓' }
        if ($Status.NextStep -eq $stage) { return '•' }
        return '–'
    }

    $setupDone = [bool]$Status.ProjectInitialized
    $g2Done    = $Status.DomainAgents -gt 0
    $g3Done    = $Status.KbDomains -gt 0
    $g4Done    = [bool]$Status.RegionsSynced

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    [void]$sb.Append("CURADORIA — estado atual`n")
    [void]$sb.Append("[$(Get-Mark 'setup'        $setupDone)] setup          projeto inicializado: $(if($setupDone){'sim'}else{'não'})`n")
    [void]$sb.Append("[$(Get-Mark 'audit-agents' $g2Done)] audit-agents   agentes de domínio: $($Status.DomainAgents)`n")
    [void]$sb.Append("[$(Get-Mark 'train-kb'     $g3Done)] train-kb       domínios de KB: $($Status.KbDomains)`n")
    [void]$sb.Append("[$(Get-Mark 'sync-context' $g4Done)] sync-context   índices: $(if($g4Done){'sincronizados'}else{'pendentes'})`n")
    [void]$sb.Append("Próximo: $($Status.NextStep)`n")
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}
