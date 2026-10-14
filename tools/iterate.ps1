<#
.SYNOPSIS
    iterate (loop bounded "até o verde") — parte determinística do /iterate: elegibilidade da task,
    verificabilidade do projeto, o ELO determinístico verifier→bool, stuck-detection e o estado
    resumível do laço. Sem engine — o motor é o Workflow nativo (loop-until-green + budget +
    isolation:'worktree'); o verificador é o Test-TaskGate REUSADO de orchestrate.ps1.

.DESCRIPTION
    Funções dot-sourceáveis e testáveis. **Reusa o Test-TaskGate** (dot-source de `orchestrate.ps1`) —
    NÃO redefine o gate (é o mesmo juiz puro do /orchestrate). A convergência real do laço (corrigir →
    re-rodar até o verde) é runtime do Workflow/LLM; aqui mora só o determinístico:
      - ELEGIBILIDADE   : Test-IterateEligible  — a meta é da classe segura (determinística/reversível/
                          machine-verifiable)? Rejeita schema/IaC/dados/outward (tabela ForbiddenClasses).
      - VERIFICABILIDADE: Test-IterateVerifiable — há sinal verde/vermelho (suíte/lint)? Sem ele o
                          /iterate DEGRADA (nunca loop cego).
      - VERIFIER→BOOL   : Get-VerifierResult — o ELO determinístico (§4.2): roda o verifier e mapeia
                          exit-code → um BOOL REAL por critério (fail-closed). Alimenta o Test-TaskGate.
      - STUCK           : Test-StuckCondition — mesmo critério reprova N× consecutivas → para e escala.
      - ESTADO          : Get-IterateState/Format-IterateReport — STATE resumível (success/failed/
                          budget-exceeded), idempotente.

    Compatível com PowerShell 7+. Ver DESIGN_ITERATE.md.
#>

Set-StrictMode -Version Latest

# Reusa o Test-TaskGate (gate determinístico) do orchestrate.ps1. Só define funções (sem side-effects).
$script:IterateOrchestratePath = Join-Path $PSScriptRoot 'orchestrate.ps1'
if (-not (Test-Path -LiteralPath $script:IterateOrchestratePath -PathType Leaf)) {
    throw "iterate.ps1 requer tools/orchestrate.ps1 (não encontrado em $script:IterateOrchestratePath)."
}
. $script:IterateOrchestratePath

# Classes PROIBIDAS no auto-loop (D-005): sinais (regex, case-insensitive) por classe. Dados, não lógica.
# Guarda COARSE e honesta: a defesa real é em camadas (guarda + humano confirma + sandbox em worktree).
$script:ForbiddenClasses = [ordered]@{
    schema  = @('\bschema\b', 'migra', 'alter\s+table', 'drop\s+table', '/migrations?/')
    iac     = @('\bterraform\b', '\.tf\b', 'cloudformation', '\bhelm\b', '\bkubernetes\b', '\bk8s\b', '\bpulumi\b')
    data    = @('delete\s+from', '\btruncate\b', '\bbq\b', '\bclickhouse\b', 'aws\s+s3\s+rm', 'produ[cç][aã]o')
    outward = @('\bpush\b', 'pull\s+request', '\bPR\b', '\brelease\b', '\bdeploy\b', '\bpublish\b', '\bbrowser\b', 'deep-research')
}

# Sinais de "há verificador" (D-003): ordem; para no 1º que existir. Manifesto → comando + critérios.
$script:VerifierSignals = @(
    [pscustomobject]@{ Glob = '*.Tests.ps1';   Cmd = 'Invoke-Pester -CI'; Required = @('TestsGreen') }
    [pscustomobject]@{ Glob = 'pytest.ini';     Cmd = 'pytest -q';         Required = @('TestsGreen') }
    [pscustomobject]@{ Glob = 'package.json';   Cmd = 'npm test';          Required = @('TestsGreen') }
    [pscustomobject]@{ Glob = '*.csproj';       Cmd = 'dotnet test';       Required = @('TestsGreen') }
)

# --- PURA: a meta é elegível ao auto-loop? (rejeita por CLASSE proibida) ------------------------
function Test-IterateEligible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Goal,
        [string[]]$Paths = @()
    )

    $haystack = (@($Goal) + @($Paths)) -join "`n"
    foreach ($class in $script:ForbiddenClasses.Keys) {
        foreach ($sig in $script:ForbiddenClasses[$class]) {
            if ($haystack -imatch $sig) {
                return [pscustomobject]@{ Eligible = $false; Class = [string]$class; Matched = [string]$sig }
            }
        }
    }
    return [pscustomobject]@{ Eligible = $true; Class = ''; Matched = '' }
}

