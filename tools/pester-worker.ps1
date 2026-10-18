<#
.SYNOPSIS
    Worker do Pester paralelo do `check.ps1`: puxa arquivos `*.Tests.ps1` de uma fila em disco, roda
    cada um com `Invoke-Pester` e grava uma linha JSON por arquivo. Não é para chamar à mão.

.DESCRIPTION
    A fila é um diretório com um `.job` por arquivo de teste (conteúdo: o caminho). O worker reivindica
    um `.job` movendo-o para a própria pasta `claimed-<PID>`: o `Move` é atômico, então dois workers
    nunca rodam o mesmo arquivo, e quem perde a corrida só tenta o próximo. Fila dinâmica em vez de
    fatias fixas porque o custo por arquivo vai de 0,1 s a ~200 s: com fatia fixa, um worker termina
    cedo e fica parado enquanto outro carrega os dois mais pesados.

    Processo separado, e não runspace: os testes usam `Mock`, `TestDrive`, `$env:` e dot-source com
    StrictMode, e nada disso é seguro de compartilhar entre threads do mesmo processo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QueueDir,
    [Parameter(Mandatory)][string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NÃO mexer em [Console]::OutputEncoding/$OutputEncoding aqui. Herdar a página do pai foi tentado
# em 2026-10-17 e quebrou o CI: no runner a página é 65001, `Encoding.GetEncoding(65001)` traz BOM,
# e o BOM ia na frente do JSON que os testes mandam por stdin aos hooks (39 falhas `silence`). O
# isolamento que importa é o console próprio por worker (CreateNoWindow, no Invoke-PesterParallel).
Import-Module Pester -MinimumVersion 5.0

$claimed = Join-Path $QueueDir "claimed-$PID"
$null = New-Item -ItemType Directory -Path $claimed -Force

function Get-FirstLine([object]$ErrorRecord) {
    if (-not $ErrorRecord) { return '' }
    # Não só a 1ª linha: no `Should -Match` o que se recebeu vem depois da quebra, e é isso que
    # diagnostica. As quebras viram ' | ' para caber numa linha do log.
    $msg = (([string]@($ErrorRecord)[0].Exception.Message) -replace "`r?`n", ' | ').Trim()
    if ($msg.Length -gt 800) { $msg = $msg.Substring(0, 800) + '…' }
    $msg
}

while ($true) {
    $next = Get-ChildItem -LiteralPath $QueueDir -Filter '*.job' -File | Sort-Object Name | Select-Object -First 1
    if (-not $next) { break }
    $dest = Join-Path $claimed $next.Name
    try { [System.IO.File]::Move($next.FullName, $dest) } catch { continue }   # outro worker levou

    # 1ª linha: o arquivo. 2ª (opcional): o Describe de topo desta fatia.
    $linhas = @((Get-Content -LiteralPath $dest -Raw -Encoding utf8) -split "`n" | ForEach-Object { $_.Trim() })
    $path = $linhas[0]
    $shard = if ($linhas.Count -gt 1) { $linhas[1] } else { '' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rec = [ordered]@{ File = $path; Shard = $shard; Seconds = 0; Passed = 0; Failed = 0; Skipped = 0; NotRun = 0
        FailedContainers = @(); FailedTests = @() }
    try {
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = $path
        if ($shard) { $cfg.Filter.FullName = "$([WildcardPattern]::Escape($shard)).*" }
        $cfg.Run.PassThru = $true
        $cfg.Output.Verbosity = 'None'
        $r = Invoke-Pester -Configuration $cfg
        $rec.Passed = $r.PassedCount; $rec.Failed = $r.FailedCount
        $rec.Skipped = $r.SkippedCount; $rec.NotRun = $r.NotRunCount
        $rec.FailedContainers = @($r.FailedContainers | ForEach-Object {
                $er = $_.PSObject.Properties['ErrorRecord']
                Get-FirstLine $(if ($er) { $er.Value })
            })
        $rec.FailedTests = @($r.Failed | ForEach-Object {
                [ordered]@{ Name = $_.ExpandedPath; Message = (Get-FirstLine $_.ErrorRecord) }
            })
    }
    catch {
        # Exceção fora do Pester (não deveria acontecer): conta como container falho, nunca some.
        $rec.FailedContainers = @("worker: $($_.Exception.Message)")
    }
    $sw.Stop()
    $rec.Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Add-Content -LiteralPath $OutFile -Value ($rec | ConvertTo-Json -Compress -Depth 5) -Encoding utf8
}
