<#
.SYNOPSIS
    Inventário/diagnóstico do I1 (/update-skills): mapeia as skills nos dois escopos
    (global ~/.claude/skills + projeto .claude/skills), diagnostica a saúde de cada uma e
    planeja o update a partir do baseline — sem escrever (read-only).

.DESCRIPTION
    Funções puras (read-only, determinísticas) usadas pela validação automática do I1 e pelo
    comando em runtime:

      ConvertFrom-SkillFrontmatter -> [pscustomobject]|$null  { name; description; version }
      Get-SkillInventory           -> [pscustomobject[]]      { Name; Scope; Path; HasManifest; Frontmatter; ShadowedBy; ... }
      Get-SkillHealth              -> [pscustomobject]        { Health; IsCustom; Evidence }
      Format-SkillReport           -> [string]                relatório determinístico (sem timestamp)
      Get-SkillUpdatePlan          -> [pscustomobject[]]      { Src; Dst; Rel; Skill } (itens que diferem do baseline)

    Reusa onboarding/windows/lib.ps1 (Get-BaselineMap, Test-FilesDiffer, Install-BaselineItem,
    Backup-File) — não reimplementa espelhamento/backup. APLICAR o plano (Install-BaselineItem,
    sob confirmação) é runtime do comando, fora deste módulo. Determinismo: ordenação estável;
    sem datas no conteúdo.
#>

Set-StrictMode -Version Latest

# Reuso da infra do instalador (espelhamento/backup/idempotência já provados em A2/A5/A6).
. (Join-Path $PSScriptRoot '..\onboarding\windows\lib.ps1')

function ConvertFrom-SkillFrontmatter {
    <#
    .SYNOPSIS
        Lê o frontmatter de um SKILL.md (bloco --- ... ---), chaves planas name/description/version.
        Retorna $null se não houver bloco de frontmatter.
    .OUTPUTS
        [pscustomobject] { name; description; version } | $null
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '(?s)^\s*---\s*\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return $null }

    $h = [ordered]@{ name = $null; description = $null; version = $null }
    foreach ($line in ($m.Groups[1].Value -split "\r?\n")) {
        $lm = [regex]::Match($line, '^\s*(name|description|version)\s*:\s*(.*?)\s*$')
        if ($lm.Success) {
            $val = $lm.Groups[2].Value.Trim().Trim('"').Trim("'")
            if ($val -ne '') { $h[$lm.Groups[1].Value] = $val }
        }
    }
    return [pscustomobject]$h
}

function Get-SkillsInRoot {
    <#
    .SYNOPSIS
        Skills (subpastas) de uma raiz. Cada subpasta = uma skill; lê o SKILL.md se houver.
        Read-only. Vazio se a raiz não existir.
    .OUTPUTS
        [pscustomobject[]]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Root,
        [Parameter(Mandatory)][ValidateSet('global', 'project')][string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @()
    }

    Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $skillMd = Join-Path $_.FullName 'SKILL.md'
        $hasManifest = Test-Path -LiteralPath $skillMd -PathType Leaf
        $fm = $null
        if ($hasManifest) {
            $fm = ConvertFrom-SkillFrontmatter (Get-Content -LiteralPath $skillMd -Raw -ErrorAction SilentlyContinue)
        }
        [pscustomobject]@{
            Name        = $_.Name
            Scope       = $Scope
            Path        = $_.FullName
            HasManifest = [bool]$hasManifest
            Frontmatter = $fm
            ShadowedBy  = $null
            Health      = $null   # anotado por Get-SkillHealth no runtime do comando
            IsCustom    = $false
            Evidence    = $null
        }
    }
}

function Get-SkillInventory {
    <#
    .SYNOPSIS
        Inventário das skills nos dois escopos (global + projeto). Resolve precedência:
        skill de mesmo Name nos dois escopos → a global é marcada ShadowedBy='project'.
        Ordenado por (Scope, Name). Read-only.
    .OUTPUTS
        [pscustomobject[]]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$GlobalRoot,
        [AllowNull()][string]$ProjectRoot
    )

    $skills = @()
    $skills += Get-SkillsInRoot -Root $GlobalRoot  -Scope 'global'
    $skills += Get-SkillsInRoot -Root $ProjectRoot -Scope 'project'

    $projNames = @($skills | Where-Object { $_.Scope -eq 'project' } | ForEach-Object { $_.Name })
    foreach ($s in $skills) {
        if ($s.Scope -eq 'global' -and $projNames -contains $s.Name) {
            $s.ShadowedBy = 'project'
        }
    }
    return @($skills | Sort-Object Scope, Name)
}

