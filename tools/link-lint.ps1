<#
.SYNOPSIS
    link-lint — acusa link markdown RELATIVO que aponta para arquivo inexistente.

.DESCRIPTION
    POR QUE EXISTE (o dano que o motivou, 2026-08-14): uma varredura do scaffold achou três links
    relativos apontando para lugar nenhum — `[agent-routing.md](agent-routing.md)` num command
    (o arquivo está em `../rules/`), o mesmo erro numa postura, e o README do `semantic-kb`
    apontando para um path que a reorganização v2 moveu. Dois deles em arquivos DISTRIBUÍDOS:
    chegam a todo projeto criado pelo framework.

    É a família "regra sem mecanismo" que esta metodologia batiza, aplicada à própria documentação.
    O repositório tem lint para frontmatter, encoding, PII, staleness de artefato gerado e prosa de
    command — e nenhum para link relativo, que é a referência mais fácil de quebrar ao mover
    arquivo. Foi exatamente o que a reorg v2 fez, e nada avisou.

    Regra emitida:
      - broken-link (error) : link relativo cujo alvo não existe no disco.

    O QUE NÃO É VERIFICADO, e cada exclusão tem uma razão:
      - `http(s)://`, `mailto:`      : sairia da máquina; lint que depende de rede alheia fica
                                       vermelho por motivo que não é nosso (mesmo argumento que
                                       fechou metade do SUPPLEMENTS_DESCOBERTA).
      - âncora pura (`#secao`)       : é interna ao próprio arquivo; só é validada com -CheckAnchor.
      - alvo com `<` ou `>`          : PLACEHOLDER de template (`DESIGN_<FEATURE>.md`). Sem esta
                                       exclusão o lint nasce com 3 falsos-positivos permanentes nos
                                       templates SDD — medido antes de escrever.
      - a ÂNCORA de um link com path : `arquivo.md#secao` valida `arquivo.md` e ignora o `#secao`,
                                       salvo com -CheckAnchor.

    ÂNCORA (LINK_LINT_IGNORA_ANCORA, opt-in): `-CheckAnchor` valida `#secao` contra os headings do
    arquivo-alvo, com o slug do GitHub (minúsculas, só letra/número/`_`/`-`, cada espaço vira `-`,
    repetido ganha `-1`, `-2`), mais `<a id|name>` explícito. Só vale para alvo `.md`; `#L10` é
    referência de linha e passa. É opt-in porque o `link-lint` também roda no projeto do usuário
    (project-check), onde o custo de um falso positivo é do usuário; o `check.ps1` do repositório liga.

    ESCOPO (Get-LinkLintTarget): todo `.md` do repositório — inclusive sob diretório oculto, que no
    Unix é todo dot-dir, `.claude/` incluído — MENOS o `.git/`, MENOS o que o git ignora (reusa
    Select-NotGitIgnored do pii-lint — fonte única) e MENOS `.claude/sdd/archive/`. O archive é
    histórico imutável de features já encerradas: a reorg v2 consolidou `features/`+`reports/` em
    `archive/<slug>/` e deixou ~70 links quebrados lá dentro. Cobrá-los seria pedir arqueologia num
    passado que não causa dano — mesmo critério do baseline do `release-lint`. Se um dia o archive
    for reescrito, o lint já sabe varrer: é um parâmetro, não uma reescrita.

    Uso por função (igual aos outros tools): `. ./tools/link-lint.ps1 ; Invoke-LinkLint -Root .`
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'pii-lint.ps1')   # Select-NotGitIgnored (fonte única do filtro gitignore)

