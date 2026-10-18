<#
.SYNOPSIS
    Runner único de verificação: roda PSScriptAnalyzer + todos os lints de conformidade + Pester,
    agrega o resultado e devolve um veredito.

    ADVISORY: `exit 0` SEMPRE, inclusive com check reprovado (decisão de postura, ver o guard no fim
    do arquivo). O veredito está no RESUMO IMPRESSO e em `$sum.AllOk` quando dot-sourced. Quem
    automatizar em cima do exit code constrói um gate que nunca fecha — e era isso que o cabeçalho
    convidava a fazer: ele prometia `exit 0/1` desde que a decisão de virar advisory foi tomada,
    sem nunca ter acompanhado.

.DESCRIPTION
    Fonte ÚNICA dos escopos de verificação do repo — o `ci.yml` chama este script em vez de repetir
    o boilerplate de cada lint. Localmente: `pwsh tools/check.ps1` (antes de abrir PR).

    Cada check devolve { Name; Ok; Status; Detail; Seconds }, com Status `ok`/`fail`/`n/a`.
    Dot-source dos `*-lint.ps1` é isolado por check. Módulos `Pester` (≥5) e `PSScriptAnalyzer`: o
    CI os instala antes; sem eles, o check sai `n/a` com a dica de `Install-Module` (não `FAIL`).

    Flags:
      -SkipPester     pula a suíte Pester (iteração rápida só nos lints estáticos)
      -ExcludeTest    caminhos (relativos à raiz) de suítes Pester a deixar de fora — o CI usa para
                      pular as suítes de scaffold quando nada do scaffold mudou (.github/ci-scope.ps1)
      -SkipAnalyzer   pula o PSScriptAnalyzer (o mais lento)
      -SkipBudget     pula o retrato de contexto always-on (rules-budget, G8 v2)
      -Quiet          só o resumo final (omite o relatório detalhado de cada lint que falhar)
      -PesterJobs     workers do Pester paralelo (tools/pester-worker.ps1). 0 = um por núcleo, até 8;
                      1 = sequencial, num Invoke-Pester só. Com mais de 1, o PSScriptAnalyzer roda
                      numa thread ao lado do Pester

    Uso por função (igual aos outros tools): `. ./tools/check.ps1 ; Invoke-Check`.
    Como script: `pwsh tools/check.ps1 [-SkipPester] [-SkipAnalyzer] [-Quiet]` — exit 0 sempre; o
    veredito é o resumo impresso, não o código de saída.
#>

[CmdletBinding()]
param(
    [switch]$SkipPester,
    [string[]]$ExcludeTest = @(),
    [switch]$SkipAnalyzer,
    [switch]$SkipBudget,
    [switch]$Quiet,
    [int]$PesterJobs = 0
)

Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Scaffold = Join-Path $script:RepoRoot 'templates/project-scaffold/.claude'
# NÃO reinicializar $script:Quiet aqui: o param `$Quiet` de nível-script JÁ é $script:Quiet, e um reset
# clobbaria um `-Quiet` passado (a guard repassa o valor à Invoke-Check, que o propaga aos helpers).

# --- PURA: monta o objeto-resultado de um check ----------------------------------------------
#
# TRÊS estados, não dois (SDDCHECK_VERMELHO_NO_ESPELHO): `ok`, `fail` e `n/a`. O `n/a` é "não há o
# que checar aqui" — o alvo não está no disco ou o módulo falta — e NUNCA é `Ok`: um check que fica
# verde por não ter conseguido rodar é a pior das duas falhas (regra de 2026-09-06). Antes, numa
# máquina recém-instalada o `sddcheck` abria com `FALHOU — 3/16` sem ter medido o framework.
function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Detail = '',
        [double]$Seconds = 0,
        [ValidateSet('ok', 'fail', 'n/a')][string]$Status
    )
    if (-not $Status) { $Status = if ($Ok) { 'ok' } else { 'fail' } }
    if ($Status -eq 'n/a') { $Ok = $false }
    [pscustomobject]@{ Name = $Name; Ok = $Ok; Status = $Status; Detail = $Detail; Seconds = [math]::Round($Seconds, 1) }
}

# --- Helper: módulo PowerShell ausente -> n/a com a dica (o onboarding não instala módulo) ------
function Test-CheckModule {
    param([Parameter(Mandatory)][string]$Name, [version]$MinimumVersion = '0.0')
    return [bool](@(Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -ge $MinimumVersion }).Count)
}

# --- Helper: roda um lint de conformidade (findings + gate) -> CheckResult --------------------
function Invoke-LintCheck {
    <#
    .SYNOPSIS  Dot-source do tool, roda -Findings (scriptblock) e -Gate; conta erros; imprime
               o relatório só quando falha e não está -Quiet.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Tool,          # nome do arquivo em tools/ (ex.: 'config-lint.ps1')
        [Parameter(Mandatory)][scriptblock]$Findings,  # devolve o array de findings
        [Parameter(Mandatory)][scriptblock]$Gate,      # ($f) -> bool (true = passou)
        [scriptblock]$Report                            # ($f) -> string (opcional)
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        . (Join-Path $PSScriptRoot $Tool)
        $f = @(& $Findings)
        $ok = [bool](& $Gate $f)
        $n = @($f | Where-Object { $_.Severity -eq 'error' }).Count
        if (-not $ok -and -not $script:Quiet -and $Report) { (& $Report $f) | Write-Host }
        $sw.Stop()
        return New-CheckResult -Name $Name -Ok $ok -Detail $(if ($ok) { 'ok' } else { "$n erro(s)" }) -Seconds $sw.Elapsed.TotalSeconds
    }
    catch {
        $sw.Stop()
        return New-CheckResult -Name $Name -Ok $false -Detail "exceção: $($_.Exception.Message)" -Seconds $sw.Elapsed.TotalSeconds
    }
}

