<#
.SYNOPSIS
    Runner único de verificação: roda PSScriptAnalyzer + todos os lints de conformidade + Pester,
    agrega o resultado e devolve um veredito (exit 0 = tudo verde).

.DESCRIPTION
    Fonte ÚNICA dos escopos de verificação do repo — o `ci.yml` chama este script em vez de repetir
    o boilerplate de cada lint. Localmente: `pwsh tools/check.ps1` (antes de abrir PR).

    Cada check devolve { Name; Ok; Detail; Seconds }. Dot-source dos `*-lint.ps1` é isolado por check.
    Pré-requisito: módulos `Pester` (≥5) e `PSScriptAnalyzer` instalados (o CI os instala antes).

    Flags:
      -SkipPester     pula a suíte Pester (iteração rápida só nos lints estáticos)
      -SkipAnalyzer   pula o PSScriptAnalyzer (o mais lento)
      -SkipBudget     pula o retrato de contexto always-on (rules-budget, G8 v2)
      -Quiet          só o resumo final (omite o relatório detalhado de cada lint que falhar)

    Uso por função (igual aos outros tools): `. ./tools/check.ps1 ; Invoke-Check`.
    Como script: `pwsh tools/check.ps1 [-SkipPester] [-SkipAnalyzer] [-Quiet]` (exit 0/1).
#>

[CmdletBinding()]
param(
    [switch]$SkipPester,
    [switch]$SkipAnalyzer,
    [switch]$SkipBudget,
    [switch]$Quiet
)

Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Scaffold = Join-Path $script:RepoRoot 'templates/project-scaffold/.claude'
# NÃO reinicializar $script:Quiet aqui: o param `$Quiet` de nível-script JÁ é $script:Quiet, e um reset
# clobbaria um `-Quiet` passado (a guard repassa o valor à Invoke-Check, que o propaga aos helpers).