function New-LinkFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-MarkdownLink {
    <#
    .SYNOPSIS  PURA: extrai os alvos RELATIVOS verificáveis de um texto markdown.
    .OUTPUTS   [pscustomobject[]] @{ Target; Line }  — já sem externos/âncoras/placeholders.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$IncludeAnchor   # também devolve a âncora pura (Target = '') — para -CheckAnchor
    )

    $out = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return $out.ToArray() }

    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # `]( ... )` — para no 1º ')' ou espaço (título opcional do markdown: `](a.md "t")`).
        foreach ($m in [regex]::Matches($lines[$i], '\]\(([^)\s]+)')) {
            $raw = $m.Groups[1].Value
            if ($raw -match '^(https?:|mailto:)') { continue }     # externo
            if ($raw -match '[<>]') { continue }                   # placeholder de template
            $parts  = $raw -split '#', 2
            $target = $parts[0]                                    # mantém o path
            $anchor = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $null }
            if ([string]::IsNullOrWhiteSpace($target)) {
                if (-not ($IncludeAnchor -and $anchor)) { continue }   # âncora pura: só com o opt-in
            }
            $out.Add([pscustomobject]@{ Target = $target; Line = $i + 1; Anchor = $anchor })
        }
    }
    return $out.ToArray()
}

function ConvertTo-GitHubSlug {
    <#
    .SYNOPSIS  PURA: o slug que o GitHub dá a um heading (sem o sufixo de repetição).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Heading)
    $t = $Heading.Trim()
    $t = [regex]::Replace($t, '!?\[([^\]]*)\]\([^)]*\)', '$1')   # link/imagem -> só o texto
    $t = [regex]::Replace($t, '<[^>]+>', '')                     # HTML inline
    $t = $t -replace '[`*~]', ''
    $t = $t.ToLowerInvariant()
    $t = [regex]::Replace($t, '[^\p{L}\p{N}\p{M} _-]', '')       # emoji e pontuação saem; "A / B" -> "a  b"
    return ($t -replace ' ', '-')
}

