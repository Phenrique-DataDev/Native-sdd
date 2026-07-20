<#
.SYNOPSIS
    /status — agregador READ-ONLY do estado do projeto: curadoria + fase SDD em andamento + inbox.

.DESCRIPTION
    Reusa Get-CurationStatus (init.ps1, dot-source via $PSScriptRoot — entry-point resolvido pela
    cascata tooling.md/B11; deps internas ancoram em $PSScriptRoot) e adiciona duas leituras novas
    read-only: Get-SddFeatureStatus (fase de cada feature) e Get-InboxItems. Format-StatusReport é
    PURO. Nada é escrito; nenhuma função lança ao chamador (fail-safe por seção).

    Funções dot-sourceáveis para teste; o arquivo NÃO auto-executa (igual aos demais tools/*.ps1).
#>

Set-StrictMode -Version Latest

# Ordem das fases SDD (rank crescente). 'shipped' é estado terminal (não está aqui).
$script:SddPhaseByRank = @{ 1 = 'brainstorm'; 2 = 'define'; 3 = 'design'; 4 = 'build' }

# Fase SDD em andamento -> próximo comando da cadeia (usado pelo "próximo passo recomendado").
$script:SddNextCommand = @{ brainstorm = '/define'; define = '/design'; design = '/build'; build = '/ship' }

# --- PURA: acesso seguro a propriedade sob StrictMode (campos novos do report são opcionais) ----
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# --- I/O leitura: invoca git read-only em -Root; $null se falhar/exit≠0 -------------------------
function Invoke-GitRO {
    param([string]$Root, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    try {
        $out = & git -C $Root @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    }
    catch { return $null }
}

# --- PURA: chave de match de slug (UPPER_SNAKE de features/ ↔ kebab de archive/) ---------------
function ConvertTo-SlugKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Slug)
    return ($Slug.ToLowerInvariant() -replace '[_-]', '')
}

# --- PURA: nome da fase a partir do rank -------------------------------------------------------
function Get-PhaseName {
    param([Parameter(Mandatory)][int]$Rank)
    if ($script:SddPhaseByRank.ContainsKey($Rank)) { return $script:SddPhaseByRank[$Rank] }
    return 'brainstorm'
}

# --- I/O leitura: fase SDD de cada feature (in-flight = -not Shipped) --------------------------
function Get-SddFeatureStatus {
    <#
    .OUTPUTS [pscustomobject[]] { Feature; Phase; Shipped } — uma por feature observada.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $sdd = Join-Path $Root '.claude/sdd'
    $obs = [System.Collections.Generic.List[object]]::new()

    # features/{BRAINSTORM,DEFINE,DESIGN}_<SLUG>.md
    $featuresDir = Join-Path $sdd 'features'
    if (Test-Path -LiteralPath $featuresDir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $featuresDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match($f.BaseName, '^(BRAINSTORM|DEFINE|DESIGN)_(.+)$')
            if (-not $m.Success) { continue }
            $rank = switch ($m.Groups[1].Value) { 'BRAINSTORM' { 1 } 'DEFINE' { 2 } 'DESIGN' { 3 } }
            $name = $m.Groups[2].Value
            $obs.Add([pscustomobject]@{ Key = (ConvertTo-SlugKey $name); Name = $name; Rank = $rank; Shipped = $false })
        }
    }

    # reports/BUILD_REPORT_<SLUG>.md
    $reportsDir = Join-Path $sdd 'reports'
    if (Test-Path -LiteralPath $reportsDir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $reportsDir -Filter 'BUILD_REPORT_*.md' -File -ErrorAction SilentlyContinue)) {
            $name = $f.BaseName -replace '^BUILD_REPORT_', ''
            $obs.Add([pscustomobject]@{ Key = (ConvertTo-SlugKey $name); Name = $name; Rank = 4; Shipped = $false })
        }
    }

    # archive/<dir>/SHIPPED_*.md  -> feature entregue
    $archiveDir = Join-Path $sdd 'archive'
    if (Test-Path -LiteralPath $archiveDir -PathType Container) {
        foreach ($d in (Get-ChildItem -LiteralPath $archiveDir -Directory -ErrorAction SilentlyContinue)) {
            $hasShipped = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'SHIPPED_*.md' -File -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasShipped) {
                $obs.Add([pscustomobject]@{ Key = (ConvertTo-SlugKey $d.Name); Name = $d.Name; Rank = 0; Shipped = $true })
            }
        }
    }

    # Reduz por chave: maior rank, OR do Shipped, nome legível (prefere artefato de features/reports).
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($g in ($obs | Group-Object Key)) {
        $grp = $g.Group
        $rank = ($grp | Measure-Object -Property Rank -Maximum).Maximum
        $shipped = [bool](@($grp | Where-Object { $_.Shipped }).Count -gt 0)
        $named = @($grp | Where-Object { $_.Rank -gt 0 })
        $name = if ($named.Count -gt 0) { $named[0].Name } else { $grp[0].Name }
        $phase = if ($shipped) { 'shipped' } else { Get-PhaseName -Rank ([int]$rank) }
        $result.Add([pscustomobject]@{ Feature = $name; Phase = $phase; Shipped = $shipped })
    }
    return @($result | Sort-Object Feature)
}

# --- I/O leitura: itens pendentes no inbox/ (exclui _ABOUT.md/README.md) -----------------------
function Get-InboxItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $dir = Join-Path $Root 'inbox'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $exclude = @('_ABOUT.md', 'README.md')
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $exclude -notcontains $_.Name } |
            ForEach-Object { $_.Name } | Sort-Object)
}

# --- I/O leitura: contexto git read-only (branch/sujidade/sync/último commit) ------------------
function Get-GitContext {
    <#
    .OUTPUTS [pscustomobject] { Available; Branch; Detached; Dirty; Untracked; Ahead; Behind;
                                HasUpstream; OnProtected; LastHash; LastSubject }
    .NOTES  Read-only (só consulta). Fail-safe: sem git ou fora de repo -> Available=$false.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $na = [pscustomobject]@{
        Available = $false; Branch = ''; Detached = $false; Dirty = $false; Untracked = 0
        Ahead = 0; Behind = 0; HasUpstream = $false; OnProtected = $false; LastHash = ''; LastSubject = ''
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $na }
    if (("$(Invoke-GitRO $Root rev-parse --is-inside-work-tree)").Trim() -ne 'true') { return $na }

    $branch = ("$(Invoke-GitRO $Root rev-parse --abbrev-ref HEAD)").Trim()

    $porcelain = @(Invoke-GitRO $Root status --porcelain)
    $dirty = ($porcelain.Count -gt 0)
    $untracked = @($porcelain | Where-Object { $_ -match '^\?\?' }).Count

    $ahead = 0; $behind = 0; $hasUp = $false
    if (("$(Invoke-GitRO $Root rev-parse --abbrev-ref --symbolic-full-name '@{u}')").Trim()) {
        $hasUp = $true
        $counts = ("$(Invoke-GitRO $Root rev-list --left-right --count '@{u}...HEAD')").Trim()
        if ($counts -match '^(\d+)\s+(\d+)$') { $behind = [int]$Matches[1]; $ahead = [int]$Matches[2] }
    }

    $hash = ''; $subj = ''
    $last = "$(Invoke-GitRO $Root log -1 --format=%h%x1f%s)"
    if ($last) { $p = $last -split [char]0x1f, 2; $hash = $p[0].Trim(); if ($p.Count -gt 1) { $subj = $p[1].Trim() } }

    return [pscustomobject]@{
        Available = $true; Branch = $branch; Detached = ($branch -eq 'HEAD'); Dirty = $dirty; Untracked = $untracked
        Ahead = $ahead; Behind = $behind; HasUpstream = $hasUp; OnProtected = ($branch -in @('main', 'master'))
        LastHash = $hash; LastSubject = $subj
    }
}

# --- I/O leitura: "validar a memória" — coerência da KB + auto-memória do Claude (fail-safe) ----
function Get-MemoryStatus {
    <#
    .OUTPUTS [pscustomobject] { Kb={Available;Entries;Invalid;Unverified}; ClaudeMem={Available;Path;Entries;Broken} }
    .NOTES  Ambos read-only e fail-safe: somem em silêncio (Available=$false) se não existirem no projeto.
            KB reusa Get-KbInventory (kb-lint); auto-memória valida ponteiros [Titulo](arquivo.md) do MEMORY.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    # (a) Curadoria/KB: ponteiros quebrados = entradas inválidas (frontmatter) ou não verificadas.
    $kb = [pscustomobject]@{ Available = $false; Entries = 0; Invalid = 0; Unverified = 0 }
    try {
        $kbDir = Join-Path $Root '.claude/kb'
        if (Test-Path -LiteralPath $kbDir -PathType Container) {
            . (Join-Path $PSScriptRoot 'kb-lint.ps1')
            $inv = @(Get-KbInventory -Dir $kbDir)
            $kb = [pscustomobject]@{
                Available  = $true
                Entries    = $inv.Count
                Invalid    = @($inv | Where-Object { -not $_.Valid }).Count
                Unverified = @($inv | Where-Object { $_.PSObject.Properties['Verified'] -and -not $_.Verified }).Count
            }
        }
    }
    catch { Write-Verbose "memória KB indisponível: $($_.Exception.Message)" }

    # (b) Auto-memória do Claude: MEMORY.md repo-local (se houver) -> os arquivos apontados existem?
    $cm = [pscustomobject]@{ Available = $false; Path = ''; Entries = 0; Broken = 0 }
    try {
        $memFile = @(
            (Join-Path $Root '.claude/memory/MEMORY.md'),
            (Join-Path $Root 'memory/MEMORY.md'),
            (Join-Path $Root 'MEMORY.md')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ($memFile) {
            $dir = Split-Path -Parent $memFile
            $text = Get-Content -LiteralPath $memFile -Raw -ErrorAction Stop
            $links = @([regex]::Matches($text, '\]\(([^)]+\.md)\)') | ForEach-Object { $_.Groups[1].Value })
            $broken = 0
            foreach ($l in $links) {
                $target = if ([System.IO.Path]::IsPathRooted($l)) { $l } else { Join-Path $dir $l }
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $broken++ }
            }
            $cm = [pscustomobject]@{ Available = $true; Path = $memFile; Entries = $links.Count; Broken = $broken }
        }
    }
    catch { Write-Verbose "auto-memória indisponível: $($_.Exception.Message)" }

    return [pscustomobject]@{ Kb = $kb; ClaudeMem = $cm }
}

# --- I/O leitura: staleness da curadoria — REUSA o curation-nudge (não reimplementa sinais) -----
function Get-CurationStaleness {
    <#
    .OUTPUTS [pscustomobject] { Available; Signals=[{Signal;Detail;Command}] }
    .NOTES  Dot-source do hook curation-nudge.ps1 (guard interno impede o fluxo rodar) e chama
            Get-CurationSnapshot + Get-StalenessSignals. Read-only. Fail-safe se o hook não existir.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $hook = @(
        (Join-Path $Root '.claude/hooks/curation-nudge.ps1'),                                       # projeto-consumidor
        (Join-Path $PSScriptRoot '../templates/project-scaffold/.claude/hooks/curation-nudge.ps1')  # dogfood (repo do framework)
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $hook) { return [pscustomobject]@{ Available = $false; Signals = @() } }

    try {
        . $hook   # guard `$MyInvocation.InvocationName -ne '.'` mantém o fluxo desligado sob dot-source
        $snap = Get-CurationSnapshot -Root $Root
        return [pscustomobject]@{ Available = $true; Signals = @(Get-StalenessSignals -Snapshot $snap) }
    }
    catch {
        Write-Verbose "staleness indisponível: $($_.Exception.Message)"
        return [pscustomobject]@{ Available = $false; Signals = @() }
    }
}

# --- PURA: "▶ Próximo passo recomendado" — decide UMA ação a partir do estado agregado ----------
function Get-NextStep {
    <#
    .OUTPUTS [pscustomobject] { Command; Reason }
    .NOTES  Prioridade: setup > curadoria incompleta > feature aberta > inbox > staleness > nova feature.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][psobject]$Report)

    # 1) projeto não inicializado
    $c = Get-PropOrNull $Report 'Curation'
    if ($null -eq $c -or -not [bool](Get-PropOrNull $c 'ProjectInitialized')) {
        return [pscustomobject]@{ Command = '/setup'; Reason = 'projeto nao inicializado' }
    }
    # 2) curadoria incompleta
    $next = [string](Get-PropOrNull $c 'NextStep')
    if ($next -and $next -ne 'done') {
        $cmd = switch ($next) {
            'setup' { '/setup' } 'audit-agents' { '/audit-agents' }
            'train-kb' { '/train-kb' } 'sync-context' { '/sync-context' }
            default { '/init' }
        }
        return [pscustomobject]@{ Command = $cmd; Reason = "curadoria incompleta (proximo: $next)" }
    }
    # 3) feature SDD aberta -> avança a mais adiantada (maior rank de fase)
    $inflight = @(@(Get-PropOrNull $Report 'Features') | Where-Object { $_ -and -not $_.Shipped })
    if ($inflight.Count -gt 0) {
        $rankOf = @{ brainstorm = 1; define = 2; design = 3; build = 4 }
        $top = $inflight |
            Sort-Object @{ Expression = { if ($rankOf.ContainsKey([string]$_.Phase)) { $rankOf[[string]$_.Phase] } else { 0 } } }, Feature -Descending |
            Select-Object -First 1
        $cmd = if ($script:SddNextCommand.ContainsKey([string]$top.Phase)) { $script:SddNextCommand[[string]$top.Phase] } else { '/define' }
        return [pscustomobject]@{ Command = $cmd; Reason = "continuar feature $($top.Feature) ($($top.Phase))" }
    }
    # 4) inbox pendente
    $inbox = @(Get-PropOrNull $Report 'Inbox' | Where-Object { $_ })
    if ($inbox.Count -gt 0) {
        return [pscustomobject]@{ Command = '/brainstorm'; Reason = "triagem do inbox ($($inbox.Count) item(ns)) -- ou /dev p/ tarefa pequena" }
    }
    # 5) staleness da curadoria
    $sig = @(Get-PropOrNull (Get-PropOrNull $Report 'Staleness') 'Signals' | Where-Object { $_ })
    if ($sig.Count -gt 0) {
        return [pscustomobject]@{ Command = [string]$sig[0].Command; Reason = [string]$sig[0].Detail }
    }
    # 6) tudo em dia
    return [pscustomobject]@{ Command = '/brainstorm'; Reason = 'tudo em dia -- nova feature (ou /dev p/ tarefa pequena)' }
}

# --- I/O leitura: agrega as seções (fail-safe por seção) --------------------------------------
function Get-StatusReport {
    <#
    .OUTPUTS [pscustomobject] { Root; Curation; Features; Inbox; Git; Memory; Staleness; Peers; NextStep }
    .NOTES  -SelfId (opcional): id desta sessão (anunciado pelo hook peer-heartbeat no SessionStart);
            marca/exclui a própria sessão na seção de peers. Read-only: NÃO poda stale (só filtra na exibição).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyString()][string]$SelfId = ''
    )

    $curation = $null
    try {
        . (Join-Path $PSScriptRoot 'init.ps1')
        $curation = Get-CurationStatus -Root $Root
    }
    catch { Write-Verbose "curadoria indisponível: $($_.Exception.Message)" }

    $features = @()
    try { $features = @(Get-SddFeatureStatus -Root $Root) } catch { Write-Verbose "fase SDD indisponível: $($_.Exception.Message)" }

    $inbox = @()
    try { $inbox = @(Get-InboxItems -Root $Root) } catch { Write-Verbose "inbox indisponível: $($_.Exception.Message)" }

    $git = $null
    try { $git = Get-GitContext -Root $Root } catch { Write-Verbose "git indisponível: $($_.Exception.Message)" }

    $memory = $null
    try { $memory = Get-MemoryStatus -Root $Root } catch { Write-Verbose "memória indisponível: $($_.Exception.Message)" }

    $staleness = $null
    try { $staleness = Get-CurationStaleness -Root $Root } catch { Write-Verbose "staleness indisponível: $($_.Exception.Message)" }

    # Peers: sessões concorrentes ativas (H10). READ-ONLY -> só lê o board, NÃO poda stale.
    $peers = @()
    try {
        . (Join-Path $PSScriptRoot 'peers.ps1')
        $peers = @(Get-PeerInventory -BoardDir (Resolve-PeerBoard -Root $Root) -SelfId $SelfId | Where-Object { -not $_.IsStale })
    }
    catch { Write-Verbose "peers indisponível: $($_.Exception.Message)" }

    $report = [pscustomobject]@{
        Root = $Root; Curation = $curation; Features = $features; Inbox = $inbox
        Git = $git; Memory = $memory; Staleness = $staleness; Peers = $peers; NextStep = $null
    }
    $report.NextStep = Get-NextStep -Report $report
    return $report
}

# --- PURA: painel legível de 3 seções ---------------------------------------------------------
function Format-StatusReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][psobject]$Report)

    $bar = ('=' * 50)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($bar)
    $root = if ($Report -and $Report.Root) { $Report.Root } else { '.' }
    $lines.Add("STATUS - $root")

    # --- Git (contexto de início de sessão) ---
    $g = Get-PropOrNull $Report 'Git'
    if ($g -and $g.Available) {
        $tree = if ($g.Dirty) {
            $u = if ($g.Untracked -gt 0) { ", $($g.Untracked) untracked" } else { '' }
            "alteracoes nao commitadas$u"
        }
        else { 'arvore limpa' }
        $sync = if ($g.HasUpstream -and ($g.Ahead -gt 0 -or $g.Behind -gt 0)) { " | ahead $($g.Ahead)/behind $($g.Behind)" } else { '' }
        $prot = if ($g.OnProtected) { ' | PROTEGIDA -> crie branch de trabalho' } else { '' }
        $lines.Add(("  Git       : {0} | {1}{2}{3}" -f $g.Branch, $tree, $sync, $prot))
        if ($g.LastHash) { $lines.Add("              ultimo: $($g.LastHash) $($g.LastSubject)") }
    }
    elseif ($g) {
        $lines.Add('  Git       : fora de repositorio git (ou git ausente)')
    }

    # --- Curadoria ---
    $c = if ($Report) { $Report.Curation } else { $null }
    if ($null -eq $c) {
        $lines.Add('  Curadoria : indisponivel (camada tools/ nao resolvida?)')
    }
    elseif (-not $c.ProjectInitialized) {
        $lines.Add('  Curadoria : projeto NAO inicializado -> rode /setup')
    }
    else {
        $idx = if ($c.IndexExists) { 'ok' } else { '-' }
        $lines.Add(("  Curadoria : iniciado | agentes(dom): {0} | KB: {1} dominios/{2} entradas | indices: {3}" -f `
                    $c.DomainAgents, $c.KbDomains, $c.KbEntries, $idx))
        $nxt = if ($c.NextStep -eq 'done') { 'tudo curado' } else { "proximo -> /$($c.NextStep)" }
        $lines.Add("              $nxt")
    }

    # --- SDD --- (atribuição explícita: `$x = if(){@()}` emitiria 0 objetos -> $null sob StrictMode)
    $feats = @()
    if ($Report -and $Report.Features) { $feats = @($Report.Features) }
    $inflight = @($feats | Where-Object { -not $_.Shipped })
    $shippedN = @($feats | Where-Object { $_.Shipped }).Count
    if ($inflight.Count -eq 0) {
        $lines.Add('  SDD       : sem feature aberta')
    }
    else {
        $list = ($inflight | ForEach-Object { "$($_.Feature) ($($_.Phase))" }) -join ' | '
        $lines.Add("  SDD       : em andamento -> $list")
    }
    $lines.Add("              entregues: $shippedN")

    # --- Inbox ---
    $inbox = @()
    if ($Report -and $Report.Inbox) { $inbox = @($Report.Inbox) }
    if ($inbox.Count -eq 0) {
        $lines.Add('  Inbox     : vazio')
    }
    else {
        $lines.Add(("  Inbox     : {0} item(ns) -> {1}" -f $inbox.Count, ($inbox -join ', ')))
    }

    # --- Peers (sessões concorrentes ativas — H10; exclui a própria sessão) ---
    $peers = @()
    if ($Report -and (Get-PropOrNull $Report 'Peers')) { $peers = @($Report.Peers) }
    $others = @($peers | Where-Object { -not $_.IsSelf })
    if ($others.Count -eq 0) {
        $lines.Add('  Peers     : nenhuma outra sessao ativa')
    }
    else {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $lines.Add(("  Peers     : {0} sessao(oes) ativa(s) -> rode /peers" -f $others.Count))
        foreach ($p in ($others | Sort-Object { [long]$_.heartbeat_at } -Descending)) {
            $age = [long]$now - [long]$p.heartbeat_at
            $ageTxt = if ($age -lt 45) { 'agora' } elseif ($age -lt 3600) { "ha $([math]::Round($age/60)) min" } else { "ha $([math]::Round($age/3600))h" }
            $br = if ($p.git_branch) { $p.git_branch } else { '?' }
            $sm = if ($p.summary) { $p.summary } else { '(sem summary)' }
            $lines.Add(("              - {0} [{1}] {2} ({3})" -f $p.id, $br, $sm, $ageTxt))
        }
    }

    # --- Memória (validação read-only: KB + auto-memória do Claude) ---
    $m = Get-PropOrNull $Report 'Memory'
    if ($m) {
        $kb = Get-PropOrNull $m 'Kb'
        $cm = Get-PropOrNull $m 'ClaudeMem'
        $parts = @()
        if ($kb -and $kb.Available) {
            $iss = @()
            if ($kb.Invalid -gt 0) { $iss += "$($kb.Invalid) invalida(s)" }
            if ($kb.Unverified -gt 0) { $iss += "$($kb.Unverified) nao verif." }
            $suf = if ($iss.Count -gt 0) { " ($($iss -join ', '))" } else { ' ok' }
            $parts += "KB $($kb.Entries) entrada(s)$suf"
        }
        if ($cm -and $cm.Available) {
            $suf = if ($cm.Broken -gt 0) { "$($cm.Broken) ponteiro(s) quebrado(s)" } else { 'ok' }
            $parts += "auto-mem $($cm.Entries) ($suf)"
        }
        if ($parts.Count -gt 0) { $lines.Add('  Memoria   : ' + ($parts -join ' | ')) }
    }

    # --- Staleness da curadoria (reuso curation-nudge) ---
    $st = Get-PropOrNull $Report 'Staleness'
    if ($st -and $st.Available) {
        $sig = @(Get-PropOrNull $st 'Signals' | Where-Object { $_ })
        if ($sig.Count -eq 0) {
            $lines.Add('  Staleness : em dia')
        }
        else {
            $lines.Add('  Staleness :')
            foreach ($s in $sig) { $lines.Add("              - $($s.Detail) -> $($s.Command)") }
        }
    }

    # --- Próximo passo recomendado (call-to-action) ---
    $ns = Get-PropOrNull $Report 'NextStep'
    if ($ns) {
        $lines.Add('  ' + ('-' * 48))
        $lines.Add("  >> PROXIMO PASSO: $($ns.Command)")
        if ($ns.Reason) { $lines.Add("     $($ns.Reason)") }
    }

    $lines.Add($bar)
    return ($lines -join [Environment]::NewLine)
}
