<#
.SYNOPSIS
    verification — lê os comandos de verificação que o projeto DECLAROU na seção `## Verificação`
    (ou `## Verification`) do `.claude/rules/project-context.md`. Fonte única para /dev, /build,
    /iterate, o gate do /orchestrate e o CI do /setup (VERIFICACAO_SEM_COMANDO_DECLARADO, 2026-10-19).

.DESCRIPTION
    Read-only. Antes, cada command deduzia sozinho como verificar o projeto, e o único detector
    (Test-IterateVerifiable) só conhecia 4 sinais e nenhum lint.

      - Get-ProjectVerification : tabela `| etapa | `comando` |` → { Install; Lint; Test; Declared }.
                                  Célula com `—`, `-`, vazia ou placeholder `<...>` vale $null.
      - Get-VerificationCommand : Lint e Test numa linha só (cada célula num pwsh filho, `&&`) + os critérios do
                                  gate (LintClean/TestsGreen). $null sem teste declarado.

    Compatível com PowerShell 7+.
#>

Set-StrictMode -Version Latest

$script:VerificationHeading = '^##\s+(Verificação|Verificacao|Verification)\s*$'
$script:VerificationSteps = @('install', 'lint', 'test')

function Get-ProjectVerification {
    <#
    .SYNOPSIS
        Comandos declarados no project-context.md. Declared = há comando de teste.
        Arquivo ausente ou sem a seção → tudo $null, Declared $false (quem chama cai no fallback).
    .OUTPUTS
        [pscustomobject] { Install; Lint; Test; Declared }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $found = @{ install = $null; lint = $null; test = $null }
    $path = Join-Path $Root '.claude/rules/project-context.md'

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $inSection = $false
        foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
            if ($line -match '^##\s') { $inSection = ($line -match $script:VerificationHeading); continue }
            if (-not $inSection) { continue }
            # | test | `python -m pytest -q` |
            if ($line -notmatch '^\|\s*`?([A-Za-z]+)`?\s*\|\s*(.*?)\s*\|\s*$') { continue }
            $step = $Matches[1].ToLowerInvariant()
            if ($step -notin $script:VerificationSteps) { continue }
            $cell = $Matches[2].Trim()
            if ($cell -match '^`(.*)`$') { $cell = $Matches[1].Trim() }
            if ($cell -eq '' -or $cell -in '—', '-', 'n/a', 'N/A' -or $cell -match '^<.*>$') { $cell = $null }
            $found[$step] = $cell
        }
    }

    return [pscustomobject]@{
        Install  = $found.install
        Lint     = $found.lint
        Test     = $found.test
        Declared = (-not [string]::IsNullOrWhiteSpace($found.test))
    }
}

function Get-VerificationCommand {
    <#
    .SYNOPSIS
        A linha que verifica o projeto (lint antes do teste, cada um num pwsh filho) e os critérios que ela
        decide no gate. $null quando não há teste declarado.
    .OUTPUTS
        [pscustomobject] { Verifier; Required[] } ou $null
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $v = Get-ProjectVerification -Root $Root
    if (-not $v.Declared) { return $null }
    if ($v.Lint) {
        # Cada célula num pwsh filho: `exit 0 && teste` encerra o host antes do teste (verde falso,
        # medido 2026-10-26), e `exit $x && $g = …` é ParserError. Base64 evita citar aspas da célula.
        $cell = { param($c) 'pwsh -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($c)) }
        return [pscustomobject]@{ Verifier = "$(& $cell $v.Lint) && $(& $cell $v.Test)"; Required = @('LintClean', 'TestsGreen') }
    }
    return [pscustomobject]@{ Verifier = [string]$v.Test; Required = @('TestsGreen') }
}
