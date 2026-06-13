<#
.SYNOPSIS
    hooks-lint (J4) — verifica que os hooks versionados sao PORTAVEIS.

.DESCRIPTION
    Espelha o padrao dos demais lints do repo (standards-lint/config-lint/agent-lint): funcoes
    PURAS + I/O fino, sem dependencia externa, dot-sourceaveis para teste.

    Checa:
      - error `missing-sh-pair` : um hook `*.ps1` (guard) sem o par `*.sh` ao lado -> nao portavel.
    E expoe `Get-HookDispatchCommand`, a forma canonica do `command` portavel (D-001) registrado no
    settings.json: tenta `pwsh` (com ele, roda o .ps1 atual = zero regressao); sem ele, cai p/ `bash`.

    A verificacao real do COMPORTAMENTO (paridade .ps1 x .sh) vive em tools/tests/hooks-portable.Tests.ps1;
    este lint so garante a ESTRUTURA (todo guard tem par shell) e a forma do dispatch.
#>

Set-StrictMode -Version Latest

# PURA: monta um finding (mesmo shape dos demais lints).
function New-HookFinding {
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Severity = $Severity; Rule = $Rule; Path = $Path; Message = $Message }
}

# PURA: a dispatch-line POSIX que escolhe o runtime (D-001). Um settings.json, cross-OS.
function Get-HookDispatchCommand {
    param(
        [Parameter(Mandatory)][string]$PsPath,
        [Parameter(Mandatory)][string]$ShPath
    )
    return "sh -c 'if command -v pwsh >/dev/null 2>&1; then exec pwsh -NoProfile -File `"`$1`"; else exec bash `"`$2`"; fi' _ `"$PsPath`" `"$ShPath`""
}

# PURA: dada a lista de nomes de arquivo de um diretorio de hooks, aponta os .ps1 sem par .sh.
# (Considera apenas guards de hook; a lib/ tambem entra se houver .ps1 com .sh — generico por nome.)
function Get-HookPairFindings {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FileNames,
        [string]$Source = '(hooks)'
    )
    $set = @{}
    foreach ($f in $FileNames) { $set[$f.ToLowerInvariant()] = $true }
    $findings = @()
    foreach ($f in $FileNames) {
        if ($f -notmatch '\.ps1$') { continue }
        $sh = ($f -replace '\.ps1$', '.sh').ToLowerInvariant()
        if (-not $set.ContainsKey($sh)) {
            $findings += New-HookFinding -Severity 'error' -Rule 'missing-sh-pair' -Path "$Source/$f" `
                -Message "hook '$f' nao tem o par '.sh' — nao roda sem pwsh (J4: portabilidade)."
        }
    }
    return @($findings)
}

# PURA: relatorio legivel (mesmo formato dos demais lints).
function Format-HookLintReport {
    param([AllowEmptyCollection()][object[]]$Findings)
    if (-not $Findings -or $Findings.Count -eq 0) { return 'hooks-lint: OK (todos os hooks tem par .sh).' }
    $lines = foreach ($f in $Findings) { '[{0}] {1} — {2} ({3})' -f $f.Severity.ToUpper(), $f.Rule, $f.Message, $f.Path }
    return ($lines -join "`n")
}

# PURA: gate — $false se ha >=1 error.
function Test-HookLintGate {
    param([AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

# I/O fino: varre diretorios de hooks e agrega os findings de pareamento.
function Invoke-HookLint {
    param([Parameter(Mandatory)][string[]]$Dirs)
    $all = @()
    foreach ($d in $Dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        $names = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $rel = $d -replace '[\\/]+$', ''
        $all += Get-HookPairFindings -FileNames $names -Source $rel
    }
    return @($all)
}