# --- PURA(-ish): há sinal verde/vermelho no projeto? (-Verifier explícito vence) ----------------
function Test-IterateVerifiable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$Verifier
    )

    if (-not [string]::IsNullOrWhiteSpace($Verifier)) {
        return [pscustomobject]@{ Verifiable = $true; Verifier = [string]$Verifier; Required = @('TestsGreen') }
    }
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        return [pscustomobject]@{ Verifiable = $false; Verifier = ''; Required = @() }
    }

    foreach ($sig in $script:VerifierSignals) {
        $hit = Get-ChildItem -LiteralPath $ProjectRoot -Filter $sig.Glob -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) {
            if ($sig.Glob -eq 'package.json') {
                # package.json só conta como verificador se declarar um script "test".
                $content = Get-Content -LiteralPath $hit.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -notmatch '"test"\s*:') { continue }
            }
            return [pscustomobject]@{ Verifiable = $true; Verifier = [string]$sig.Cmd; Required = @($sig.Required) }
        }
    }
    return [pscustomobject]@{ Verifiable = $false; Verifier = ''; Required = @() }
}

# --- SEAM (mockável nos testes): roda o verifier e devolve o exit-code; crash/timeout/spawn → $null
function Invoke-VerifierCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Verifier,
        [int]$TimeoutSec = 0   # 0 = sem teto aqui (o teto duro é o timeout do Workflow nativo).
    )

    $out = [System.IO.Path]::GetTempFileName()
    $err = "$out.err"
    try {
        $psArgs = @('-NoProfile', '-Command', $Verifier)
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList $psArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $out -RedirectStandardError $err
        if ($TimeoutSec -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
                try { $proc.Kill() } catch { $null = $_ }
                return $null   # timeout → vermelho (fail-closed)
            }
        }
        else {
            $proc.WaitForExit()
        }
        return [int]$proc.ExitCode
    }
    catch {
        return $null   # não rodou (spawn falhou) → vermelho (fail-closed)
    }
    finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

# --- O ELO DETERMINÍSTICO (§4.2): verifier → BOOL REAL por critério (fail-closed) ---------------
function Get-VerifierResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Verifier,
        [string[]]$Required = @('TestsGreen'),
        [int]$TimeoutSec = 0
    )

    $code = Invoke-VerifierCommand -Verifier $Verifier -TimeoutSec $TimeoutSec
    # exit 0 = verde; ≠0 OU $null (crash/timeout) = vermelho. NUNCA falso-verde por omissão.
    $green = ($null -ne $code -and $code -eq 0)

    $result = [ordered]@{}
    foreach ($c in @($Required)) { $result[$c] = [bool]$green }   # [bool] real — nunca string.
    return [pscustomobject]$result
}

# --- PURA: stuck? (mesmo critério reprovado em TODAS as últimas N voltas) -----------------------
function Test-StuckCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FailureHistory,
        [int]$Threshold = 5
    )

    $hist = @($FailureHistory)
    if ($Threshold -lt 1 -or $hist.Count -lt $Threshold) {
        return [pscustomobject]@{ Stuck = $false; Criterion = ''; Run = 0 }
    }

    $last = @($hist[$hist.Count - 1])   # critérios reprovados na última volta (string ou sub-array)
    foreach ($crit in $last) {
        $run = 0
        for ($i = $hist.Count - 1; $i -ge 0; $i--) {
            if (@($hist[$i]) -contains $crit) { $run++ } else { break }
        }
        if ($run -ge $Threshold) {
            return [pscustomobject]@{ Stuck = $true; Criterion = [string]$crit; Run = [int]$run }
        }
    }
    return [pscustomobject]@{ Stuck = $false; Criterion = ''; Run = 0 }
}

