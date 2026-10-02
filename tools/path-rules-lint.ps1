<#
.SYNOPSIS
    Lint das rules de AREA: `.claude/rules/*.md` com `paths:` no frontmatter. Confere se cada glob
    casa algum arquivo do projeto e se a lista `rules` do AGENTS.md diz a que area a rule se aplica.

.DESCRIPTION
    Funcoes PURAS (texto + listas, sem tocar disco) + um I/O fino. Mesmo molde do
    tools/rules-list-lint.ps1.

    POR QUE EXISTE (REGRA_DE_AREA_SEM_DESTINO, 2026-09-25): rule com `paths:` e' condicional -- o
    harness so' a injeta quando o modelo LE um arquivo que casa o glob. Medido na mesma data, com
    rule inflada e salto de tokens (o autorrelato do modelo errou 2 de 3 injecoes): Read relativo e
    absoluto 4/4, subagente que le o arquivo casado 6/6; Write de arquivo novo, Glob, Grep e `cat`
    via Bash 0/2 cada. Duas consequencias viram achado aqui:

      - Glob que nao casa nada e' rule que NUNCA carrega -- e ninguem ve, porque rule ausente nao
        da erro. Erro de digitacao no glob tem exatamente esse efeito.
      - Codex/Cursor/Antigravity ignoram `paths:`; para eles a lista `rules` do AGENTS.md e' a unica
        porta, e uma linha que nao diz a area apresenta a rule como se valesse para tudo.

    O que e' AVISO (warn, NAO bloqueia -- area que ainda vai existir e' legitima):
      - dead-glob          : um glob da rule nao casa nenhum arquivo do projeto.
      - paths-unparsed     : a rule declara `paths:` mas nenhum glob foi lido (forma nao reconhecida).
      - area-missing-in-list: a linha da rule na lista `rules` nao cita o glob nem o prefixo fixo dele.

    O que NAO e' violacao: rule sem `paths:` (always-on, fora do escopo); rule ausente da lista
    (cobertura e' do rules-list-lint).

    Glob: `**` (qualquer profundidade, inclusive zero), `*` e `?` (sem cruzar `/`), `{a,b}`. Relativo
    a raiz do projeto, como o harness o resolve.
#>

Set-StrictMode -Version Latest

# --- PURA: globs do frontmatter -----------------------------------------------------------------
function Get-RulePathGlobs {
    <# .SYNOPSIS  Globs de `paths:` no frontmatter de um texto de rule. $null se nao houver `paths:`;
       array (talvez vazio) se houver. Aceita escalar, lista inline `[a, b]` e lista em bloco `- a`.
       .OUTPUTS   [string[]] ou $null #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = @($Text -split "\r?\n")
    if ($lines.Count -lt 2 -or $lines[0].Trim().TrimStart([char]0xFEFF) -ne '---') { return $null }

    $globs = [System.Collections.Generic.List[string]]::new()
    $found = $false
    $inPaths = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') { break }
        if ($inPaths) {
            $m = [regex]::Match($line, '^\s+-\s*(?<v>.+?)\s*$')
            if ($m.Success) { $globs.Add(($m.Groups['v'].Value.Trim().Trim('"', "'"))); continue }
            if ($line -match '^\s*$') { continue }
            $inPaths = $false
        }
        $k = [regex]::Match($line, '^paths\s*:\s*(?<v>.*)$')
        if (-not $k.Success) { continue }
        $found = $true
        $v = $k.Groups['v'].Value.Trim()
        if ($v -eq '') { $inPaths = $true; continue }
        if ($v.StartsWith('[') -and $v.EndsWith(']')) { $v = $v.Substring(1, $v.Length - 2) }
        # Virgula DENTRO de `{a,b}` nao separa item -- so' a de fora das chaves.
        $depth = 0; $cur = ''
        foreach ($ch in $v.ToCharArray()) {
            if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth-- }
            if ($ch -eq ',' -and $depth -eq 0) { $globs.Add($cur); $cur = ''; continue }
            $cur += $ch
        }
        $globs.Add($cur)
    }
    if (-not $found) { return $null }
    # `,` impede o PowerShell de desenrolar a lista vazia em $null -- `paths:` sem item tem que chegar
    # ao inventario como lista vazia (achado paths-unparsed), nao sumir como rule always-on.
    return , [string[]]@($globs | ForEach-Object { $_.Trim().Trim('"', "'").Trim() } | Where-Object { $_ })
}

