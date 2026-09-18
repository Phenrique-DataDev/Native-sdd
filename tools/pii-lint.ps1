<#
.SYNOPSIS
    Lint de PII na SUPERFÍCIE DISTRIBUÍDA: pega nome/e-mail/handle pessoal antes de
    versionar/distribuir o produto. Feature F4 (parte PII).

.DESCRIPTION
    Funções PURAS (recebem texto, sem tocar disco) + um I/O fino. Espelha tools/config-lint.ps1
    e tools/config-lint.ps1 (sem módulo externo). Dois detectores:

      - email     (error)  e-mail no formato `local@dominio` + TLD, exceto placeholders/exemplos
                           (`@example.`, `@exemplo.`, `noreply@`).
      - denylist  (error)  termo literal de uma lista externa (nome/handle/sobrenome),
                           comparação case-insensitive por substring.

    A denylist vive FORA da superfície distribuída (ex.: `.claude/pii-denylist.txt`, camada
    dev/meta excluída da distribuição — ver A9) — assim os termos pessoais não viajam no produto.

    Severidade: tudo `error` (PII na superfície distribuída bloqueia o CI/gate).
    Opt-out: um arquivo que contenha o marcador `pii-lint:disable` é pulado inteiro — reservado
    aos arquivos-meta que precisam conter os padrões/fixtures (o próprio lint e seu teste).
#>

Set-StrictMode -Version Latest

# E-mail genérico (suficiente p/ pegar vazamento). Allowlist de placeholders/exemplos abaixo.
$script:EmailPattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# Substrings que marcam um e-mail como placeholder/exemplo (não-PII). Comparação minúscula.
$script:EmailAllow = @('@example.', '@exemplo.', 'noreply@')

function New-PiiFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-PiiFindings {
    <#
    .SYNOPSIS  E-mails + termos da denylist no TEXTO. Reporta por linha ("$Source:<n>").
    .OUTPUTS   [pscustomobject[]] (vazio = limpo)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source,
        [string[]]$Denylist = @()
    )

    if ([string]::IsNullOrEmpty($Text)) { return @() }

    $findings = [System.Collections.Generic.List[object]]::new()
    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $ln = $i + 1

        foreach ($m in [regex]::Matches($line, $script:EmailPattern)) {
            $email = $m.Value
            $low = $email.ToLowerInvariant()
            $allowed = $false
            foreach ($a in $script:EmailAllow) { if ($low.Contains($a)) { $allowed = $true; break } }
            if (-not $allowed) {
                $findings.Add((New-PiiFinding -Severity error -Rule email `
                            -Path "${Source}:${ln}" -Message "e-mail pessoal: '$email'"))
            }
        }

        foreach ($term in $Denylist) {
            if ([string]::IsNullOrWhiteSpace($term)) { continue }
            if ($line.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $findings.Add((New-PiiFinding -Severity error -Rule denylist `
                            -Path "${Source}:${ln}" -Message "termo de PII (denylist): '$term'"))
            }
        }
    }
    return $findings.ToArray()
}

function Read-PiiDenylist {
    <# .SYNOPSIS  Lê a denylist (um termo por linha; ignora '#'/vazias). Ausente -> array vazio. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $out.Add($t)
    }
    return $out.ToArray()
}

function Format-PiiLintReport {
    <# .SYNOPSIS  Painel legível dos achados, agrupado por arquivo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'pii-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $byFile = $Findings | Group-Object { ($_.Path -split ':\d+$')[0] }
    foreach ($g in $byFile) {
        $lines.Add("• $($g.Name)")
        foreach ($f in $g.Group) {
            $lines.Add("    [$($f.Severity)] $($f.Rule) $($f.Path) — $($f.Message)")
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-PiiLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-PiiLint {
    <#
    .SYNOPSIS  I/O fino: lê cada arquivo, pula os com marcador 'pii-lint:disable', agrega achados.
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [string[]]$Denylist = @(),
        [string[]]$Allowlist = @()
    )

    $all = @()
    foreach ($p in $Path) {
        try {
            $text = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
        }
        catch {
            $all += New-PiiFinding -Severity error -Rule unreadable -Path "$p" `
                -Message "arquivo ilegível: $($_.Exception.Message)"
            continue
        }
        if ([string]::IsNullOrEmpty($text)) { continue }
        if ($text -match 'pii-lint:\s*disable') { continue }   # opt-out (arquivos-meta: o próprio lint/teste)
        # Identificadores PÚBLICOS por construção (ex.: handle do espelho): mascarados ANTES do
        # scan — mesma técnica do SCAN do publish.ps1 (ver .claude/pii-allowlist.txt).
        foreach ($a in $Allowlist) {
            if ([string]::IsNullOrWhiteSpace($a)) { continue }
            $text = $text -replace [regex]::Escape($a), '__PUBLIC_ID__'
        }
        $src = try { Resolve-Path -Relative -LiteralPath $p } catch { $p }
        $all += Get-PiiFindings -Text $text -Source $src -Denylist $Denylist
    }
    return @($all)
}

# --- I/O compartilhada: filtra paths que o git ignora, EM LOTES ------------------------------
function Select-NotGitIgnored {
    <# .SYNOPSIS
         De $Files (rel ou absolutos, sob $Root), devolve os que o git NÃO ignora.
       .DESCRIPTION
         Por que EM LOTES: `git check-ignore @Files` recebe os paths como ARGUMENTOS. Uma working
         tree com um diretório gitignored volumoso (ex.: um `.venv` de ~3k arquivos do semantic-kb)
         estoura o limite de linha de comando do Windows (~32k chars) — e o PowerShell reporta isso
         com a mensagem enganosa "StandardOutputEncoding is only supported when standard output is
         redirected". Fatiar em lotes pequenos mantém cada invocação abaixo do limite, para QUALQUER
         volume. check-ignore ecoa só os IGNORADOS (exit 0=algum, 1=nenhum, 128=erro → 2>$null).

         FONTE ÚNICA: usada pelo VERIFY (pii-lint do check.ps1, para não escanear o `.venv`) E pelo
         STAGE do publish (Remove-GitIgnored delega aqui) — o subset distribuído e a superfície
         escaneada passam a concordar sobre "o que o git ignora fica de fora". #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files,
        [int]$BatchSize = 100
    )
    if ($Files.Count -eq 0) { return @() }
    # Normaliza '\' -> '/' ANTES de passar ao git: recebendo '/', o check-ignore ecoa o path "limpo";
    # recebendo '\' (FullName do Windows), ele CITA/ESCAPA a saída ("C:\\...") e a comparação falha.
    # Devolvemos o path ORIGINAL (o chamador usa rel OU absoluto) — só o matching é normalizado.
    $norm = @($Files | ForEach-Object { $_ -replace '\\', '/' })
    $ignSet = @{}
    for ($i = 0; $i -lt $norm.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize, $norm.Count) - 1
        $batch = @($norm[$i..$end])
        $ignored = git -C $Root check-ignore @batch 2>$null
        foreach ($ig in @($ignored)) { $ignSet[($ig -replace '\\', '/')] = $true }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    for ($j = 0; $j -lt $Files.Count; $j++) {
        if (-not $ignSet.ContainsKey($norm[$j])) { $out.Add($Files[$j]) }
    }
    return @($out)
}