# --- PURA: estado resumível do laço a partir do STATE (idempotente) -----------------------------
function Get-IterateState {
    [CmdletBinding()]
    param([AllowNull()][string]$StatePath)

    $state = [ordered]@{
        Goal = ''; Status = 'running'; TerminalReason = ''
        Iteration = 0; Streak = 0; StuckCriterion = ''
        MaxIter = 0; StreakRequired = 1; StuckThreshold = 5
        Iterations = @()
    }
    if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return [pscustomobject]$state
    }

    $lines = Get-Content -LiteralPath $StatePath -ErrorAction SilentlyContinue
    $inIter = $false
    $cur = $null
    $iters = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^\S') {
            if ($cur) { $iters.Add([pscustomobject]$cur); $cur = $null }
            $inIter = ($line -match '^\s*iterations\s*:')
            if (-not $inIter) {
                if     ($line -match '^\s*goal\s*:\s*(.+?)\s*$')            { $state.Goal = $Matches[1].Trim().Trim('"').Trim("'") }
                elseif ($line -match '^\s*status\s*:\s*(.+?)\s*$')          { $state.Status = $Matches[1].Trim().Trim('"').Trim("'") }
                elseif ($line -match '^\s*terminal_reason\s*:\s*(.+?)\s*$') { $state.TerminalReason = $Matches[1].Trim().Trim('"').Trim("'") }
                elseif ($line -match '^\s*max_iter\s*:\s*(\d+)\s*$')        { $state.MaxIter = [int]$Matches[1] }
                elseif ($line -match '^\s*streak_required\s*:\s*(\d+)\s*$') { $state.StreakRequired = [int]$Matches[1] }
                elseif ($line -match '^\s*stuck_threshold\s*:\s*(\d+)\s*$') { $state.StuckThreshold = [int]$Matches[1] }
            }
            continue
        }
        if (-not $inIter) { continue }

        if ($line -match '^\s*-\s*n\s*:\s*(\d+)\s*$') {
            if ($cur) { $iters.Add([pscustomobject]$cur) }
            $cur = [ordered]@{ N = [int]$Matches[1]; GatePassed = $false; Failed = @() }
        }
        elseif ($cur) {
            if ($line -match '^\s*gate_passed\s*:\s*(.+?)\s*$') {
                $cur.GatePassed = ($Matches[1].Trim().Trim('"').Trim("'") -ieq 'true')
            }
            elseif ($line -match '^\s*failed\s*:\s*\[(.*)\]\s*$') {
                $inner = $Matches[1].Trim()
                $cur.Failed = if ($inner) { @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ }) } else { @() }
            }
        }
    }
    if ($cur) { $iters.Add([pscustomobject]$cur) }

    $state.Iterations = @($iters)
    $state.Iteration = if ($iters.Count -gt 0) { [int]$iters[$iters.Count - 1].N } else { 0 }

    # Streak = nº de gate_passed=true consecutivos no fim.
    $streak = 0
    for ($i = $iters.Count - 1; $i -ge 0; $i--) {
        if ($iters[$i].GatePassed) { $streak++ } else { break }
    }
    $state.Streak = [int]$streak

    # Stuck = mesmo critério reprovado nas últimas StuckThreshold voltas (sub-arrays preservados).
    $histList = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $iters) { $histList.Add(@($it.Failed)) }
    $stuck = Test-StuckCondition -FailureHistory $histList.ToArray() -Threshold $state.StuckThreshold
    $state.StuckCriterion = if ($stuck.Stuck) { [string]$stuck.Criterion } else { '' }

    # Status derivado — idempotente: se o STATE já declara terminal, respeita; senão deriva.
    if ($state.Status -notin @('success', 'failed', 'budget-exceeded')) {
        if ($iters.Count -gt 0 -and $streak -ge $state.StreakRequired) {
            $state.Status = 'success'; $state.TerminalReason = 'green-streak'
        }
        elseif ($stuck.Stuck) {
            $state.Status = 'failed'; $state.TerminalReason = 'stuck'
        }
        elseif ($state.MaxIter -gt 0 -and $state.Iteration -ge $state.MaxIter) {
            $state.Status = 'failed'; $state.TerminalReason = 'max-iter'
        }
        else {
            $state.Status = 'running'
        }
    }
    return [pscustomobject]$state
}

# --- PURA: painel determinístico do laço (sem timestamp; estilo Format-OrchestrationReport) -----
function Format-IterateReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$State)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    [void]$sb.Append("ITERATE — $($State.Goal)`n")
    $reason = if ($State.TerminalReason) { " ($($State.TerminalReason))" } else { '' }
    [void]$sb.Append("status: $($State.Status)$reason`n")
    [void]$sb.Append("iteração: $($State.Iteration)/$($State.MaxIter) · streak: $($State.Streak)/$($State.StreakRequired)`n")
    if ($State.StuckCriterion) {
        [void]$sb.Append("⚠ stuck: '$($State.StuckCriterion)' reprovou em sequência — para e escala`n")
    }
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}
