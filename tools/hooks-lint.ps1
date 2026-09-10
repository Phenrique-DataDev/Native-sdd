<#
.SYNOPSIS
    hooks-lint (J4) — verifica que os hooks versionados sao PORTAVEIS.

.DESCRIPTION
    Espelha o padrao dos demais lints do repo (config-lint/agent-lint): funcoes
    PURAS + I/O fino, sem dependencia externa, dot-sourceaveis para teste.

    Checa:
      - error `missing-sh-pair` : um hook `*.ps1` (guard) sem o par `*.sh` ao lado -> nao portavel.
      - error `missing-dir`     : um diretorio de hooks configurado que nao existe (rename/move da
                                  pasta -> o glob casaria 0 e o lint passaria em silencio).
      - error `no-targets`      : nenhum `.ps1` em NENHUM dos diretorios existentes (falso-verde por
                                  ausencia de alvo). Espelha o `missing-dir` do command-lint.
    E expoe `Get-HookDispatchCommand`, a forma canonica do `command` portavel (D-001) registrado no
    settings.json: tenta `pwsh` (com ele, roda o .ps1 atual = zero regressao); sem ele, cai p/ `bash`.

    A verificacao real do COMPORTAMENTO (paridade .ps1 x .sh) vive na suite de cada hook —
    destructive-guard, complementary-repo-guard — e o dispatch em hook-triggers.Tests.ps1.
    (Este bloco ja apontou DUAS vezes para alvo removido, no mesmo dia 2026-09-01:
    hooks-portable.Tests.ps1, apagado em 2111872, e agent-graph-context, retirado do scaffold
    por falta de efeito medido. Ponteiro em comentario nao tem lint que o cubra — confira o
    alvo ao editar.)
    Este lint so garante a ESTRUTURA (todo guard tem par shell) e a forma do dispatch.
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
#
# -SkipIf / -SkipArg (2026-08-14, GUARD_PRETOOLUSE_SEM_ALVO + HOOK_STARTUP_PWSH): teste POSIX
# opcional avaliado ANTES de subir o interpretador. Medido nesta maquina: `pwsh -NoProfile "exit 0"`
# custa ~274ms e `sh -c "exit 0"` ~36ms -- quando o .ps1 so vai ler um arquivo e sair calado, os
# 274ms sao o custo INTEIRO. O teste recebe o alvo em `$3` (nunca interpolado na expressao): assim
# o caminho aparece UMA vez por dispatch-line e da para compara-lo com a constante do .ps1 num
# teste, que e a unica defesa contra o `sh` e o `.ps1` divergirem sobre onde o estado mora.
#
# Duas invariantes deste gate, e as duas sao testadas:
#   1. FAIL-OPEN. Qualquer duvida (arquivo ausente, `find` ausente, erro) -> o teste da falso e o
#      pwsh sobe. O gate so pode ADIANTAR um `return` que o .ps1 ja faria; nunca suprimir saida.
#   2. DRENA O STDIN antes de sair -- sair sem ler o
#      payload deixaria o processo pai escrevendo num pipe fechado.
function Get-HookDispatchCommand {
    param(
        [Parameter(Mandatory)][string]$PsPath,
        [Parameter(Mandatory)][string]$ShPath,
        [string]$SkipIf = '',
        [string]$SkipArg = ''
    )
    $dispatch = "if command -v pwsh >/dev/null 2>&1; then exec pwsh -NoProfile -File `"`$1`"; else exec bash `"`$2`"; fi"
    if ([string]::IsNullOrWhiteSpace($SkipIf)) {
        return "sh -c '$dispatch' _ `"$PsPath`" `"$ShPath`""
    }
    return "sh -c 'if $SkipIf; then cat >/dev/null 2>&1; exit 0; fi; $dispatch' _ `"$PsPath`" `"$ShPath`" `"$SkipArg`""
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
    $totalPs1 = 0
    foreach ($d in $Dirs) {
        $rel = $d -replace '[\\/]+$', ''
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            $all += New-HookFinding -Severity 'error' -Rule 'missing-dir' -Path $rel `
                -Message "diretorio de hooks inexistente (rename/move? o lint passaria em silencio)."
            continue
        }
        $names = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $totalPs1 += @($names | Where-Object { $_ -match '\.ps1$' }).Count
        $all += Get-HookPairFindings -FileNames $names -Source $rel
    }
    if ($totalPs1 -eq 0) {
        $all += New-HookFinding -Severity 'error' -Rule 'no-targets' -Path '(hooks)' `
            -Message "nenhum hook .ps1 encontrado em nenhum diretorio — alvo vazio (falso-verde)."
    }
    return @($all)
}