function Get-MarkdownAnchor {
    <#
    .SYNOPSIS  PURA: os slugs de âncora válidos num texto markdown (headings ATX + <a id|name>).
    .OUTPUTS   [string[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $out  = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    if ([string]::IsNullOrEmpty($Text)) { return $out.ToArray() }
    $fence = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^ {0,3}(`{3,}|~{3,})') {
            $mark = $Matches[1][0]
            if ($null -eq $fence) { $fence = $mark } elseif ($fence -eq $mark) { $fence = $null }
            continue
        }
        if ($null -ne $fence) { continue }
        if ($line -match '^ {0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$') {
            $slug = ConvertTo-GitHubSlug -Heading $Matches[1]
            if ($seen.ContainsKey($slug)) { $seen[$slug]++; $out.Add("$slug-$($seen[$slug])") }
            else { $seen[$slug] = 0; $out.Add($slug) }
        }
        foreach ($m in [regex]::Matches($line, '<a\s[^>]*?\b(?:id|name)\s*=\s*"([^"]+)"')) { $out.Add($m.Groups[1].Value.ToLowerInvariant()) }
    }
    return $out.ToArray()
}

function Test-LinkTarget {
    <#
    .SYNOPSIS  I/O mínimo: o alvo existe, resolvido RELATIVO AO ARQUIVO que o cita?
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$Target
    )
    $dir  = Split-Path -Parent $SourceFile
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.' }
    # Join-Path + normalização manual: Resolve-Path LANÇA quando o alvo não existe, que é
    # justamente o caso que este lint procura.
    $full = [System.IO.Path]::GetFullPath((Join-Path $dir ($Target -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    return (Test-Path -LiteralPath $full)
}

function Get-LinkLintTarget {
    <#
    .SYNOPSIS  I/O: os .md a varrer — sem gitignored, sem .claude/sdd/archive/ (ver .DESCRIPTION).
    .OUTPUTS   [string[]] caminhos completos.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludeFragment = @('.claude\sdd\archive\', '.claude/sdd/archive/')
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    # -Force: sem ele o PowerShell não desce em diretório OCULTO — no Unix, todo nome começado por
    # '.', que é onde mora o `.claude/` (LINK_LINT_CEGO_A_DOT_DIR_NO_UNIX: 6 de 82 .md num Mac real,
    # 7 de 84 no WSL). O `.git/` do topo é podado ANTES de descer, porque o -Force cego o varreria
    # (+167 ms medidos na raiz deste repo); um `.git/` aninhado (submódulo) sai pelo filtro de segmento.
    $all = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.git' } |
        ForEach-Object {
            if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Filter '*.md' -Force -ErrorAction SilentlyContinue }
            elseif ($_.Extension -eq '.md') { $_ }
        } |
        Where-Object { $p = $_.FullName; ($p -notmatch '[\\/]\.git[\\/]') -and -not (@($ExcludeFragment) | Where-Object { $p -like "*$_*" }) } |
        ForEach-Object { $_.FullName })
    if ($all.Count -eq 0) { return @() }
    return @(Select-NotGitIgnored -Root $Root -Files $all)
}

function Get-LinkLintFindings {
    <#
    .SYNOPSIS  I/O fino: para cada arquivo, extrai os links e testa cada alvo.
    .OUTPUTS   [pscustomobject[]] (vazio = nenhum link quebrado).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files,
        [string]$Root = '',
        [switch]$CheckAnchor
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    $anchorCache = @{}
    foreach ($f in $Files) {
        $text = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { continue }
        $shown = if ($Root -and $f.StartsWith($Root)) { $f.Substring($Root.Length).TrimStart('\', '/') } else { $f }
        foreach ($link in (Get-MarkdownLink -Text $text -IncludeAnchor:$CheckAnchor)) {
            if ($link.Target -and -not (Test-LinkTarget -SourceFile $f -Target $link.Target)) {
                $findings.Add((New-LinkFinding -Severity error -Rule 'broken-link' -Path "${shown}:$($link.Line)" `
                            -Message "link relativo aponta para arquivo inexistente: '$($link.Target)'"))
                continue
            }
            if (-not $CheckAnchor -or -not $link.Anchor -or $link.Anchor -match '^L\d+') { continue }
            $dest = if ($link.Target) {
                [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $f) ($link.Target -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
            } else { $f }
            if ($dest -notmatch '\.md$' -or -not (Test-Path -LiteralPath $dest -PathType Leaf)) { continue }
            if (-not $anchorCache.ContainsKey($dest)) {
                $t = if ($dest -eq $f) { $text } else { Get-Content -LiteralPath $dest -Raw -ErrorAction SilentlyContinue }
                $anchorCache[$dest] = @(Get-MarkdownAnchor -Text $t)
            }
            $want = [uri]::UnescapeDataString($link.Anchor).ToLowerInvariant()
            if ($anchorCache[$dest] -notcontains $want) {
                $findings.Add((New-LinkFinding -Severity error -Rule 'broken-anchor' -Path "${shown}:$($link.Line)" `
                            -Message "âncora inexistente no alvo: '$($link.Target)#$($link.Anchor)'"))
            }
        }
    }
    return $findings.ToArray()
}

function Format-LinkLintReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'link-lint: ok (nenhum link relativo quebrado)' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("link-lint: $(@($Findings).Count) achado(s)")
    foreach ($f in $Findings) { $lines.Add(("  [{0}] {1} - {2} ({3})" -f $f.Severity, $f.Rule, $f.Message, $f.Path)) }
    return ($lines -join [Environment]::NewLine)
}

function Test-LinkLintGate {
    <# .SYNOPSIS  PURA: passa quando não há finding `error`. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Findings)
    return (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -eq 0)
}

function Invoke-LinkLint {
    <#
    .SYNOPSIS  Driver: varre o alvo e devolve os findings. Read-only.
    .OUTPUTS   [pscustomobject[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$CheckAnchor)
    $full  = (Resolve-Path -LiteralPath $Root).Path
    $files = @(Get-LinkLintTarget -Root $full)
    return @(Get-LinkLintFindings -Files $files -Root $full -CheckAnchor:$CheckAnchor)
}
