<#
.SYNOPSIS
    Lint de agentes do scaffold: valida o frontmatter de arquivos .md de agente.

.DESCRIPTION
    Funções puras (sem efeitos colaterais) usadas pela validação automática do G2
    (/audit-agents) e reaproveitáveis pela curadoria/sync (G4). Não dependem de módulo
    YAML — o frontmatter de agente é plano (key: value entre as duas primeiras cercas '---').

    Contrato de formato de um agente (.claude/agents/**.md):
      - bloco frontmatter presente
      - name:        presente e kebab-case (^[a-z0-9]+(-[a-z0-9]+)*$)
      - description: presente e não-vazia
      - tools:       presente (CSV "a, b" ou array inline "[a, b]")
      - model:       presente
      - generated_by: opcional; "audit-agents" marca os gerados pela curadoria (idempotência).
#>

Set-StrictMode -Version Latest

function Read-AgentFrontmatter {
    <#
    .SYNOPSIS
        Extrai o frontmatter (hashtable key->value) de um .md. $null se não houver bloco.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { return $null }

    $fm = [ordered]@{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') { return $fm }   # fecha o bloco
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }                  # linha de continuação/array — ignora
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($key) { $fm[$key] = $val }
    }
    return $null   # cerca de fechamento ausente => frontmatter malformado
}

function Test-AgentFrontmatter {
    <#
    .SYNOPSIS
        Valida o frontmatter de um agente. Retorna objeto com Valid/Generated/Name/Errors.
    .OUTPUTS
        [pscustomobject] @{ Path; Name; Valid; Generated; Errors }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $errors = [System.Collections.Generic.List[string]]::new()
    $fm = Read-AgentFrontmatter -Path $Path

    if ($null -eq $fm) {
        $errors.Add('frontmatter ausente ou malformado (esperado bloco entre cercas ---)')
        return [pscustomobject]@{
            Path = $Path; Name = $null; Valid = $false; Generated = $false
            Errors = $errors.ToArray()
        }
    }

    $name = if ($fm.Contains('name')) { $fm['name'] } else { $null }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $errors.Add("chave 'name' ausente ou vazia")
    }
    elseif ($name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        $errors.Add("'name' não é kebab-case: '$name'")
    }

    if (-not $fm.Contains('description') -or [string]::IsNullOrWhiteSpace($fm['description'])) {
        $errors.Add("chave 'description' ausente ou vazia")
    }
    if (-not $fm.Contains('tools') -or [string]::IsNullOrWhiteSpace($fm['tools'])) {
        $errors.Add("chave 'tools' ausente ou vazia")
    }
    if (-not $fm.Contains('model') -or [string]::IsNullOrWhiteSpace($fm['model'])) {
        $errors.Add("chave 'model' ausente ou vazia")
    }

    $generated = $fm.Contains('generated_by') -and ($fm['generated_by'] -eq 'audit-agents')

    return [pscustomobject]@{
        Path      = $Path
        Name      = $name
        Valid     = ($errors.Count -eq 0)
        Generated = $generated
        Errors    = $errors.ToArray()
    }
}

function Get-AgentInventory {
    <#
    .SYNOPSIS
        Inventaria os agentes de um diretório (recursivo) e detecta colisão de 'name'.
    .OUTPUTS
        [pscustomobject[]] um por .md, com Path/Name/Valid/Generated/Errors.
        Colisões de name viram um erro extra em CADA agente envolvido.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }

    # Só agentes: ignora o mapa (AGENT_MAP.md) e arquivos auxiliares (_*.md).
    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') }
    $results = foreach ($f in $files) { Test-AgentFrontmatter -Path $f.FullName }
    $results = @($results)

    # detecta nomes duplicados (ignora os nulos/inválidos sem name)
    $dupes = $results |
        Where-Object { $_.Name } |
        Group-Object Name |
        Where-Object { $_.Count -gt 1 } |
        Select-Object -ExpandProperty Name

    if ($dupes) {
        foreach ($r in $results) {
            if ($r.Name -in $dupes) {
                $r.Errors = @($r.Errors) + "colisão de 'name': '$($r.Name)' aparece em mais de um agente"
                $r.Valid = $false
            }
        }
    }

    return $results
}

# ───────────────────────────────────────────────────────────────────────────────
# Camada de findings (B9 — agentes-base): contrato de CORPO + metadados RELACIONAIS.
# Estende o contrato de frontmatter acima com:
#   - seção de corpo "Regras críticas (faça / não faça)" (harvest);
#   - metadados relacionais 'role' (enum fechado) + 'connects_to' (grafo H4-ready).
# Espelha o shape dos demais lints (standards/config/doubt): finding{Rule;Severity;Path;Message},
# Format-/Test-Gate e um driver Invoke- com I/O fino. error bloqueia o CI; warn é advisory.
# ───────────────────────────────────────────────────────────────────────────────

# Enum fechado de papéis dos agentes base (V2: papel universal, não stack/domínio).
# 'simulation' é o único papel INSTANCIADO no domínio (via /audit-agents, G2): marca um
# simulador de stack (ex.: dbt-simulator) que cumpre o contrato do /simulate. Os demais são
# papéis universais do base. 'observation' = caixa-preta de runtime externo (external-observer,
# ver DESIGN_EXTERNAL_OBSERVER.md). Aditivo/retrocompat (ver DESIGN_SIMULATION.md, D-002).
$script:AgentRoles = @('search', 'review', 'testing', 'vcs', 'security', 'debug', 'validation', 'documentation', 'simulation', 'observation', 'design', 'tracking')

function New-AgentFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-MarkdownHeadings {
    <#
    .SYNOPSIS  Lista os headings (texto após os '#') de um Markdown, na ordem.
    .OUTPUTS   [string[]] (vazio se não houver heading)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $headings = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*#{1,6}\s+(.+?)\s*$') { $headings.Add($Matches[1]) }
    }
    return $headings.ToArray()
}

function Get-MarkdownSectionBody {
    <#
    .SYNOPSIS  Texto entre o heading que casa $HeadingPattern e o próximo heading.
               '' se a seção não existir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$HeadingPattern
    )

    $inSection = $false
    $buf = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*#{1,6}\s+(.+?)\s*$') {
            if ($inSection) { break }                       # próximo heading encerra a seção
            $inSection = ($Matches[1] -imatch $HeadingPattern)
            continue
        }
        if ($inSection) { $buf.Add($line) }
    }
    return ($buf -join "`n")
}

function ConvertFrom-InlineList {
    <#
    .SYNOPSIS  "[a, b]" -> @('a','b'); "" / "[]" / $null -> @(). Tolera CSV sem colchetes.
    .OUTPUTS   [string[]]
    #>
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    $v = $Value.Trim()
    if ($v.StartsWith('[')) { $v = $v.Substring(1) }
    if ($v.EndsWith(']')) { $v = $v.Substring(0, $v.Length - 1) }
    if ([string]::IsNullOrWhiteSpace($v)) { return @() }
    return @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-AgentBodyFindings {
    <#
    .SYNOPSIS  Verifica a seção de corpo "Regras críticas (faça / não faça)".
    .OUTPUTS   finding[] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $rxCritical = 'regras\s+cr[íi]ticas'

    $hasHeading = @(Get-MarkdownHeadings -Text $Text | Where-Object { $_ -imatch $rxCritical }).Count -gt 0
    if (-not $hasHeading) {
        $findings.Add((New-AgentFinding -Severity error -Rule 'missing-critical-rules' -Path $Source `
                    -Message 'sem seção "Regras críticas (faça / não faça)"'))
        return $findings.ToArray()
    }

    $body = Get-MarkdownSectionBody -Text $Text -HeadingPattern $rxCritical
    $hasDo = $body -imatch 'fa[çc]a|fazer'
    $hasDont = $body -imatch 'n[ãa]o\s+fa'
    if (-not ($hasDo -and $hasDont)) {
        $findings.Add((New-AgentFinding -Severity warn -Rule 'critical-rules-incomplete' -Path $Source `
                    -Message 'seção "Regras críticas" sem par faça/não-faça explícito'))
    }
    return $findings.ToArray()
}

function Get-AgentRelationalFindings {
    <#
    .SYNOPSIS  Verifica os metadados relacionais 'role' + 'connects_to' (grafo H4-ready).
    .OUTPUTS   finding[] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter()][System.Collections.IDictionary]$Frontmatter,
        [Parameter()][AllowNull()][string[]]$KnownNames,
        [Parameter(Mandatory)][string]$Source,
        # H9: inventário de skills conhecidas p/ validar skills_used (opcional). $null => inventário
        # indisponível => NÃO valida (degrada/silêncio, D-006). Lista (mesmo vazia) => valida dangling.
        [Parameter()][AllowNull()][string[]]$KnownSkills
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Frontmatter) {
        $findings.Add((New-AgentFinding -Severity error -Rule 'missing-role' -Path $Source `
                    -Message 'frontmatter ausente — sem metadados relacionais'))
        return $findings.ToArray()
    }
    $known = @($KnownNames)

    if (-not $Frontmatter.Contains('role') -or [string]::IsNullOrWhiteSpace($Frontmatter['role'])) {
        $findings.Add((New-AgentFinding -Severity error -Rule 'missing-role' -Path $Source `
                    -Message "chave 'role' ausente"))
    }
    elseif ($Frontmatter['role'] -notin $script:AgentRoles) {
        $findings.Add((New-AgentFinding -Severity error -Rule 'invalid-role' -Path $Source `
                    -Message "'role' fora do enum: '$($Frontmatter['role'])'"))
    }

    if (-not $Frontmatter.Contains('connects_to') -or [string]::IsNullOrWhiteSpace($Frontmatter['connects_to'])) {
        $findings.Add((New-AgentFinding -Severity error -Rule 'missing-connects-to' -Path $Source `
                    -Message "chave 'connects_to' ausente"))
    }
    else {
        foreach ($t in (ConvertFrom-InlineList -Value $Frontmatter['connects_to'])) {
            if ($t -notin $known) {
                $findings.Add((New-AgentFinding -Severity error -Rule 'dangling-connection' -Path $Source `
                            -Message "connects_to aponta a agente inexistente: '$t'"))
            }
        }
    }

    # skills_used (opcional, H9): override do elo agente↔skill. Validação ADVISORY (warn) — NUNCA barra
    # o CI (skills são runtime/curadas, podem ser global/ausentes). $null => silêncio (degrada).
    if ($null -ne $KnownSkills -and $Frontmatter.Contains('skills_used') -and -not [string]::IsNullOrWhiteSpace($Frontmatter['skills_used'])) {
        foreach ($s in (ConvertFrom-InlineList -Value $Frontmatter['skills_used'])) {
            if ($s -notin $KnownSkills) {
                $findings.Add((New-AgentFinding -Severity warn -Rule 'unknown-skill-used' -Path $Source `
                            -Message "skills_used aponta a skill fora do inventário: '$s'"))
            }
        }
    }
    return $findings.ToArray()
}

function Format-AgentLintReport {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Findings)

    $items = @($Findings)
    if ($items.Count -eq 0) { return 'agent-lint: 0 achados.' }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($f in $items) {
        [void]$sb.AppendLine(('[{0}] {1} — {2} ({3})' -f $f.Severity, $f.Rule, $f.Message, $f.Path))
    }
    $nE = @($items | Where-Object { $_.Severity -eq 'error' }).Count
    $nW = @($items | Where-Object { $_.Severity -eq 'warn' }).Count
    [void]$sb.AppendLine(('agent-lint: {0} erro(s), {1} aviso(s).' -f $nE, $nW))
    return $sb.ToString().TrimEnd()
}

function Test-AgentLintGate {
    <#
    .SYNOPSIS  $false se houver ≥1 finding 'error'; $true caso contrário.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Findings)
    return (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -eq 0)
}

function Invoke-AgentLint {
    <#
    .SYNOPSIS  Driver com I/O fino: varre $Dir e agrega frontmatter + colisão + corpo + relacional.
    .OUTPUTS   finding[] (vazio = tudo conforme)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }

    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') }

    $findings = [System.Collections.Generic.List[object]]::new()
    $fmMap = [ordered]@{}
    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($f in $files) {
        $fm = Read-AgentFrontmatter -Path $f.FullName
        $fmMap[$f.FullName] = $fm
        if ($fm -and $fm.Contains('name') -and $fm['name']) { $names.Add([string]$fm['name']) }
    }
    $known = $names.ToArray()
    $dupes = $names | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name

    # H9: nomes de skills do projeto (pasta irmã .claude/skills) p/ validar skills_used. Ausente => $null
    # => agent-lint NÃO valida skills_used (degrada/silêncio, D-006). Identidade da skill = nome da pasta.
    $skillsDir = Join-Path (Split-Path -Parent $Dir) 'skills'
    $knownSkills = $null
    if (Test-Path -LiteralPath $skillsDir -PathType Container) {
        $knownSkills = @(Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }

    foreach ($f in $files) {
        $src = $f.FullName

        $tf = Test-AgentFrontmatter -Path $src
        foreach ($e in @($tf.Errors)) {
            $findings.Add((New-AgentFinding -Severity error -Rule 'frontmatter' -Path $src -Message $e))
        }
        if ($tf.Name -and $tf.Name -in $dupes) {
            $findings.Add((New-AgentFinding -Severity error -Rule 'name-collision' -Path $src `
                        -Message "colisão de 'name': '$($tf.Name)'"))
        }

        $text = Get-Content -LiteralPath $src -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) {
            $findings.Add((New-AgentFinding -Severity error -Rule 'unreadable' -Path $src -Message 'arquivo ilegível'))
            continue
        }

        foreach ($x in (Get-AgentBodyFindings -Text $text -Source $src)) { $findings.Add($x) }
        foreach ($x in (Get-AgentRelationalFindings -Frontmatter $fmMap[$src] -KnownNames $known -Source $src -KnownSkills $knownSkills)) {
            $findings.Add($x)
        }
    }
    return $findings.ToArray()
}
