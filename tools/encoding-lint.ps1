<#
.SYNOPSIS
    Acusa script PowerShell que tem caractere não-ASCII mas NÃO tem BOM UTF-8 — a combinação que
    quebra o parser do Windows PowerShell 5.1.

    ACHADO EM USO REAL (2026-07-20): um usuário rodou o bootstrap remoto e a instalação morreu na
    etapa final. Causa: `onboarding/windows/lib.ps1` (e mais 96 arquivos) tinham acento SEM BOM. O
    5.1 lê arquivo sem BOM como ANSI (code page do sistema), então "órfãos" vira "Ã³rfÃ£os", a aspa
    curva U+201D vira delimitador de string, e o parse do arquivo INTEIRO explode antes de qualquer
    linha executar. O bootstrap delega ao install.ps1 usando o MESMO host que o invocou — e a porta
    de entrada documentada no README é `irm | iex`, que a maioria cola num powershell.exe 5.1.

    Por que ninguém viu antes: todo o desenvolvimento e o CI rodam em pwsh 7, que assume UTF-8 sem
    BOM por padrão e nunca reproduz a falha. O bug só existe no runtime do usuário.

.DESCRIPTION
    Regra única, binária e barata (lê 3 bytes + faz um match por arquivo):

      no-bom-utf8 : arquivo contém byte >= 0x80 e não começa com EF BB BF.

    Escopo: `.ps1` / `.psd1` / `.psm1` rastreados pelo git. Arquivos 100% ASCII são ignorados de
    propósito — sem caractere não-ASCII não há ambiguidade de encoding, e exigir BOM neles só criaria
    ruído (é o caso de `onboarding/bootstrap.ps1`, que é ASCII-only por decisão de design justamente
    porque é servido como texto cru via HTTP e avaliado com Invoke-Expression).

    Severidade só `error`: o alvo é determinístico e a consequência é um script que não parseia.
    Shape canônico dos demais lints (New-*Finding / Get-*Findings / Format-* / Test-*Gate / Invoke-*).

    Correção de um achado: gravar o arquivo como "UTF-8 with BOM". Em pwsh:
      $c = Get-Content -Raw -LiteralPath <arquivo>
      [System.IO.File]::WriteAllText(<arquivo>, $c, (New-Object System.Text.UTF8Encoding $true))
#>

Set-StrictMode -Version Latest

function New-EncodingFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Test-FileNeedsBom {
    <#
    .SYNOPSIS  PURA (dado o conteúdo em bytes): $true se o arquivo tem não-ASCII e não tem BOM UTF-8.
    .DESCRIPTION
        Opera sobre BYTES, nunca sobre string decodificada — decodificar já aplicaria uma suposição de
        encoding e apagaria justamente o sinal que queremos medir.
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    if ($Bytes.Count -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return $false   # já tem BOM
    }
    foreach ($b in $Bytes) { if ($b -ge 0x80) { return $true } }
    return $false       # ASCII puro — sem ambiguidade, nada a exigir
}

function Get-EncodingLintTarget {
    <#
    .SYNOPSIS  I/O: caminhos absolutos dos scripts PowerShell rastreados pelo git sob $RepoRoot.
    .DESCRIPTION
        `git ls-files` em vez de Get-ChildItem: pega só o que é NOSSO e versionado. Sem isso, um
        `.venv/Scripts/activate.ps1` de dependência de terceiro entraria no gate e o reprovaria por
        um arquivo que não podemos consertar (achado ao montar este lint).
    .OUTPUTS   [string[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $tracked = & git -C $RepoRoot ls-files '*.ps1' '*.psd1' '*.psm1' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tracked) { return @() }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $tracked) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $full = Join-Path $RepoRoot $rel
        if (Test-Path -LiteralPath $full -PathType Leaf) { $paths.Add($full) }
    }
    return $paths.ToArray()
}

function Get-EncodingFindings {
    <#
    .SYNOPSIS  I/O fino: lê os bytes de cada alvo e devolve um finding por arquivo sem BOM.
    .OUTPUTS   [pscustomobject[]] (vazio = tudo certo).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        [string]$RepoRoot
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $Path) {
        try { $bytes = [System.IO.File]::ReadAllBytes($file) }
        catch { continue }   # ilegível == fora do escopo; não é papel deste lint reportar I/O

        if (-not (Test-FileNeedsBom -Bytes $bytes)) { continue }

        $rel = if ($RepoRoot) { $file.Substring($RepoRoot.TrimEnd('\', '/').Length).TrimStart('\', '/') } else { $file }
        $findings.Add((New-EncodingFinding -Severity error -Rule no-bom-utf8 -Path "$rel#/" `
                    -Message 'tem caractere não-ASCII sem BOM UTF-8 — o Windows PowerShell 5.1 lê como ANSI e o parse do arquivo inteiro falha; regrave como "UTF-8 with BOM"'))
    }
    return $findings.ToArray()
}

function Format-EncodingLintReport {
    <# .SYNOPSIS  Painel legível dos achados. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'encoding-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $file = ($f.Path -split '#', 2)[0]
        $lines.Add("    [$($f.Severity)] $($f.Rule) $file — $($f.Message)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-EncodingLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (reprova o check). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-EncodingLint {
    <#
    .SYNOPSIS  Entrada de alto nível: descobre os alvos e devolve os achados.
    .OUTPUTS   [pscustomobject[]] de achados (vazio = tudo com BOM).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $targets = @(Get-EncodingLintTarget -RepoRoot $RepoRoot)
    return @(Get-EncodingFindings -Path $targets -RepoRoot $RepoRoot)
}