# --- Check: PSScriptAnalyzer ------------------------------------------------------------------
function Invoke-AnalyzerCheck {
    param([string]$Root = $script:RepoRoot)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-CheckModule -Name 'PSScriptAnalyzer')) {
        return New-CheckResult -Name 'PSScriptAnalyzer' -Ok $false -Status 'n/a' `
            -Detail 'módulo ausente — Install-Module PSScriptAnalyzer -Scope CurrentUser' -Seconds $sw.Elapsed.TotalSeconds
    }
    try {
        $settings = Join-Path $Root 'onboarding/PSScriptAnalyzerSettings.psd1'
        # `-Recurse` numa pasta inteira arrasta dependencia de terceiro junto: `tools/site-tests/`
        # traz `node_modules/playwright-core/bin/*.ps1`, que e gitignorado, nao e distribuido e
        # nao e nosso — e ainda assim derrubava o check com um PSAvoidUsingWMICmdlet que ninguem
        # aqui pode corrigir. Excluir a REGRA esconderia o defeito tambem no nosso codigo; o que
        # se exclui e o caminho.
        $alvos = @('onboarding', 'tools') | ForEach-Object {
            Get-ChildItem -Path (Join-Path $Root $_) -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' }
        }
        $issues = @($alvos | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings })
        $blocking = @($issues | Where-Object { $_.Severity -in 'Error', 'Warning' })
        if ($blocking.Count -gt 0 -and -not $script:Quiet) {
            $blocking | Format-Table -AutoSize | Out-String | Write-Host
        }
        $sw.Stop()
        return New-CheckResult -Name 'PSScriptAnalyzer' -Ok ($blocking.Count -eq 0) `
            -Detail $(if ($blocking.Count -eq 0) { 'limpo' } else { "$($blocking.Count) bloqueante(s)" }) `
            -Seconds $sw.Elapsed.TotalSeconds
    }
    catch {
        $sw.Stop()
        return New-CheckResult -Name 'PSScriptAnalyzer' -Ok $false -Detail "exceção: $($_.Exception.Message)" -Seconds $sw.Elapsed.TotalSeconds
    }
}

# --- Check: Pester ----------------------------------------------------------------------------

# Os mais caros no CI de 2026-10-17 (run 39057747249, Windows), em ordem: a fila paralela os põe na
# frente e o resto vai por tamanho. Começar pelo mais longo impede que um worker o pegue no fim e
# segure o check sozinho. Nome que sumiu daqui só custa tempo, nunca correção.
$script:PesterHeavyFirst = @(
    'scaffold-upgrade.Tests.ps1', 'destructive-guard.Tests.ps1', 'scaffold-profile.Tests.ps1',
    'complementary-repo-guard.Tests.ps1', 'hook-triggers.Tests.ps1', 'new-project-git.Tests.ps1',
    'secret-guard-sh.Tests.ps1', 'project-check.Tests.ps1', 'secret-scan-sh.Tests.ps1', 'tools-wiring.Tests.ps1'
)

# Workers do Pester paralelo quando ninguém diz: um por núcleo lógico, até 8 (mais não ganha, e cada
# pwsh custa memória). Abaixo de 4 núcleos, sequencial: o Pester daqui é spawn de processo, preso a
# CPU, e com 2–3 núcleos os workers só disputam a mesma CPU. Medido no CI da v0.11.55: Windows de
# 2 vCPU levou 643 s em paralelo contra ~546 s em fila; macOS de 3 vCPU, 145 s contra 124 s.
function Get-PesterDefaultJobs {
    $n = [Environment]::ProcessorCount
    if ($n -lt 4) { return 1 }
    [math]::Min(8, $n)
}

# --- PURA: ordem da fila — pesados medidos primeiro, depois por tamanho ------------------------
function Get-PesterQueueOrder {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.IO.FileInfo[]]$Files)
    $rank = @{}
    for ($i = 0; $i -lt $script:PesterHeavyFirst.Count; $i++) { $rank[$script:PesterHeavyFirst[$i]] = $i }
    @($Files | Sort-Object @{ Expression = { if ($rank.ContainsKey($_.Name)) { $rank[$_.Name] } else { [int]::MaxValue } } },
        @{ Expression = { $_.Length }; Descending = $true }, FullName)
}

# --- PURA: nomes dos Describe de topo, quando o arquivo pode ser fatiado por eles ---------------
# Um arquivo não se divide entre workers, e o mais pesado vira o teto do check inteiro (medido em
# 2026-10-17: scaffold-upgrade, 154 s sozinho, com o resto pronto antes). Os da PesterHeavyFirst
# rodam uma fatia por Describe, filtrada por `Filter.FullName`. Devolve vazio (= não fatiar) quando
# o filtro por nome não acharia os testes: Describe com template `<x>` ou `-ForEach`/`-TestCases`
# (o nome expandido difere do escrito), nome repetido, ou um Describe só.
function Get-PesterDescribeShard {
    param([Parameter(Mandatory)][string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $top = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.PipelineAst] } |
        ForEach-Object { $_.PipelineElements } | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandAst] -and $_.GetCommandName() -eq 'Describe' })
    $nomes = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $top) {
        $el = @($d.CommandElements)
        if ($el.Count -lt 2 -or $el[1] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return @() }
        $param = @($el | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        if ($param -contains 'ForEach' -or $param -contains 'TestCases' -or $el[1].Value -match '<') { return @() }
        $nomes.Add($el[1].Value)
    }
    if ($nomes.Count -lt 2 -or @($nomes | Select-Object -Unique).Count -ne $nomes.Count) { return @() }
    $nomes.ToArray()
}

# --- Itens da fila: um por arquivo, ou um por Describe nos pesados que se deixam fatiar ---------
function Get-PesterQueueItem {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.IO.FileInfo[]]$Files)
    foreach ($f in @(Get-PesterQueueOrder -Files $Files)) {
        $fatias = @(if ($script:PesterHeavyFirst -contains $f.Name) { Get-PesterDescribeShard -Path $f.FullName })
        if ($fatias.Count -eq 0) { [pscustomobject]@{ Path = $f.FullName; Shard = ''; Label = $f.Name }; continue }
        foreach ($s in $fatias) { [pscustomobject]@{ Path = $f.FullName; Shard = $s; Label = "$($f.Name) :: $s" } }
    }
}

# --- Pester paralelo: N processos pwsh puxando de uma fila em disco (tools/pester-worker.ps1) ---
# Devolve um objeto com os mesmos contadores do resultado do Invoke-Pester que o check lê, mais
# `Files` (tempo por arquivo) e `FailedTests`. Arquivo que nenhum worker terminou (worker caiu)
# entra como container falho: teste que não rodou não pode passar por teste que passou.
function Invoke-PesterParallel {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.IO.FileInfo[]]$Files,
        [Parameter(Mandatory)][int]$Jobs
    )
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("sdd-pester-" + [guid]::NewGuid().ToString('N'))
    $queue = Join-Path $work 'queue'
    $null = New-Item -ItemType Directory -Path $queue -Force
    try {
        $ordem = @(Get-PesterQueueItem -Files $Files)
        for ($i = 0; $i -lt $ordem.Count; $i++) {
            # 1ª linha: o arquivo; 2ª: o Describe da fatia (vazia = arquivo inteiro).
            [System.IO.File]::WriteAllText((Join-Path $queue ('{0:D4}.job' -f $i)), "$($ordem[$i].Path)`n$($ordem[$i].Shard)")
        }
        $pwsh = (Get-Process -Id $PID).Path
        $worker = Join-Path $PSScriptRoot 'pester-worker.ps1'
        $n = [math]::Max(1, [math]::Min($Jobs, $ordem.Count))
        $procs = for ($w = 0; $w -lt $n; $w++) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new($pwsh)
            foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $worker, '-QueueDir', $queue, '-OutFile', (Join-Path $work "out-$w.jsonl"))) {
                $psi.ArgumentList.Add($a)
            }
            $psi.WorkingDirectory = $Root
            $psi.UseShellExecute = $false
            # Console PRÓPRIO por worker. A página de código é do console, não do processo: medido em
            # 2026-10-17, um teste noutro worker que põe [Console]::OutputEncoding em UTF-8 (o
            # bash-guards-gate faz, e todo hook .ps1 também) mudava a página de todos, e o
            # scaffold-upgrade capturava `j├í em dia` da saída de um pwsh filho.
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            # Ler os dois streams de forma assíncrona: buffer cheio de stdout trava o filho.
            [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
        }
        foreach ($x in $procs) { $x.Proc.WaitForExit() }

        $recs = @(Get-ChildItem -LiteralPath $work -Filter 'out-*.jsonl' -File | ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
            })
        $feitos = @{}
        foreach ($r in $recs) { $feitos["$($r.File)|$($r.Shard)"] = $true }
        $containers = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $recs) {
            $rotulo = if ($r.Shard) { "$(Split-Path -Leaf $r.File) :: $($r.Shard)" } else { Split-Path -Leaf $r.File }
            foreach ($m in @($r.FailedContainers)) { $containers.Add("$rotulo ($m)") }
            # Fatia que não rodou teste nenhum quer dizer filtro que não casou: os testes dela
            # sumiriam da contagem sem falhar. Reprova.
            if ($r.Shard -and ($r.Passed + $r.Failed + $r.Skipped) -eq 0 -and @($r.FailedContainers).Count -eq 0) {
                $containers.Add("$rotulo (a fatia não rodou nenhum teste: o filtro por Describe não casou)")
            }
        }
        $erroWorker = (@($procs | Where-Object { $_.Proc.ExitCode -ne 0 } | ForEach-Object { ($_.Err.Result -split "`r?`n")[0] }) | Select-Object -First 1)
        foreach ($f in $ordem) {
            if (-not $feitos.ContainsKey("$($f.Path)|$($f.Shard)")) { $containers.Add("$($f.Label) (nenhum worker terminou este item: $erroWorker)") }
        }
        # Suíte verde sem teste executado não mede nada (a mesma regra que os workflows aplicavam à mão).
        $total = @($recs | ForEach-Object { $_.Passed + $_.Failed + $_.Skipped } | Measure-Object -Sum)[0].Sum
        if ($ordem.Count -gt 0 -and -not $total) { $containers.Add('nenhum teste executou: o gate não mediu nada') }
        # `Measure-Object -Property` sem entrada não emite nada, e o `.Sum` lançaria sob StrictMode
        # quando nenhum worker grava resultado; a forma sem -Property sempre emite (Sum = 0).
        $soma = { param($Campo) [int](@($recs | ForEach-Object { $_.$Campo } | Measure-Object -Sum)[0].Sum) }
        [pscustomobject]@{
            PassedCount           = & $soma 'Passed'
            FailedCount           = & $soma 'Failed'
            SkippedCount          = & $soma 'Skipped'
            FailedContainersCount = $containers.Count
            FailedContainerNames  = $containers.ToArray()
            FailedTests           = @($recs | ForEach-Object { @($_.FailedTests) } | Where-Object { $_ })
            Files                 = @($recs | Sort-Object Seconds -Descending)
            Workers               = $n
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PesterCheck {
    param(
        [string]$Root = $script:RepoRoot,
        [string[]]$Exclude = @(),
        # Alvos relativos à raiz (arquivos ou pastas). Vazio = as duas suítes inteiras.
        [string[]]$Path = @(),
        # 1 = sequencial, num Invoke-Pester só (o que os testes deste runner fazem mock). >1 = fila paralela.
        [int]$Jobs = 1
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # As suítes são infra de dev: o espelho não distribui `tools/tests/` nem `onboarding/tests/`.
    # Sem elas, o `Invoke-Pester` não lança — escreve o erro e devolve $null, e o check saía `FAIL`
    # com o detalhe " passed /  failed /  skipped" (medido, Pester 5.7.1).
    $alvos = if (@($Path | Where-Object { $_ }).Count -gt 0) { @($Path | Where-Object { $_ }) } else { @('onboarding/tests', 'tools/tests') }
    $suites = @($alvos | ForEach-Object { Join-Path $Root $_ } |
        Where-Object { Test-Path -LiteralPath $_ })
    if ($suites.Count -eq 0) {
        return New-CheckResult -Name 'Pester' -Ok $false -Status 'n/a' `
            -Detail 'nenhuma suite no disco (o espelho não distribui tools/tests/ nem onboarding/tests/)' -Seconds $sw.Elapsed.TotalSeconds
    }
    if (-not (Test-CheckModule -Name 'Pester' -MinimumVersion '5.0')) {
        return New-CheckResult -Name 'Pester' -Ok $false -Status 'n/a' `
            -Detail 'módulo ausente — Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser' -Seconds $sw.Elapsed.TotalSeconds
    }
    try {
        # Só o que existe: um nome errado aqui não exclui nada, e o detalhe abaixo conta o que de
        # fato ficou de fora — "fora do escopo: 0" com -ExcludeTest passado denuncia o erro.
        $fora = @($Exclude | Where-Object { $_ } | ForEach-Object { Join-Path $Root $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($Jobs -gt 1) {
            $foraFull = @($fora | ForEach-Object { [System.IO.Path]::GetFullPath($_) })
            $arquivos = @($suites | ForEach-Object {
                    if (Test-Path -LiteralPath $_ -PathType Leaf) { Get-Item -LiteralPath $_ }
                    else { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter '*.Tests.ps1' }
                } | Where-Object { $foraFull -notcontains $_.FullName })
            $r = Invoke-PesterParallel -Root $Root -Files $arquivos -Jobs $Jobs
            $sw.Stop()
            if (-not $script:Quiet) {
                # Tempo por arquivo, do mais caro: é o insumo para mexer no PesterHeavyFirst e em
                # qualquer corte futuro. Antes vinha nas linhas [+] do Pester sequencial.
                Write-Host "Pester paralelo: $($r.Workers) worker(s), $(@($r.Files).Count) item(ns) de $($arquivos.Count) arquivo(s)"
                @($r.Files) | Select-Object -First 15 | ForEach-Object {
                    $rot = if ($_.Shard) { "$(Split-Path -Leaf $_.File) :: $($_.Shard)" } else { Split-Path -Leaf $_.File }
                    Write-Host ("  {0,7:N1}s  {1}" -f $_.Seconds, $rot)
                }
                foreach ($t in @($r.FailedTests)) { Write-Host "[-] $($t.Name)`n    $($t.Message)" }
            }
            $falhos = @($r.FailedContainerNames)
        }
        else {
            $cfg = New-PesterConfiguration
            $cfg.Run.Path = $suites
            if ($fora.Count -gt 0) { $cfg.Run.ExcludePath = $fora }
            $cfg.Run.PassThru = $true
            $cfg.Output.Verbosity = $(if ($script:Quiet) { 'None' } else { 'Normal' })
            $r = Invoke-Pester -Configuration $cfg
            $sw.Stop()
            $falhos = $null
        }
        # Container que falha na DISCOVERY não conta em `FailedCount`: os `It` dele nunca chegam a
        # existir, e o próprio container sai com `Result = Passed` (medido, Pester 5.7.1). Em
        # 2026-09-26 o `perfil-claims.Tests.ps1` rodava 1 de 10 testes sob o StrictMode deste runner,
        # e o check só não saiu verde porque outro teste falhava ao mesmo tempo. O que conta é
        # `FailedContainersCount` — teste que não roda não pode passar por teste que passou.
        # O mesmo contador pega erro de TEARDOWN (o `curation-nudge.Tests.ps1`, com o handle preso no
        # TestDrive: os `It` rodaram e passaram), então o detalhe não afirma "não rodou" — diz que o
        # erro foi fora dos `It` e mostra a 1ª linha dele, que é o que distingue um caso do outro.
        # Sob `-Quiet` o Pester não imprime nada, e sem isto a causa se perdia (2026-09-26).
        if ($null -eq $falhos) {
            $falhos = @($r.FailedContainers | ForEach-Object {
                    $er = $_.PSObject.Properties['ErrorRecord']
                    $msg = @($(if ($er) { $er.Value }) | ForEach-Object { $_.Exception.Message }) | Select-Object -First 1
                    $msg = (([string]$msg) -split "`r?`n")[0]
                    if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + '…' }
                    "$(Split-Path -Leaf ([string]$_.Item)) ($msg)"
                })
        }
        $detail = "$($r.PassedCount) passed / $($r.FailedCount) failed / $($r.SkippedCount) skipped"
        if (@($Exclude | Where-Object { $_ }).Count -gt 0) { $detail += " / fora do escopo: $($fora.Count) arquivo(s)" }
        if ($r.FailedContainersCount -gt 0) {
            $detail += " / $($r.FailedContainersCount) arquivo(s) com erro fora dos It: $($falhos -join '; ')"
        }
        return New-CheckResult -Name 'Pester' -Ok ($r.FailedCount -eq 0 -and $r.FailedContainersCount -eq 0) `
            -Detail $detail -Seconds $sw.Elapsed.TotalSeconds
    }
    catch {
        $sw.Stop()
        return New-CheckResult -Name 'Pester' -Ok $false -Detail "exceção: $($_.Exception.Message)" -Seconds $sw.Elapsed.TotalSeconds
    }
}

# --- Check: coletor do Apps Script (lógica pura, em Node) --------------------------------------
# Por que entrou no runner em 2026-09-06: `docs/apps-script/collector.test.js` existia desde
# 2026-07 e NADA o rodava. Era o mesmo padrão do command-lint e do command-table-lint acima — um
# teste escrito, versionado, citado no README ("valida a lógica pura") e nunca executado por
# ninguém além de quem o digitasse à mão. O coletor é a ponta que grava o tráfego do site numa
# planilha; a lógica dele (host-check, anti-fórmula, mapa de 26 colunas, reparo de cabeçalho)
# passou a ser conferida a cada rodada, como tudo o mais.
#
# Roda em Node porque o alvo é um `.gs` de Apps Script: `collector.test.js` o carrega com
# `new Function` e exercita só as funções puras — `doPost`/`doGet` são DEFINIDOS e nunca chamados,
# então nenhum runtime do Google é tocado. Custo medido: ~0,1s.
#
# Sem `node` no PATH o check REPROVA em vez de passar em silêncio. Um check que fica verde por não
# ter conseguido rodar é a pior das duas falhas: some da vista justamente quando deixou de medir.
function Invoke-CollectorCheck {
    param([string]$Root = $script:RepoRoot)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # O teste mora em `docs/apps-script/`, que o espelho não distribui: sem ele não há o que
        # checar (`n/a`). Vem ANTES do `node`: sem o arquivo, a falta do node não importa. Com o
        # arquivo no disco e sem node, segue `FAIL` — o onboarding instala o node.
        $teste = Join-Path $Root 'docs/apps-script/collector.test.js'
        if (-not (Test-Path -LiteralPath $teste -PathType Leaf)) {
            $sw.Stop()
            return New-CheckResult -Name 'collector' -Ok $false -Status 'n/a' `
                -Detail 'collector.test.js não está no disco (docs/apps-script/ não é distribuído)' -Seconds $sw.Elapsed.TotalSeconds
        }
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) {
            $sw.Stop()
            return New-CheckResult -Name 'collector' -Ok $false -Detail 'node ausente no PATH — não rodou' -Seconds $sw.Elapsed.TotalSeconds
        }
        $saida = & $node.Source $teste 2>&1
        $code = $LASTEXITCODE
        $sw.Stop()

        # A contagem sai do próprio relato do teste. Zero caso relatado com saída 0 seria um teste
        # que não testou nada — e ficaria verde. Aqui isso reprova.
        $casos = @($saida | Select-String -Pattern '^\s*ok - ' -AllMatches).Count
        $ok = ($code -eq 0) -and ($casos -gt 0)

        if (-not $ok -and -not $script:Quiet) { $saida | Out-String | Write-Host }

        $detalhe = if ($code -ne 0) { "reprovou (saiu $code, $casos caso[s] antes)" }
                   elseif ($casos -eq 0) { 'nenhum caso relatado — o teste não testou nada' }
                   else { "$casos casos ok" }
        return New-CheckResult -Name 'collector' -Ok $ok -Detail $detalhe -Seconds $sw.Elapsed.TotalSeconds
    }
    catch {
        $sw.Stop()
        return New-CheckResult -Name 'collector' -Ok $false -Detail "exceção: $($_.Exception.Message)" -Seconds $sw.Elapsed.TotalSeconds
    }
}

# --- Plano dos lints de conformidade (escopos = fonte única; espelha o ci.yml) -----------------
function Get-LintPlan {
    # Os scriptblocks rodam depois (em Invoke-LintCheck) -> referenciam $script:Scaffold/$script:RepoRoot
    # (escopo de script, sempre acessível), nunca locais (PS não captura locais em scriptblock).
    @(
        @{ Name = 'config-lint'; Tool = 'config-lint.ps1'
            Findings = {
                $files = Get-ChildItem -Path (Join-Path $script:RepoRoot 'templates') -Recurse -Filter '*settings*.json' -File
                @($files | ForEach-Object { Get-ConfigLintFindings -Text (Get-Content $_.FullName -Raw) -Source (Resolve-Path -Relative $_.FullName) })
            }
            Gate = { param($f) Test-ConfigLintGate -Findings $f }; Report = { param($f) Format-ConfigLintReport -Findings $f }
        }
        @{ Name = 'hooks-lint'; Tool = 'hooks-lint.ps1'
            Findings = { Invoke-HookLint -Dirs @((Join-Path $script:RepoRoot 'templates/global-claude/hooks'), (Join-Path $script:RepoRoot 'templates/global-claude/hooks/lib'), "$script:Scaffold/hooks") }
            Gate = { param($f) Test-HookLintGate -Findings $f }; Report = { param($f) Format-HookLintReport -Findings $f }
        }
        @{ Name = 'agent-lint'; Tool = 'agent-lint.ps1'
            Findings = { Invoke-AgentLint -Dir "$script:Scaffold/agents" }
            Gate = { param($f) Test-AgentLintGate -Findings $f }; Report = { param($f) Format-AgentLintReport -Findings $f }
        }
        # command-lint EXISTIA mas NÃO era chamado por ninguém (nem aqui, nem no CI) — enquanto o
        # rules/tooling.md afirmava "Verificado por command-lint.ps1: dot-source cru BLOQUEIA o CI".
        # A promessa era falsa: o lint que mecanizaria a regra era ele próprio uma regra sem
        # mecanismo. Ligado em 2026-07-13. Cobre: missing-description, raw-tools-dotsource e
        # orphan-posture (postura que nenhum command lê).
        @{ Name = 'command-lint'; Tool = 'command-lint.ps1'
            Findings = { Invoke-CommandLint -Dir "$script:Scaffold/commands" }
            Gate = { param($f) Test-CommandLintGate -Findings $f }; Report = { param($f) Format-CommandLintReport -Findings $f }
        }
        # Mesmo caso do command-lint: o CHANGELOG (v0.5.x) o anuncia como "9º lint do check.ps1", mas
        # ele NUNCA foi ligado — e o próprio header dizia "trava essa divergência no CI". Ligado em
        # 2026-07-13. Pega drift entre a tabela de commands do CLAUDE.md e .claude/commands/ real.
        @{ Name = 'command-table-lint'; Tool = 'command-table-lint.ps1'
            # $script:Scaffold já aponta para .../project-scaffold/.claude — o CLAUDE.md é o irmão dele.
            Findings = { Invoke-CommandTableLint -ClaudeMd (Join-Path (Split-Path $script:Scaffold -Parent) 'CLAUDE.md') -CommandsDir "$script:Scaffold/commands" }
            Gate = { param($f) Test-CommandTableLintGate -Findings $f }; Report = { param($f) Format-CommandTableLintReport -Findings $f }
        }
        # O irmao que faltava do de cima, ligado em 2026-08-16. A tabela de agentes do
        # rules/agent-routing.md e escrita a mao, e always-on e NAO tinha lint nenhum: a coluna
        # "Quando usar" tinha virado uma segunda copia do `description` que o harness ja injeta
        # (1 568 b dos 2 561 b da secao), e o unico dado nao-duplicado dela -- "usado pelo /review-diff e
        # ao fim do /build" -- estava FALSO (nenhum dos dois menciona o code-reviewer; quem invoca e
        # /doubt, /iterate e /orchestrate). Trava o CONJUNTO de nomes (error) e o orcamento de ~12
        # palavras/linha (warn). Custo: ~0,01 s.
        @{ Name = 'agent-table-lint'; Tool = 'agent-table-lint.ps1'
            Findings = { Invoke-AgentTableLint -RulePath "$script:Scaffold/rules/agent-routing.md" -AgentsDir "$script:Scaffold/agents" }
            Gate = { param($f) Test-AgentTableLintGate -Findings $f }; Report = { param($f) Format-AgentTableLintReport -Findings $f }
        }
        # O terceiro irmao, ligado em 2026-08-22. A lista de rules do AGENTS.md (bloco marcado
        # `rules`) e a UNICA porta para harness que nao varre .claude/rules/ -- Codex e Antigravity,
        # ambos confirmados na doc de cada um. Ela estava com 10 de 12: faltavam documentation.md e
        # orchestration.md, e a segunda carrega o gate de regime. No Claude Code o drift e' invisivel
        # (o diretorio auto-carrega), e era por isso que ninguem via. O bloco e' escrito pelo AGENTE
        # (prosa no /sync-context), nao pelo Invoke-Resync, entao o resync-lint nao o cobria.
        @{ Name = 'rules-list-lint'; Tool = 'rules-list-lint.ps1'
            # $script:Scaffold aponta para .../project-scaffold/.claude -- o AGENTS.md e' o irmao dele.
            Findings = { Invoke-RulesListLint -AgentsMdPath (Join-Path (Split-Path $script:Scaffold -Parent) 'AGENTS.md') -RulesDir "$script:Scaffold/rules" }
            Gate = { param($f) Test-RulesListLintGate -Findings $f }; Report = { param($f) Format-RulesListLintReport -Findings $f }
        }
        # Ligado em 2026-09-25 (REGRA_DE_AREA_SEM_DESTINO). Rule com `paths:` so' carrega quando o
        # modelo le arquivo casado -- glob que nao casa nada e' rule que nunca chega, sem erro nenhum.
        # Aqui guarda as do scaffold (docs-first, kb-taxonomy); no projeto, a secao `rules` do /check.
        # Advisory: so' warn. Custo: um `git ls-files` do scaffold.
        @{ Name = 'path-rules-lint'; Tool = 'path-rules-lint.ps1'
            Findings = { @(Invoke-PathRulesLint -Root (Split-Path $script:Scaffold -Parent)) }
            Gate = { param($f) Test-PathRulesLintGate -Findings $f }; Report = { param($f) Format-PathRulesLintReport -Findings $f }
        }
        # Ligado em 2026-07-13, REVERTENDO a decisão de 2026-06-20 (ficar fora do CI, postura
        # low-friction) — com evidência: o AGENT_MAP.md COMMITADO no scaffold estava stale (faltava
        # /complementary-repos), então TODO projeto novo nascia com o mapa velho, e nada avisou. Um
        # artefato derivado que entra no template errado é defeito de produto, não fricção de dev.
        # Custo real: ~0,1 s (o driver gera em memória, escreve 0 bytes).
        @{ Name = 'resync-lint'; Tool = 'resync-lint.ps1'
            Findings = { Invoke-ResyncLint -ClaudeDir $script:Scaffold }
            Gate = { param($f) Test-ResyncLintGate -Findings $f }; Report = { param($f) Format-ResyncLintReport -Findings $f }
        }
        # Ligado em 2026-07-20, depois do dano: VERSION dizia 0.9.0 e o CHANGELOG documentava 0.9.0,
        # 0.8.32 e 0.8.31 — a última tag era v0.8.30. Três releases sem tag, e nada avisou porque
        # NENHUM script criava tag (taguear era ato de disciplina). Cobre só do baseline 0.8.10 para
        # cima e isenta a versão ATUAL — a janela entre bumpar VERSION e taguear é legítima; ver o
        # .DESCRIPTION do lint, que registra as duas isenções e por que sem elas ele nasceria
        # vermelho (39 versões históricas). Inerte sem git. Custo: ~0,1 s (um `git tag -l`).
        @{ Name = 'release-lint'; Tool = 'release-lint.ps1'
            Findings = { Invoke-ReleaseLint -RepoRoot $script:RepoRoot }
            Gate = { param($f) Test-ReleaseLintGate -Findings $f }; Report = { param($f) Format-ReleaseLintReport -Findings $f }
        }
        # Ligado em 2026-07-20, depois do dano: um usuário rodou o bootstrap remoto e a instalação
        # morreu no parse — 97 scripts tinham acento SEM BOM UTF-8, e o Windows PowerShell 5.1 (o
        # host onde a maioria cola o `irm | iex` do README) lê arquivo sem BOM como ANSI. Nada
        # avisou porque dev e CI rodam em pwsh 7, que assume UTF-8 e NUNCA reproduz a falha: é um
        # defeito que só existe no runtime do usuário. Custo: ~0,1 s (3 bytes por arquivo).
        @{ Name = 'encoding-lint'; Tool = 'encoding-lint.ps1'
            Findings = { Invoke-EncodingLint -RepoRoot $script:RepoRoot }
            Gate = { param($f) Test-EncodingLintGate -Findings $f }; Report = { param($f) Format-EncodingLintReport -Findings $f }
        }
        # Ligado em 2026-07-23, depois do dano: um projeto scaffolded viu o /status listar como
        # "build em andamento" uma feature já encerrada — o BUILD_REPORT tinha ficado em reports/
        # porque o passo 3 do /ship dizia "mova/APONTE" e nada verificava a invariante. A redação do
        # command virou imperativa no mesmo ciclo; este lint é o backstop. Roda no dogfood (a própria
        # raiz tem .claude/sdd/) e no alvo via /check. Custo: ~0,01 s (dois Get-ChildItem).
        @{ Name = 'sdd-lint'; Tool = 'sdd-lint.ps1'
            Findings = { Invoke-SddLint -Root $script:RepoRoot }
            Gate = { param($f) Test-SddLintGate -Findings $f }; Report = { param($f) Format-SddLintReport -Findings $f }
        }
        @{ Name = 'link-lint'; Tool = 'link-lint.ps1'
            # Link relativo quebrado nos .md — exclui gitignored e .claude/sdd/archive/ (histórico
            # imutável: a reorg v2 deixou ~70 lá, cobrá-los seria arqueologia). Ver o .DESCRIPTION.
            Findings = { Invoke-LinkLint -Root $script:RepoRoot }
            Gate = { param($f) Test-LinkLintGate -Findings $f }; Report = { param($f) Format-LinkLintReport -Findings $f }
        }
        @{ Name = 'pii-lint'; Tool = 'pii-lint.ps1'
            # PII na SUPERFÍCIE DISTRIBUÍDA (F4): exclui a camada dev/meta (features/, .claude/,
            # CHANGELOG.md, docs/DECISOES.md) — que fica intacta no canônico e fora da distribuição (A9).
            Findings = {
                $deny = Read-PiiDenylist -Path (Join-Path $script:RepoRoot '.claude/pii-denylist.txt')
                # Identificadores públicos por construção (handle do espelho nas URLs de bootstrap/docs):
                # mascarados antes do scan — paridade com o SCAN do publish.ps1 (.claude/pii-allowlist.txt).
                $allow = Read-PiiDenylist -Path (Join-Path $script:RepoRoot '.claude/pii-allowlist.txt')
                $dirs = @('onboarding', 'templates', 'methodology', 'tools') | ForEach-Object { Join-Path $script:RepoRoot $_ }
                $exts = '.md', '.ps1', '.sh', '.psd1', '.psm1', '.json', '.yml', '.yaml', '.txt'
                $files = [System.Collections.Generic.List[string]]::new()
                Get-ChildItem -Path $dirs -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $exts -contains $_.Extension } | ForEach-Object { $files.Add($_.FullName) }
                # PII_LINT_CEGO_A_LANDING (2026-09-16): a lista era só-`.md` e deixava de fora a
                # landing, que É distribuída desde a D-19. O `publish` reprovou no SCAN (passo 3) por
                # um primeiro nome solto num comentário HTML do card de autor — o re-scan do subset
                # pegou o que o gate local não via. Aqui o gate local passa a cobrir os MESMOS
                # arquivos de `docs/` que o manifesto distribui.
                #
                # A lista fica escrita à mão de propósito: derivá-la de `Get-DistributionFileList`
                # exigiria dot-sourcar `tools/publish.ps1`, que o espelho NÃO recebe — e o `check.ps1`
                # roda lá também. Ao acrescentar arquivo distribuído em `docs/`, acrescente aqui.
                foreach ($rf in @('README.md', 'docs/VISAO.md', 'docs/USO.md', 'docs/HARNESS-CONTRACT.md',
                        'docs/TUTORIAL.md', 'docs/index.html', 'docs/privacidade.html', 'docs/MEDICOES.md',
                        # Arquivos de comunidade da raiz e de .github/ (2026-10-18): distribuídos, e
                        # o CODE_OF_CONDUCT carrega o contato do mantenedor.
                        'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md',
                        '.github/FUNDING.yml', '.github/pull_request_template.md',
                        '.github/ISSUE_TEMPLATE/bug_report.yml', '.github/ISSUE_TEMPLATE/feature_request.yml',
                        '.github/ISSUE_TEMPLATE/config.yml')) {
                    $full = Join-Path $script:RepoRoot $rf
                    if (Test-Path -LiteralPath $full) { $files.Add($full) }
                }
                # Honra o .gitignore ANTES de escanear: um `.venv`/`node_modules` na working tree traz
                # arquivos de TERCEIROS (SBOMs, LICENSE) com nomes que casam a denylist — falsos
                # positivos por algo que NÃO é distribuído (o STAGE do publish já os remove). Paridade
                # com a superfície real. Select-NotGitIgnored (pii-lint.ps1) fatia em lotes (ver lá).
                $scan = @(Select-NotGitIgnored -Root $script:RepoRoot -Files $files.ToArray())
                Invoke-PiiLint -Path $scan -Denylist $deny -Allowlist $allow
            }
            Gate = { param($f) Test-PiiLintGate -Findings $f }; Report = { param($f) Format-PiiLintReport -Findings $f }
        }
    )
}

# --- PURA: resumo legível dos resultados ------------------------------------------------------
function Format-CheckSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    $isNa = { param($r) $r.PSObject.Properties['Status'] -and $r.Status -eq 'n/a' }
    foreach ($r in $Results) {
        $mark = if (& $isNa $r) { '[ n/a]' } elseif ($r.Ok) { '[ OK ]' } else { '[FAIL]' }
        $lines.Add(("{0} {1,-18} {2}  ({3}s)" -f $mark, $r.Name, $r.Detail, $r.Seconds))
    }
    $na = @($Results | Where-Object { & $isNa $_ })
    $failed = @($Results | Where-Object { -not $_.Ok -and -not (& $isNa $_) })
    $naNames = ($na | ForEach-Object { $_.Name }) -join ', '
    $lines.Add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    if ($failed.Count -gt 0) {
        $tail = if ($na.Count -gt 0) { " · n/a: $naNames" } else { '' }
        $lines.Add("❌ FALHOU — $($failed.Count)/$($Results.Count): $((($failed | ForEach-Object { $_.Name }) -join ', '))$tail")
    }
    elseif ($na.Count -gt 0) {
        # Sem falha não é "verde": o n/a não mediu. O veredito diz o que ficou de fora.
        $lines.Add("⚠️ INCOMPLETO — $($Results.Count - $na.Count)/$($Results.Count) mediram e passaram; n/a: $naNames")
    }
    else {
        $lines.Add("✅ TUDO VERDE — $($Results.Count) check(s)")
    }
    return ($lines -join [Environment]::NewLine)
}

# --- PURA: anotações do GitHub Actions para o que não passou ----------------------------------
# O veredito é ADVISORY (exit 0 sempre), e no CI isso escondia a falha: o run saía verde e só quem
# abrisse o log via o [FAIL]. Medido em 2026-09-13: o teste do release-lint reprovou nos 10 últimos
# runs "verdes" do ci.yml. Uma linha `::warning` por check aparece no resumo do run sem mudar a
# postura (continua não bloqueando). O n/a também avisa, com outra frase: no CI ele quer dizer que
# o runner ficou cego para aquele check, e foi exatamente essa a classe do release-lint.
function Format-CheckAnnotation {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)
    $isNa = { param($r) $r.PSObject.Properties['Status'] -and $r.Status -eq 'n/a' }
    @($Results | Where-Object { -not $_.Ok } | ForEach-Object {
        # Sem o escape, uma quebra de linha no detalhe corta a anotação no meio (sintaxe do runner).
        $detail = ([string]$_.Detail) -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
        $verbo = if (& $isNa $_) { 'não mediu (n/a)' } else { 'falhou' }
        "::warning title=check.ps1 (advisory)::$($_.Name) $verbo — $detail"
    })
}

# --- Orquestra todos os checks ----------------------------------------------------------------
function Invoke-Check {
    [CmdletBinding()]
    param([switch]$SkipPester, [string[]]$ExcludeTest = @(), [switch]$SkipAnalyzer, [switch]$SkipBudget, [switch]$Quiet,
        [int]$PesterJobs = 0)

    $script:Quiet = [bool]$Quiet   # propaga a flag aos helpers (que leem $script:Quiet)
    $results = [System.Collections.Generic.List[object]]::new()
    $jobs = if ($PesterJobs -gt 0) { $PesterJobs } else { Get-PesterDefaultJobs }

    # O PSScriptAnalyzer (~40 s local, ~90 s no CI) roda numa thread ao lado do Pester em vez de
    # antes dele. Com o Pester sequencial (-PesterJobs 1) segue em série, como sempre foi.
    $analyzerJob = $null
    if (-not $SkipAnalyzer) {
        if ($jobs -gt 1 -and -not $SkipPester -and (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
            $checkPs1 = Join-Path $PSScriptRoot 'check.ps1'
            $quietNow = $script:Quiet
            $analyzerJob = Start-ThreadJob -ScriptBlock {
                . $using:checkPs1
                $script:Quiet = $using:quietNow
                Invoke-AnalyzerCheck
            }
        }
        else { $results.Add((Invoke-AnalyzerCheck)) }
    }
    foreach ($c in (Get-LintPlan)) {
        $results.Add((Invoke-LintCheck -Name $c.Name -Tool $c.Tool -Findings $c.Findings -Gate $c.Gate -Report $c.Report))
    }
    $results.Add((Invoke-CollectorCheck))
    if (-not $SkipPester) { $pesterResult = Invoke-PesterCheck -Exclude $ExcludeTest -Jobs $jobs }
    if ($analyzerJob) {
        $a = @(Receive-Job -Job $analyzerJob -Wait -AutoRemoveJob | Where-Object { $_.PSObject.Properties['Status'] }) | Select-Object -Last 1
        if (-not $a) { $a = New-CheckResult -Name 'PSScriptAnalyzer' -Ok $false -Detail 'exceção: a thread do analyzer não devolveu resultado' }
        $results.Insert(0, $a)
    }
    if (-not $SkipPester) { $results.Add($pesterResult) }

    # Bloco ADVISORY (G8 v2): retrato do contexto always-on (total + ranking). Imprime, mas NÃO entra no
    # veredito (AllOk). Sem teto/%: informar ≠ julgar. Usa o $Quiet LOCAL (não $script:Quiet).
    if (-not $SkipBudget -and -not $Quiet) {
        try {
            . (Join-Path $PSScriptRoot 'rules-budget.ps1')
            $b = Invoke-RulesBudget -Quiet
            Write-Host ''
            Write-Host ("ⓘ retrato (não afeta o veredito) — " + $b.Summary)
            if ($b.Report) { Write-Host $b.Report }
        }
        catch {
            Write-Host "ⓘ retrato: rules-budget indisponível ($($_.Exception.Message))"
        }
    }

    $summary = Format-CheckSummary -Results $results.ToArray()
    Write-Host $summary
    return [pscustomobject]@{ Results = $results.ToArray(); AllOk = (@($results | Where-Object { -not $_.Ok }).Count -eq 0); Summary = $summary }
}

# --- Guard: roda só quando NÃO dot-sourced (Pester/CI fazem `. check.ps1`) ---------------------
# ADVISORY (postura low-friction): reporta o veredito mas NUNCA bloqueia (exit 0 sempre). Quem quiser
# tratar como gate lê $sum.AllOk via dot-source. CI/local ficam informativos, não impeditivos.
if ($MyInvocation.InvocationName -ne '.') {
    $sum = Invoke-Check -SkipPester:$SkipPester -ExcludeTest $ExcludeTest -SkipAnalyzer:$SkipAnalyzer -SkipBudget:$SkipBudget -Quiet:$Quiet -PesterJobs $PesterJobs
    if (-not $sum.AllOk) {
        if ($env:GITHUB_ACTIONS -eq 'true') { Format-CheckAnnotation -Results $sum.Results | ForEach-Object { Write-Host $_ } }
        Write-Host '(advisory — não bloqueia; exit 0)'
    }
    exit 0
}
