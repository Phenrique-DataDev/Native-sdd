<#
.SYNOPSIS
    B6 — telemetria por fase SDD. PILOTO de ITERAÇÕES (o sinal mais barato/útil): conta quantas
    iterações cada fase consumiu por feature. A DURAÇÃO fica PREPARADA (parâmetro/colunas
    existem) mas não é exigida — liga-se sem mudar o contrato. Ver DESIGN_TELEMETRY.md.

.DESCRIPTION
    Funções puras/determinísticas. Armazenam métricas como JSONL append-only (convenção:
    .claude/sdd/telemetry.jsonl). Capturam só metadados (fase/feature/iterações[/duração]) —
    nunca conteúdo. O timestamp é parâmetro do chamador (mantém as funções testáveis).

      Add-PhaseIteration -> registra iterações de uma fase (atalho do piloto, sem duração)
      Add-PhaseMetric    -> registro completo (iterações + duração opcional) — base para ligar a duração
      Get-PhaseReport    -> agrega por fase (iteration-centric; colunas de duração já presentes)
      Format-PhaseReport -> painel determinístico (sem timestamp)

    Integração nos comandos (/build etc.) e um /telemetry ficam para o passo seguinte — aqui
    estão a captura e o relatório prontos para uso.
#>

Set-StrictMode -Version Latest

function Add-PhaseMetric {
    <#
    .SYNOPSIS
        Registro completo de uma métrica de fase (append JSONL). Iterações é o sinal do piloto;
        DurationSeconds é opcional (preparado — só é gravado se informado > 0).
    .OUTPUTS
        Nenhum (efeito: 1 linha JSON anexada).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Feature,
        [int]$Iterations = 1,
        [double]$DurationSeconds = 0,
        [string]$Timestamp
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $record = [ordered]@{
        phase      = $Phase
        feature    = $Feature
        iterations = $Iterations
    }
    # Duração só entra no registro quando de fato medida (mantém o piloto enxuto; preparado p/ ligar).
    if ($DurationSeconds -gt 0) { $record['duration_seconds'] = $DurationSeconds }
    if ($Timestamp)            { $record['timestamp'] = $Timestamp }

    $line = ($record | ConvertTo-Json -Compress)
    Add-Content -LiteralPath $Path -Value $line -Encoding utf8
}

function Add-PhaseIteration {
    <#
    .SYNOPSIS
        Atalho do piloto: registra as iterações de uma fase, sem duração. Use ao fim de uma fase
        (ex.: nº de re-invocações/gate-fails no /build) — `Add-PhaseIteration -Path <jsonl>
        -Phase build -Feature H2 -Iterations 3`.
    .OUTPUTS
        Nenhum (efeito: 1 linha JSON anexada).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Feature,
        [int]$Iterations = 1,
        [string]$Timestamp
    )
    Add-PhaseMetric -Path $Path -Phase $Phase -Feature $Feature -Iterations $Iterations -Timestamp $Timestamp
}

function Get-PhaseReport {
    <#
    .SYNOPSIS
        Agrega o JSONL por fase (iteration-centric). Read-only e determinístico (ordenado por
        Phase). As colunas de duração já vêm no objeto (0 enquanto a duração não for medida).
        Arquivo ausente -> @().
    .OUTPUTS
        [pscustomobject[]] { Phase; Events; TotalIterations; AvgIterations; TotalSeconds; AvgSeconds }
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $records = foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $line | ConvertFrom-Json } catch { continue }   # ignora linha corrompida
    }

    $report = foreach ($g in (@($records) | Group-Object phase | Sort-Object Name)) {
        $events = [int]$g.Count
        $iters = (@($g.Group) | Measure-Object -Property iterations -Sum).Sum
        if (-not $iters) { $iters = 0 }
        # duration_seconds pode não existir em todos os registros (piloto) — soma defensiva.
        $secs = 0.0
        foreach ($r in @($g.Group)) {
            if ($r.PSObject.Properties['duration_seconds']) { $secs += [double]$r.duration_seconds }
        }
        [pscustomobject]@{
            Phase           = $g.Name
            Events          = $events
            TotalIterations = [int]$iters
            AvgIterations   = [double]([math]::Round($iters / $events, 2))
            TotalSeconds    = [double]$secs
            AvgSeconds      = [double]([math]::Round($secs / $events, 2))
        }
    }
    return @($report)
}

function Format-PhaseReport {
    <#
    .SYNOPSIS
        Painel determinístico do relatório de fases (sem timestamp). Foco em iterações; a coluna
        de duração só aparece com conteúdo quando alguma fase tiver duração medida.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    $report = @(Get-PhaseReport -Path $Path)
    $anyDuration = [bool](@($report | Where-Object { $_.TotalSeconds -gt 0 }).Count)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    [void]$sb.Append("TELEMETRIA — iterações por fase`n")
    if ($report.Count -eq 0) {
        [void]$sb.Append("(sem dados)`n")
    }
    else {
        foreach ($r in $report) {
            $dur = if ($anyDuration) { "  ·  $($r.TotalSeconds)s (avg $($r.AvgSeconds)s)" } else { '' }
            [void]$sb.Append("  $($r.Phase): $($r.TotalIterations) iter em $($r.Events) evento(s) (avg $($r.AvgIterations))$dur`n")
        }
    }
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}
