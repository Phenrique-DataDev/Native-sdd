<#
.SYNOPSIS
    Staleness-lint dos artefatos derivados: acusa quando AGENT_MAP.md, graph.json/graph.cypher ou
    kb/_index.yaml COMMITADOS divergem do estado ao vivo.

    HISTÓRICO (vale a pena não repetir): este lint saiu do CI em 2026-06-20 (postura low-friction),
    mas o header seguiu dizendo "trava o CI" — falso por ~3 semanas. Corrigido em 2026-07-13… e no
    mesmo dia a decisão foi REVERTIDA, com evidência: o AGENT_MAP.md COMMITADO no scaffold estava
    stale (faltava /complementary-repos), então TODO projeto novo nascia com o mapa velho — e nada
    avisou, porque o único lint que pegaria isso era este, e ele não rodava. Agora roda no check.ps1
    sobre o scaffold (~0,1 s, 0 bytes escritos).

.DESCRIPTION
    Rede de segurança para o caminho MANUAL (alguém edita um agente à mão e esquece de ressincronizar).
    O mecanismo primário é o passo de resync NA CRIAÇÃO (/audit-agents · /train-kb · /skill-gap, e o
    /sync-context) via Invoke-Resync -Write; este lint apenas PEGA quem escapou — quando invocado.

    Casca fina sobre o driver (resync.ps1): roda `Invoke-Resync -Check` (gera em memória, não escreve)
    e mapeia cada DriftResult{InSync=$false} → finding `error` `stale-<key>`:
      - stale-map       : AGENT_MAP.md diverge (ou ausente).
      - stale-graph     : graph.json e/ou graph.cypher divergem (ou ausentes).
      - stale-kb-index  : kb/_index.yaml diverge (ou ausente).

    A Message aponta a correção (Invoke-Resync -Write / /sync-context). Severidade só `error` (alvo
    determinístico/binário, sem `warn`) — o gate reprova quando invocado. Shape canônico dos demais
    lints (New-*Finding / Get-*Findings / Format-* / Test-*Gate / Invoke-*).
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'resync.ps1')   # Invoke-Resync, Get-ResyncPlan

# Mapa estável Key -> regra do finding.
$script:ResyncRuleFor = @{ 'map' = 'stale-map'; 'graph' = 'stale-graph'; 'kb-index' = 'stale-kb-index' }

function New-ResyncFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-ResyncFindings {
    <#
    .SYNOPSIS  PURA: transforma os DriftResult (de Invoke-Resync -Check) em findings stale-<key>.
    .OUTPUTS   [pscustomobject[]] (vazio = em dia).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Drift)

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Drift) {
        if ($d.Key -eq '_dir') {
            $findings.Add((New-ResyncFinding -Severity error -Rule missing-claudedir -Path "$(@($d.Paths)[0])#/" `
                        -Message 'diretório .claude inexistente — nada a comparar'))
            continue
        }
        if ($d.InSync) { continue }
        $rule  = if ($script:ResyncRuleFor.ContainsKey($d.Key)) { $script:ResyncRuleFor[$d.Key] } else { "stale-$($d.Key)" }
        $where = @($d.Paths) -join ', '
        $what  = if ($d.Reason -eq 'missing-on-disk') { 'ausente' } else { 'divergente do estado ao vivo' }
        $findings.Add((New-ResyncFinding -Severity error -Rule $rule -Path "$where#/" `
                    -Message "$where $what — rode Invoke-Resync -Write (ou /sync-context) para ressincronizar"))
    }
    return $findings.ToArray()
}

function Format-ResyncLintReport {
    <# .SYNOPSIS  Painel legível dos achados. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'resync-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $file = ($f.Path -split '#', 2)[0]
        $lines.Add("    [$($f.Severity)] $($f.Rule) $file — $($f.Message)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-ResyncLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-ResyncLint {
    <#
    .SYNOPSIS  I/O fino: roda o driver em -Check sobre o .claude e devolve os achados de staleness.
    .OUTPUTS   [pscustomobject[]] de achados (vazio = em sincronia).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClaudeDir)

    $drift = @(Invoke-Resync -ClaudeDir $ClaudeDir -Check)
    return @(Get-ResyncFindings -Drift $drift)
}