function ConvertTo-GlobRegex {
    <# .SYNOPSIS  Glob -> regex ancorado (caminho relativo com `/`). PURA. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Glob)

    $g = $Glob.Trim() -replace '\\', '/'
    if ($g.StartsWith('./')) { $g = $g.Substring(2) }
    $sb = [System.Text.StringBuilder]::new('^')
    $i = 0
    $brace = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*' -and $i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
            $atStart = ($i -eq 0 -or $g[$i - 1] -eq '/')
            if ($atStart -and $i + 2 -lt $g.Length -and $g[$i + 2] -eq '/') {
                [void]$sb.Append('(?:.*/)?'); $i += 3; continue      # `**/` = zero ou mais pastas
            }
            if ($atStart -and $i + 2 -eq $g.Length -and $i -gt 0) {
                # `dir/**` casa tudo sob dir: tira a `/` ja emitida e a torna opcional junto.
                $sb.Length--
                [void]$sb.Append('(?:/.*)?'); $i += 2; continue
            }
            [void]$sb.Append('.*'); $i += 2; continue
        }
        switch ($c) {
            '*' { [void]$sb.Append('[^/]*') }
            '?' { [void]$sb.Append('[^/]') }
            '{' { $brace++; [void]$sb.Append('(?:') }
            '}' { if ($brace -gt 0) { $brace--; [void]$sb.Append(')') } else { [void]$sb.Append('\}') } }
            ',' { if ($brace -gt 0) { [void]$sb.Append('|') } else { [void]$sb.Append(',') } }
            default { [void]$sb.Append([regex]::Escape([string]$c)) }
        }
        $i++
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

function Test-GlobMatch {
    <# .SYNOPSIS  O caminho relativo casa o glob? PURA. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Glob,
        [Parameter(Mandatory)][string]$RelPath
    )
    $p = $RelPath -replace '\\', '/'
    if ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return [regex]::IsMatch($p, (ConvertTo-GlobRegex -Glob $Glob))
}

function Get-GlobStaticPrefix {
    <# .SYNOPSIS  Segmentos fixos do glob antes do 1o curinga (`migrations/**` -> `migrations`). PURA. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Glob)
    $segs = [System.Collections.Generic.List[string]]::new()
    foreach ($s in (($Glob -replace '\\', '/') -split '/')) {
        if ($s -eq '.' -or $s -eq '') { continue }
        if ($s -match '[*?{\[]') { break }
        $segs.Add($s)
    }
    return ($segs -join '/')
}

function Get-RulesListRow {
    <# .SYNOPSIS  A linha da rule <Name> na regiao `rules` do AGENTS.md, ou $null. PURA. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Name
    )
    $s = $Text.IndexOf('<!-- sync-context:start:rules -->')
    $e = $Text.IndexOf('<!-- sync-context:end:rules -->')
    if ($s -lt 0 -or $e -lt $s) { return $null }
    $rx = 'rules/' + [regex]::Escape($Name) + '\.md\)'
    foreach ($line in ($Text.Substring($s, $e - $s) -split "\r?\n")) {
        if ($line -match $rx) { return $line }
    }
    return $null
}

