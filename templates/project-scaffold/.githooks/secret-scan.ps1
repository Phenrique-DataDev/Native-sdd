<#
.SYNOPSIS
    git pre-commit — bloqueia (exit 1) o commit se houver segredo no que esta STAGED.

.DESCRIPTION
    Rede DETERMINISTICA do #1: protege contra qualquer agente E erro humano, nao so o Claude.
    Chamado pelo shim .githooks/pre-commit. Verifica:
      - arquivos staged cujo PATH é de segredo (.env, *.pem, id_rsa, secrets/…)  -> bloqueia
      - segredo de ALTA confianca nas linhas adicionadas do diff staged          -> bloqueia

    Usa a lib UNICA de deteccao (secret-patterns.ps1). Procura-a, em ordem:
      1. $PSScriptRoot/secret-patterns.ps1                       (copia vendorizada no scaffold — padrao)
      2. $env:USERPROFILE/.claude/hooks/lib/secret-patterns.ps1  (instalada pelo onboarding — fallback)
    A copia em .githooks/ é IDENTICA a canonica (templates/global-claude/hooks/lib/) — um teste
    anti-drift garante isso no repo do framework. Sem nenhuma das duas -> AVISA e NAO bloqueia
    (degradacao graciosa; o secret-guard do Claude + a managed policy seguem valendo).

    Só ALTA confianca bloqueia (baixo falso-positivo). Ruido medio fica para o hook "ask".
    Bypass consciente: git commit --no-verify.

    Compativel com Windows PowerShell 5.1+ e PowerShell 7+.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Carrega a lib unica de deteccao -----------------------------------------------------------
$libCandidates = @(
    (Join-Path $PSScriptRoot 'secret-patterns.ps1'),
    (Join-Path $env:USERPROFILE '.claude/hooks/lib/secret-patterns.ps1')
)
$lib = $libCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $lib) {
    Write-Host "[pre-commit] lib de deteccao de segredos nao encontrada — varredura PULADA." -ForegroundColor Yellow
    Write-Host "             (instale o onboarding ou copie secret-patterns.ps1 para .githooks/)" -ForegroundColor DarkGray
    exit 0
}
. $lib

# --- Coleta o que esta staged (read-only) ------------------------------------------------------
function Get-StagedFile {
    $files = & git diff --cached --name-only --diff-filter=ACM 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($files | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
}

function Get-StagedAddedLine {
    $d = & git diff --cached --unified=0 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $text = ($d -join "`n")
    $added = foreach ($line in ($text -split "`r?`n")) {
        if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) { $line.Substring(1) }
    }
    return ($added -join "`n")
}

# --- Avaliacao ---------------------------------------------------------------------------------
$problems = New-Object System.Collections.Generic.List[string]

foreach ($f in (Get-StagedFile)) {
    if (Test-IsSecretFilePath $f) {
        $problems.Add("arquivo de segredo no commit: $f")
    }
}

$findings = Find-SecretMatch -Text (Get-StagedAddedLine) -MinConfidence 'High'
foreach ($hit in $findings) {
    $problems.Add("$($hit.Pattern) detectado (amostra: $($hit.Sample))")
}

if ($problems.Count -eq 0) { exit 0 }

# --- Bloqueio ----------------------------------------------------------------------------------
Write-Host ''
Write-Host '  COMMIT BLOQUEADO — possivel segredo no que esta staged:' -ForegroundColor Red
foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Yellow }
Write-Host ''
Write-Host '  Remova/rotacione o segredo e refaca o stage. Se for falso-positivo:' -ForegroundColor DarkGray
Write-Host '    git commit --no-verify   (pula a verificacao conscientemente)' -ForegroundColor DarkGray
Write-Host ''
exit 1