# --- PURA: monta o objeto-resultado de um check ----------------------------------------------
function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Detail = '',
        [double]$Seconds = 0
    )
    [pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Seconds = [math]::Round($Seconds, 1) }
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
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $settings = Join-Path $script:RepoRoot 'onboarding/PSScriptAnalyzerSettings.psd1'
        $issues = @('onboarding', 'tools') | ForEach-Object {
            Invoke-ScriptAnalyzer -Path (Join-Path $script:RepoRoot $_) -Recurse -Settings $settings
        }
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
function Invoke-PesterCheck {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = (Join-Path $script:RepoRoot 'onboarding/tests'), (Join-Path $script:RepoRoot 'tools/tests')
        $cfg.Run.PassThru = $true
        $cfg.Output.Verbosity = $(if ($script:Quiet) { 'None' } else { 'Normal' })
        $r = Invoke-Pester -Configuration $cfg
        $sw.Stop()
        return New-CheckResult -Name 'Pester' -Ok ($r.FailedCount -eq 0) `
            -Detail "$($r.PassedCount) passed / $($r.FailedCount) failed / $($r.SkippedCount) skipped" `
            -Seconds $sw.Elapsed.TotalSeconds
    }
    catch {
        $sw.Stop()
        return New-CheckResult -Name 'Pester' -Ok $false -Detail "exceção: $($_.Exception.Message)" -Seconds $sw.Elapsed.TotalSeconds
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
        @{ Name = 'standards-lint'; Tool = 'standards-lint.ps1'
            Findings = { Invoke-StandardsLint -Path @("$script:Scaffold/rules/workflow-sdd.md", "$script:Scaffold/commands/define.md", "$script:Scaffold/commands/build.md", "$script:Scaffold/commands/ship.md", "$script:Scaffold/commands/review.md") }
            Gate = { param($f) Test-StandardsLintGate -Findings $f }; Report = { param($f) Format-StandardsLintReport -Findings $f }
        }
        @{ Name = 'doubt-lint'; Tool = 'doubt-lint.ps1'
            Findings = { Invoke-DoubtLint -RulePath "$script:Scaffold/rules/doubt-driven.md" -CommandPath "$script:Scaffold/commands/doubt.md" }
            Gate = { param($f) Test-DoubtLintGate -Findings $f }; Report = { param($f) Format-DoubtLintReport -Findings $f }
        }
        @{ Name = 'hooks-lint'; Tool = 'hooks-lint.ps1'
            Findings = { Invoke-HookLint -Dirs @((Join-Path $script:RepoRoot 'templates/global-claude/hooks'), (Join-Path $script:RepoRoot 'templates/global-claude/hooks/lib'), "$script:Scaffold/hooks") }
            Gate = { param($f) Test-HookLintGate -Findings $f }; Report = { param($f) Format-HookLintReport -Findings $f }
        }
        @{ Name = 'agent-lint'; Tool = 'agent-lint.ps1'
            Findings = { Invoke-AgentLint -Dir "$script:Scaffold/agents" }
            Gate = { param($f) Test-AgentLintGate -Findings $f }; Report = { param($f) Format-AgentLintReport -Findings $f }
        }
        @{ Name = 'doc-lint'; Tool = 'doc-lint.ps1'
            Findings = { Invoke-DocLint -RulePath "$script:Scaffold/rules/documentation.md" -CommandPath "$script:Scaffold/commands/document.md" }
            Gate = { param($f) Test-DocLintGate -Findings $f }; Report = { param($f) Format-DocLintReport -Findings $f }
        }
        @{ Name = 'command-lint'; Tool = 'command-lint.ps1'
            Findings = { Invoke-CommandLint -Dir "$script:Scaffold/commands" }
            Gate = { param($f) Test-CommandLintGate -Findings $f }; Report = { param($f) Format-CommandLintReport -Findings $f }
        }
        @{ Name = 'command-table-lint'; Tool = 'command-table-lint.ps1'
            # Drift entre a tabela marcada `commands` do CLAUDE.md e os arquivos de .claude/commands/.
            Findings = { Invoke-CommandTableLint -ClaudeMdPath "$script:RepoRoot/templates/project-scaffold/CLAUDE.md" -CommandsDir "$script:Scaffold/commands" }
            Gate = { param($f) Test-CommandTableLintGate -Findings $f }; Report = { param($f) Format-CommandTableLintReport -Findings $f }
        }
        @{ Name = 'pii-lint'; Tool = 'pii-lint.ps1'
            # PII na SUPERFÍCIE DISTRIBUÍDA (F4): exclui a camada dev/meta (features/, .claude/,
            # CHANGELOG.md, docs/DECISOES.md) — que fica intacta no canônico e fora da distribuição (A9).
            Findings = {
                $deny = Read-PiiDenylist -Path (Join-Path $script:RepoRoot '.claude/pii-denylist.txt')
                $dirs = @('onboarding', 'templates', 'methodology', 'tools') | ForEach-Object { Join-Path $script:RepoRoot $_ }
                $exts = '.md', '.ps1', '.sh', '.psd1', '.psm1', '.json', '.yml', '.yaml', '.txt'
                $files = [System.Collections.Generic.List[string]]::new()
                Get-ChildItem -Path $dirs -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $exts -contains $_.Extension } | ForEach-Object { $files.Add($_.FullName) }
                foreach ($rf in @('README.md', 'docs/VISAO.md', 'docs/USO.md', 'docs/HARNESS-CONTRACT.md')) {
                    $full = Join-Path $script:RepoRoot $rf
                    if (Test-Path -LiteralPath $full) { $files.Add($full) }
                }
                Invoke-PiiLint -Path $files.ToArray() -Denylist $deny
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
    foreach ($r in $Results) {
        $mark = if ($r.Ok) { '[ OK ]' } else { '[FAIL]' }
        $lines.Add(("{0} {1,-18} {2}  ({3}s)" -f $mark, $r.Name, $r.Detail, $r.Seconds))
    }
    $failed = @($Results | Where-Object { -not $_.Ok })
    $lines.Add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    if ($failed.Count -eq 0) {
        $lines.Add("✅ TUDO VERDE — $($Results.Count) check(s)")
    }
    else {
        $lines.Add("❌ FALHOU — $($failed.Count)/$($Results.Count): $((($failed | ForEach-Object { $_.Name }) -join ', '))")
    }
    return ($lines -join [Environment]::NewLine)
}

# --- Orquestra todos os checks ----------------------------------------------------------------
function Invoke-Check {
    [CmdletBinding()]
    param([switch]$SkipPester, [switch]$SkipAnalyzer, [switch]$SkipBudget, [switch]$Quiet)

    $script:Quiet = [bool]$Quiet   # propaga a flag aos helpers (que leem $script:Quiet)
    $results = [System.Collections.Generic.List[object]]::new()

    if (-not $SkipAnalyzer) { $results.Add((Invoke-AnalyzerCheck)) }
    foreach ($c in (Get-LintPlan)) {
        $results.Add((Invoke-LintCheck -Name $c.Name -Tool $c.Tool -Findings $c.Findings -Gate $c.Gate -Report $c.Report))
    }
    if (-not $SkipPester) { $results.Add((Invoke-PesterCheck)) }

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
if ($MyInvocation.InvocationName -ne '.') {
    $sum = Invoke-Check -SkipPester:$SkipPester -SkipAnalyzer:$SkipAnalyzer -SkipBudget:$SkipBudget -Quiet:$Quiet
    exit ([int](-not $sum.AllOk))
}