function Get-SkillHealth {
    <#
    .SYNOPSIS
        Classifica a saúde de uma skill por precedência: orphan → malformed → stale → valid.
        `custom` é flag ortogonal (skill válida sem contraparte no baseline). Read-only.
    .OUTPUTS
        [pscustomobject] { Health; IsCustom; Evidence }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Skill,
        [AllowNull()][object[]]$BaselineMap = @()
    )

    # 1) orphan — pasta de skill sem SKILL.md (resíduo)
    if (-not $Skill.HasManifest) {
        return [pscustomobject]@{ Health = 'orphan'; IsCustom = $false; Evidence = 'pasta sem SKILL.md' }
    }

    # 2) malformed — frontmatter sem name/description
    $fm = $Skill.Frontmatter
    $missing = @()
    if ($null -eq $fm -or [string]::IsNullOrWhiteSpace([string]$fm.name)) { $missing += 'name' }
    if ($null -eq $fm -or [string]::IsNullOrWhiteSpace([string]$fm.description)) { $missing += 'description' }
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ Health = 'malformed'; IsCustom = $false; Evidence = "missing: $($missing -join ', ')" }
    }

    # contraparte no baseline? (itens cujo Rel começa pelo nome da skill)
    $rx = '^' + [regex]::Escape($Skill.Name) + '[\\/]'
    $baseItems = @($BaselineMap | Where-Object { $_.Rel -match $rx })
    $isCustom = ($baseItems.Count -eq 0)

    # 3) stale — origem no baseline e ≥1 arquivo difere (hash)
    if (-not $isCustom) {
        foreach ($bi in $baseItems) {
            if (Test-FilesDiffer -A $bi.Src -B $bi.Dst) {
                return [pscustomobject]@{ Health = 'stale'; IsCustom = $false; Evidence = 'difere do baseline' }
            }
        }
    }

    # 4) valid (custom marcada à parte)
    $ev = if ($isCustom) { 'sem contraparte no baseline' } else { 'em dia com o baseline' }
    return [pscustomobject]@{ Health = 'valid'; IsCustom = $isCustom; Evidence = $ev }
}

function Format-SkillReport {
    <#
    .SYNOPSIS
        Relatório determinístico do inventário (já anotado com Health/IsCustom): agrupa por escopo,
        lista skill + estado + ação sugerida. Sem timestamp.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$Inventory = @())

    $Inventory = @($Inventory | Where-Object { $null -ne $_ })

    # glifo + ação por estado de saúde
    $glyph = @{ valid = '✓'; stale = '↑'; malformed = '!'; orphan = '∅' }
    function Get-Action($s) {
        switch ($s.Health) {
            'valid'     { if ($s.IsCustom) { 'preservada (custom)' } else { 'em dia' } }
            'stale'     { 'atualizar do baseline' }
            'malformed' { [string]$s.Evidence }
            'orphan'    { 'pasta sem SKILL.md' }
            default     { '' }
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    [void]$sb.Append("UPDATE-SKILLS — inventário & saúde`n")

    foreach ($scope in @('global', 'project')) {
        [void]$sb.Append("[$scope]`n")
        $items = @($Inventory | Where-Object { $_.Scope -eq $scope } | Sort-Object Name)
        if ($items.Count -eq 0) {
            [void]$sb.Append("  (nenhuma skill)`n")
            continue
        }
        foreach ($s in $items) {
            $h = if ($s.Health) { [string]$s.Health } else { 'valid' }
            $g = if ($glyph.ContainsKey($h)) { $glyph[$h] } else { '·' }
            [void]$sb.Append(("  [{0}] {1,-22} {2,-10} → {3}`n" -f $g, $s.Name, $h, (Get-Action $s)))
        }
    }

    $stale = @($Inventory | Where-Object { $_.Health -eq 'stale' }).Count
    if ($stale -gt 0) {
        [void]$sb.Append("Ação: $stale skill(s) desatualizada(s). Rode sem --check para atualizar (com backup).`n")
    }
    else {
        [void]$sb.Append("Ação: nenhuma skill desatualizada (tudo em dia).`n")
    }
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}

function Get-SkillUpdatePlan {
    <#
    .SYNOPSIS
        Plano de update de um escopo: reusa Get-BaselineMap + Test-FilesDiffer para listar os
        ARQUIVOS do baseline que diferem do local. Vazio se nada difere (idempotente). Skills
        custom (sem pasta no baseline) nunca aparecem aqui → preservadas por construção. Read-only
        (só planeja; aplicar é Install-BaselineItem no runtime).
    .OUTPUTS
        [pscustomobject[]] { Src; Dst; Rel; Skill }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$BaselineRoot,
        [Parameter(Mandatory)][string]$LocalRoot
    )

    if ([string]::IsNullOrWhiteSpace($BaselineRoot) -or -not (Test-Path -LiteralPath $BaselineRoot -PathType Container)) {
        return @()
    }

    $map = Get-BaselineMap -SourceRoot $BaselineRoot -DestRoot $LocalRoot
    $plan = foreach ($item in $map) {
        # ignora dotfiles do baseline (ex.: .gitkeep) — não são conteúdo de skill
        $leaf = Split-Path -Leaf $item.Rel
        if ($leaf -like '.*') { continue }
        if (Test-FilesDiffer -A $item.Src -B $item.Dst) {
            [pscustomobject]@{
                Src   = $item.Src
                Dst   = $item.Dst
                Rel   = $item.Rel
                Skill = ($item.Rel -split '[\\/]')[0]
            }
        }
    }
    return @($plan | Sort-Object Rel)
}