function New-PathRuleFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-PathRuleFindings {
    <# .SYNOPSIS  Achados das rules de area. PURA (sem disco).
       .PARAMETER Rules     objetos { Name (basename sem .md); Globs [string[]] } -- so' as com `paths:`.
       .PARAMETER Files     caminhos relativos a raiz do projeto.
       .PARAMETER AgentsText texto do AGENTS.md ('' se ausente -- a checagem da lista e' pulada).
       .OUTPUTS   [pscustomobject[]] #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files,
        [AllowEmptyString()][string]$AgentsText = ''
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rules) {
        $src = ".claude/rules/$($r.Name).md"
        $globs = @($r.Globs)
        if ($globs.Count -eq 0) {
            $findings.Add((New-PathRuleFinding -Severity warn -Rule paths-unparsed -Path $src `
                        -Message 'declara `paths:` mas nenhum glob foi lido -- use lista em bloco (`  - "dir/**"`)'))
            continue
        }
        foreach ($g in $globs) {
            $rx = ConvertTo-GlobRegex -Glob $g
            $hit = $false
            foreach ($f in $Files) {
                if ([regex]::IsMatch(($f -replace '\\', '/'), $rx)) { $hit = $true; break }
            }
            if (-not $hit) {
                $findings.Add((New-PathRuleFinding -Severity warn -Rule dead-glob -Path $src `
                            -Message "glob '$g' nao casa nenhum arquivo do projeto -- a rule nunca carrega (erro de digitacao? se a area ainda vai existir, ignore)"))
            }
        }
        if ($AgentsText) {
            $row = Get-RulesListRow -Text $AgentsText -Name $r.Name
            if ($null -ne $row) {
                $cita = $false
                foreach ($g in $globs) {
                    $pre = Get-GlobStaticPrefix -Glob $g
                    if ($row.Contains($g) -or ($pre -and $row.Contains($pre))) { $cita = $true; break }
                }
                if (-not $cita) {
                    $findings.Add((New-PathRuleFinding -Severity warn -Rule area-missing-in-list -Path 'AGENTS.md' `
                                -Message "a linha de $($r.Name).md na lista ``rules`` nao diz a area ($($globs -join ', ')) -- Codex/Cursor nao leem ``paths:`` e a tratam como regra global; rode /sync-context"))
                }
            }
        }
    }
    return $findings.ToArray()
}

function Format-PathRulesLintReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    if (@($Findings).Count -eq 0) { return 'path-rules-lint: OK (0 achados)' }
    return (@($Findings | ForEach-Object { "    [$($_.Severity)] $($_.Rule) $($_.Path) -- $($_.Message)" }) -join [Environment]::NewLine)
}

function Test-PathRulesLintGate {
    <# .SYNOPSIS  Sempre $true: todos os achados sao warn (advisory). Existe pelo contrato do check.ps1. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

# --- I/O fino ------------------------------------------------------------------------------------
function Get-PathRuleInventory {
    <# .SYNOPSIS  Rules de RulesDir com `paths:` -> { Name; Globs }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RulesDir)
    if (-not (Test-Path -LiteralPath $RulesDir -PathType Container)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $RulesDir -Filter '*.md' -File | Sort-Object Name)) {
        $globs = Get-RulePathGlobs -Text (Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue)
        if ($null -eq $globs) { continue }
        $out.Add([pscustomobject]@{ Name = $f.BaseName; Globs = @($globs) })
    }
    return $out.ToArray()
}

function Get-ProjectRelativeFile {
    <# .SYNOPSIS  Arquivos do projeto, relativos a Root com `/`. Via git (respeita .gitignore) quando
       ha repositorio; sem git, varre o disco pulando .git/ e node_modules/ -- aqui a degradacao nao
       cega o lint (ao contrario do encoding): so' custa enumerar mais. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $abs = (Resolve-Path -LiteralPath $Root).Path
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $inside = & git -C $abs rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0 -and "$inside".Trim() -eq 'true') {
            $ls = @(& git -C $abs ls-files --cached --others --exclude-standard 2>$null)
            if ($LASTEXITCODE -eq 0) { return @($ls | Where-Object { $_ }) }
        }
    }
    $prefix = $abs.TrimEnd('\', '/').Length + 1
    return @(Get-ChildItem -LiteralPath $abs -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } |
            ForEach-Object { $_.FullName.Substring($prefix) -replace '\\', '/' })
}

function Invoke-PathRulesLint {
    <# .SYNOPSIS  Le as rules de <Root>/.claude/rules, enumera o projeto e o AGENTS.md; devolve achados.
       $null quando nao ha rule de area (o chamador decide se isso e' `n/a`). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $rules = @(Get-PathRuleInventory -RulesDir (Join-Path $Root '.claude/rules'))
    if ($rules.Count -eq 0) { return $null }
    $agents = Join-Path $Root 'AGENTS.md'
    $txt = if (Test-Path -LiteralPath $agents -PathType Leaf) { Get-Content -LiteralPath $agents -Raw } else { '' }
    return @(Get-PathRuleFindings -Rules $rules -Files @(Get-ProjectRelativeFile -Root $Root) -AgentsText $txt)
}
