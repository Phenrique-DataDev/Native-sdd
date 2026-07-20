<#
.SYNOPSIS
    Retrato ADVISORY do contexto always-on de uma sessão: mede o que é lido do DISCO (rules, âncoras
    CLAUDE.md/AGENTS.md, índice de memória, e a superfície de descrição de commands/agents/skills) e
    DECLARA o que não é medível do disco (system prompt base, schemas de tools/MCP). NUNCA bloqueia
    (exit 0 sempre).

.DESCRIPTION
    Funções puras/read-only (molde kb-lint/config-lint). Reusa Measure-KbContentSize e
    Read-KbFrontmatter do kb-lint.ps1 (dot-source) — mesma verdade de "como medir contexto" (conta o
    corpo excluindo fenced code blocks) e de "como ler frontmatter". Rules não têm frontmatter, então
    o arquivo inteiro é o corpo.

    O contexto always-on de uma sessão tem partes de origens diferentes, e o script NÃO as mistura:

      MEDIDO (vem do disco, este script conta):
        - rules       .claude/rules/*.md          — auto-carregadas inteiras, imposto permanente
        - anchor      CLAUDE.md / AGENTS.md       — idem
        - memory      MEMORY.md                   — índice de memória, carregado toda sessão
        - descriptor  commands/agents/skills      — SÓ a superfície (nome + description do
                                                    frontmatter). O CORPO carrega sob demanda, quando
                                                    o item é invocado — contar o corpo aqui INFLARIA
                                                    o retrato (30 commands ≠ 30k tok de always-on).

      NÃO MEDÍVEL DO DISCO (o script declara, nunca estima):
        - system prompt base do Claude Code   — interno do harness
        - schemas das tools nativas           — idem
        - schemas dos MCP servers             — vêm do servidor no handshake, em runtime
      A única fonte de verdade para essas três é o `/context` da sessão. O script ENUMERA os MCP
      configurados (nome), para dizer o que está ligado sem fingir que sabe o peso.

    Fora do always-on, reportado à parte: as ENTRADAS de memória (memory/*.md além do MEMORY.md) são
    recall sob demanda, não imposto de sessão.

    SEM teto, SEM %, SEM headroom, SEM flag de reprovação (revisão G8 v2, 2026-06-16): informar ≠
    julgar. Um teto fixo seria arbitrário e dispararia falso-positivo sobre crescimento legítimo.

    Uso: `pwsh tools/rules-budget.ps1`                 → mede o templates/project-scaffold (o que se entrega)
         `pwsh tools/rules-budget.ps1 -Root .`         → mede este repositório (a sessão atual)
         `pwsh tools/rules-budget.ps1 -Root C:\proj`   → mede um projeto scaffolded real
         `pwsh tools/rules-budget.ps1 -Detailed`       → abre o ranking de commands/agents/skills
         `. ./tools/rules-budget.ps1 ; Invoke-RulesBudget`  (dot-source; exit 0)
#>

[CmdletBinding()]
param(
    [string]$Root,
    [string]$RulesDir,
    [string[]]$AnchorFiles,
    [string]$MemoryDir,
    [switch]$Detailed,
    [switch]$Quiet
)

Set-StrictMode -Version Latest

# Reusa Measure-KbContentSize (B7) e Read-KbFrontmatter: mesma verdade de "como medir contexto"
# (exclui código) e de "como ler frontmatter". Fonte única — nenhuma cópia aqui.
. (Join-Path $PSScriptRoot 'kb-lint.ps1')

# Chars -> tokens: NÃO se define aqui. A conversão é UM valor no repo e vive na FONTE ÚNICA
# (`ConvertTo-KbTokens`/`$script:CharsPerToken` no kb-lint.ps1, dot-sourced acima) — calibrada em
# 2,2 contra o /context real. Ter uma cópia local seria a cópia derivada que envenena (precedente
# Get-KbEntryFile, v0.8.7): as duas divergiriam, e foi exatamente isso que aconteceu quando este
# script usava 2,2 e o kb-lint ainda dividia por 4.
#
# Alias fino, só para não reescrever as chamadas deste arquivo — delega, não reimplementa.
function ConvertTo-Tokens {
    [CmdletBinding()]
    param([int]$Chars)
    return (ConvertTo-KbTokens -Chars $Chars)
}

# --- PURA: inventário de rules + âncoras (arquivo inteiro é o corpo) ---------------------------
function Get-AlwaysOnInventory {
    <#
    .SYNOPSIS
        Mede cada .md de RulesDir + cada AnchorFile existente. Chars via Measure-KbContentSize (exclui
        fenced code); rules sem frontmatter => o arquivo inteiro é o corpo. Dir ausente => só as âncoras
        (ou @() se nenhuma).
    .OUTPUTS
        [pscustomobject[]] @{ Path; Name; Kind('rule'|'anchor'); Chars; Tokens }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RulesDir,
        [string[]]$AnchorFiles = @()
    )

    $targets = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $RulesDir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $RulesDir -Filter '*.md' -File | Sort-Object Name)) {
            $targets.Add(@{ Path = $f.FullName; Kind = 'rule' })
        }
    }
    foreach ($a in $AnchorFiles) {
        if ($a -and (Test-Path -LiteralPath $a -PathType Leaf)) {
            $targets.Add(@{ Path = (Resolve-Path -LiteralPath $a).Path; Kind = 'anchor' })
        }
    }

    # O CLAUDE.md pessoal (~/.claude) e o do projeto têm o MESMO basename: sem desambiguar, o ranking
    # mostra duas linhas 'CLAUDE.md' e o leitor não sabe qual cortar.
    $userClaudeDir = (Join-Path $HOME '.claude')

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $targets) {
        $lines  = @(Get-Content -LiteralPath $t.Path -ErrorAction SilentlyContinue)
        $chars  = Measure-KbContentSize -BodyLines $lines
        $name   = Split-Path $t.Path -Leaf
        if ((Split-Path $t.Path -Parent) -eq $userClaudeDir) { $name = "$name (~/.claude)" }
        $items.Add([pscustomobject]@{
            Path   = $t.Path
            Name   = $name
            Kind   = $t.Kind
            Chars  = $chars
            Tokens = (ConvertTo-Tokens -Chars $chars)
        })
    }
    return $items.ToArray()
}

# --- PURA: superfície de descrição de UM descriptor (command/agent/skill) ----------------------
function Measure-DescriptorSurface {
    <#
    .SYNOPSIS
        Mede a SUPERFÍCIE always-on de um command/agent/skill: o que o harness injeta na lista de
        itens disponíveis é o NOME + a DESCRIPTION, não o corpo. Chars = nome + description (+
        argument-hint quando houver, que também aparece na lista).

        PREDICADO EXPLÍCITO (a lição do Get-KbEntryFile — fonte única do "o que é X"): só conta como
        descriptor o .md com frontmatter que TENHA 'description'. Arquivo gerado sem frontmatter no
        mesmo diretório (ex.: agents/AGENT_MAP.md) NÃO é um agent e não entra — sem isso, o retrato
        contaria um índice gerado como se fosse superfície de sessão.
    .OUTPUTS
        [pscustomobject] @{ Path; Name; Chars; Tokens } — ou $null se não for um descriptor.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fm = Read-KbFrontmatter -Path $Path
    if ($null -eq $fm) { return $null }
    if (-not $fm.Contains('description')) { return $null }

    $desc = [string]$fm['description']
    if ([string]::IsNullOrWhiteSpace($desc)) { return $null }

    # 'name' explícito (skills) ou o basename sem extensão (commands/agents, que viram /nome).
    $name = if ($fm.Contains('name') -and -not [string]::IsNullOrWhiteSpace([string]$fm['name'])) {
        [string]$fm['name']
    }
    else {
        [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }

    $surface = $name + $desc
    if ($fm.Contains('argument-hint')) { $surface += [string]$fm['argument-hint'] }

    $chars = $surface.Length
    return [pscustomobject]@{
        Path   = (Resolve-Path -LiteralPath $Path).Path
        Name   = $name
        Chars  = $chars
        Tokens = (ConvertTo-Tokens -Chars $chars)
    }
}

# --- PURA: inventário de descriptors de um diretório -------------------------------------------
function Get-DescriptorInventory {
    <#
    .SYNOPSIS
        Varre um diretório de commands/agents (.md diretos) ou skills (<nome>/SKILL.md) e devolve a
        superfície de cada descriptor válido. Dir ausente => @() (degrada, nunca lança).
    .OUTPUTS
        [pscustomobject[]] @{ Path; Name; Kind; Chars; Tokens }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][ValidateSet('command', 'agent', 'skill')][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }

    $files = if ($Kind -eq 'skill') {
        @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'SKILL.md' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }
    else {
        @(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($f in ($files | Sort-Object)) {
        $d = Measure-DescriptorSurface -Path $f
        if ($null -eq $d) { continue }   # sem frontmatter/description => não é descriptor
        $items.Add([pscustomobject]@{
            Path = $d.Path; Name = $d.Name; Kind = $Kind; Chars = $d.Chars; Tokens = $d.Tokens
        })
    }
    return $items.ToArray()
}

# --- PURA: posturas sob demanda (.claude/postures/) — medidas, FORA do total always-on ---------
function Get-PostureInventory {
    <#
    .SYNOPSIS
        Mede os .md de PosturesDir (`.claude/postures/`). Essas rules vivem FORA de `.claude/rules/`
        de propósito: o harness varre `rules/`, não esta pasta — então custam **0 token** até um
        command lê-las (`/max` no Passo 0, `/orchestrate`).

        São medidas e reportadas para que o ganho seja AUDITÁVEL (e uma regressão — alguém devolver
        uma postura ao always-on — apareça no retrato), mas NUNCA entram no total always-on: elas não
        estão no contexto de uma sessão que não as aciona.
    .OUTPUTS
        [pscustomobject[]] @{ Path; Name; Kind('posture'); Chars; Tokens }
    #>
    [CmdletBinding()]
    param([string]$PosturesDir)

    if (-not $PosturesDir -or -not (Test-Path -LiteralPath $PosturesDir -PathType Container)) { return @() }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $PosturesDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $lines = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
        $chars = Measure-KbContentSize -BodyLines $lines
        $items.Add([pscustomobject]@{
            Path   = $f.FullName
            Name   = $f.Name
            Kind   = 'posture'
            Chars  = $chars
            Tokens = (ConvertTo-Tokens -Chars $chars)
        })
    }
    return $items.ToArray()
}

# --- PURA: footprint da memória (índice always-on × entradas sob demanda) ----------------------
function Get-MemoryFootprint {
    <#
    .SYNOPSIS
        Separa o que é imposto de sessão do que não é: MEMORY.md é o ÍNDICE, carregado toda sessão
        (always-on); as demais entradas .md são RECALL sob demanda (entram via system-reminder só
        quando relevantes) — medidas, mas reportadas fora do total always-on.
    .OUTPUTS
        [pscustomobject] @{ IndexItem; Entries; EntryCount; EntryTokens }
    #>
    [CmdletBinding()]
    param([string]$MemoryDir)

    $empty = [pscustomobject]@{ IndexItem = $null; Entries = @(); EntryCount = 0; EntryTokens = 0 }
    if (-not $MemoryDir -or -not (Test-Path -LiteralPath $MemoryDir -PathType Container)) { return $empty }

    $index   = $null
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($f in (Get-ChildItem -LiteralPath $MemoryDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $lines = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
        $chars = Measure-KbContentSize -BodyLines $lines
        $item  = [pscustomobject]@{
            Path   = $f.FullName
            Name   = $f.Name
            Kind   = 'memory'
            Chars  = $chars
            Tokens = (ConvertTo-Tokens -Chars $chars)
        }
        if ($f.Name -eq 'MEMORY.md') { $index = $item } else { $entries.Add($item) }
    }

    $entryTokens = 0
    foreach ($e in $entries) { $entryTokens += [int]$e.Tokens }

    return [pscustomobject]@{
        IndexItem   = $index
        Entries     = $entries.ToArray()
        EntryCount  = $entries.Count
        EntryTokens = $entryTokens
    }
}

# --- PURA: enumera MCP servers configurados (NOME apenas — o peso não vem do disco) ------------
function Get-ConfiguredMcpServer {
    <#
    .SYNOPSIS
        Lista os nomes dos MCP servers DECLARADOS EM ARQUIVO: bloco 'mcpServers' na raiz de cada config
        (.mcp.json / .claude/settings*.json / ~/.claude.json) E o bloco por-projeto em
        ~/.claude.json -> projects['<caminho>'].mcpServers.

        NÃO mede o peso: o schema das tools chega do servidor no handshake, em runtime — estimar isso
        do disco seria inventar. Serve só para dizer O QUE está ligado.

        NÃO enxerga tudo, e isso é honesto: conectores gerenciados pela conta (claude.ai — Gmail,
        Drive, Calendar, claude-in-chrome…) não têm declaração em disco nenhuma. Ausência aqui NÃO
        significa "nenhum MCP na sessão" — só o /context sabe.

        ConvertFrom-Json usa -AsHashtable de propósito: o ~/.claude.json real tem chaves que só diferem
        no casing ('C:/…' e 'c:/…'), e o parse em PSCustomObject FALHA nesse caso. Sem isso a função
        cai no catch e reporta 'nenhum MCP' em silêncio — degradação muda, o pior tipo.
    .OUTPUTS
        [string[]] — nomes ordenados, sem duplicata. @() se nada declarado em arquivo.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ConfigPaths = @(),
        [string]$ProjectPath
    )

    $names = [System.Collections.Generic.List[string]]::new()

    $addKeys = {
        param($Servers)
        if ($Servers -isnot [hashtable] -and $Servers -isnot [System.Collections.IDictionary]) { return }
        foreach ($k in $Servers.Keys) {
            if ($k -and $names -notcontains $k) { $names.Add([string]$k) }
        }
    }

    # Normaliza p/ comparar caminho de projeto: ~/.claude.json grava com '/' e casing inconsistente.
    $wanted = if ($ProjectPath) { ($ProjectPath -replace '\\', '/').TrimEnd('/') } else { $null }

    foreach ($p in $ConfigPaths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $json = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch { continue }   # JSON inválido/ilegível não derruba o retrato (advisory)
        if ($json -isnot [hashtable] -and $json -isnot [System.Collections.IDictionary]) { continue }

        if ($json.ContainsKey('mcpServers')) { & $addKeys $json['mcpServers'] }

        # Bloco por-projeto (só o ~/.claude.json tem): projects['C:/caminho/do/projeto'].mcpServers
        if ($wanted -and $json.ContainsKey('projects')) {
            $projects = $json['projects']
            if ($projects -is [hashtable] -or $projects -is [System.Collections.IDictionary]) {
                foreach ($k in $projects.Keys) {
                    if ((($k -replace '\\', '/').TrimEnd('/')) -ine $wanted) { continue }
                    $entry = $projects[$k]
                    if (($entry -is [hashtable] -or $entry -is [System.Collections.IDictionary]) -and $entry.ContainsKey('mcpServers')) {
                        & $addKeys $entry['mcpServers']
                    }
                }
            }
        }
    }
    return @($names | Sort-Object)
}

# --- PURA: junta tudo num inventário de sessão -------------------------------------------------
function Get-SessionInventory {
    <#
    .SYNOPSIS
        Compõe o retrato completo a partir das partes puras. Cada componente degrada sozinho (dir
        ausente => vazio), então medir um scaffold (sem memória) e um projeto real (com) usa o mesmo
        caminho de código.
    .OUTPUTS
        [pscustomobject] @{ AlwaysOn; Descriptors; Memory; McpServers }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RulesDir,
        [string[]]$AnchorFiles = @(),
        [string]$CommandsDir,
        [string]$AgentsDir,
        [string]$SkillsDir,
        [string]$PosturesDir,
        [string]$MemoryDir,
        [string[]]$McpConfigPaths = @(),
        [string]$ProjectPath
    )

    $alwaysOn = @(Get-AlwaysOnInventory -RulesDir $RulesDir -AnchorFiles $AnchorFiles)

    $desc = [System.Collections.Generic.List[object]]::new()
    if ($CommandsDir) { $desc.AddRange([object[]]@(Get-DescriptorInventory -Dir $CommandsDir -Kind 'command')) }
    if ($AgentsDir)   { $desc.AddRange([object[]]@(Get-DescriptorInventory -Dir $AgentsDir   -Kind 'agent'))   }
    if ($SkillsDir)   { $desc.AddRange([object[]]@(Get-DescriptorInventory -Dir $SkillsDir   -Kind 'skill'))   }

    return [pscustomobject]@{
        AlwaysOn    = $alwaysOn
        Descriptors = $desc.ToArray()
        Postures    = @(Get-PostureInventory -PosturesDir $PosturesDir)
        Memory      = (Get-MemoryFootprint -MemoryDir $MemoryDir)
        McpServers  = @(Get-ConfiguredMcpServer -ConfigPaths $McpConfigPaths -ProjectPath $ProjectPath)
    }
}

# --- PURA: monta o retrato (total + ranking por-arquivo, tokens-desc) -------------------------
function Format-AlwaysOnReport {
    <#
    .SYNOPSIS
        Recebe o inventário de sessão e devolve o retrato: total always-on MEDIDO, ranking das rules/
        âncoras (maior→menor), subtotal por categoria de descriptor, memória (índice × entradas) e a
        seção explícita do que NÃO é medível do disco. SEM teto, SEM %, SEM headroom, SEM flag.

        Aceita também um inventário CRU (array de rules/âncoras) — compat com o uso antigo.
    .OUTPUTS
        [pscustomobject] @{ Total; FileCount; Summary; Lines }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object]$Inventory,
        [switch]$Detailed
    )

    # Compat: chamada antiga passava só o array de rules/âncoras.
    $session = if ($Inventory -is [pscustomobject] -and $Inventory.PSObject.Properties.Name -contains 'AlwaysOn') {
        $Inventory
    }
    else {
        [pscustomobject]@{
            AlwaysOn    = @($Inventory)
            Descriptors = @()
            Postures    = @()
            Memory      = [pscustomobject]@{ IndexItem = $null; Entries = @(); EntryCount = 0; EntryTokens = 0 }
            McpServers  = @()
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $total = 0
    $count = 0

    # 1) Rules + âncoras — carregam INTEIRAS, é o grosso do imposto. Ranking por-arquivo.
    $anchored = @($session.AlwaysOn)
    if ($anchored.Count -gt 0) {
        $sub = 0
        foreach ($i in $anchored) { $sub += [int]$i.Tokens }
        $total += $sub; $count += $anchored.Count

        $ranked = @($anchored | Sort-Object @{ e = { [int]$_.Tokens }; Descending = $true }, Name)
        $width = 0
        foreach ($i in $ranked) { if ($i.Name.Length -gt $width) { $width = $i.Name.Length } }

        $lines.Add(('  rules + âncoras — carregam inteiras  ~{0} tok ({1} arquivos)' -f $sub, $anchored.Count))
        foreach ($i in $ranked) {
            $lines.Add(('    {0}  {1,6} tok' -f ([string]$i.Name).PadRight($width), [int]$i.Tokens))
        }
    }

    # 2) Descriptors — só a superfície (nome + description). O corpo NÃO é always-on.
    $descs = @($session.Descriptors)
    if ($descs.Count -gt 0) {
        $sub = 0
        foreach ($d in $descs) { $sub += [int]$d.Tokens }
        $total += $sub; $count += $descs.Count

        $lines.Add('')
        $lines.Add(('  descrições de commands/agents/skills — só nome+description; o corpo carrega sob demanda  ~{0} tok ({1} itens)' -f $sub, $descs.Count))
        foreach ($kind in @('command', 'agent', 'skill')) {
            $ofKind = @($descs | Where-Object { $_.Kind -eq $kind })
            if ($ofKind.Count -eq 0) { continue }
            $kSub = 0
            foreach ($d in $ofKind) { $kSub += [int]$d.Tokens }
            $lines.Add(('    {0}  {1,6} tok  ({2} itens)' -f ("$kind`s").PadRight(10), $kSub, $ofKind.Count))

            if ($Detailed) {
                $rankedK = @($ofKind | Sort-Object @{ e = { [int]$_.Tokens }; Descending = $true }, Name)
                $wK = 0
                foreach ($d in $rankedK) { if ($d.Name.Length -gt $wK) { $wK = $d.Name.Length } }
                foreach ($d in $rankedK) {
                    $lines.Add(('      {0}  {1,5} tok' -f ([string]$d.Name).PadRight($wK), [int]$d.Tokens))
                }
            }
        }
    }

    # 3) Posturas — medidas, mas FORA do total: custam 0 até um command lê-las.
    $postures = @($session.Postures)
    if ($postures.Count -gt 0) {
        $pSub = 0
        foreach ($p in $postures) { $pSub += [int]$p.Tokens }

        $rankedP = @($postures | Sort-Object @{ e = { [int]$_.Tokens }; Descending = $true }, Name)
        $wP = 0
        foreach ($p in $rankedP) { if ($p.Name.Length -gt $wP) { $wP = $p.Name.Length } }

        $lines.Add('')
        $lines.Add(('  posturas SOB DEMANDA — 0 tok até um command lê-las; NÃO somam no always-on  (~{0} tok evitados, {1} arquivos)' -f $pSub, $postures.Count))
        foreach ($p in $rankedP) {
            $lines.Add(('    {0}  {1,6} tok' -f ([string]$p.Name).PadRight($wP), [int]$p.Tokens))
        }
    }

    # 4) Memória — o ÍNDICE é always-on; as ENTRADAS são recall sob demanda (fora do total).
    $mem = $session.Memory
    if ($mem.IndexItem -or $mem.EntryCount -gt 0) {
        $lines.Add('')
        $lines.Add('  memória')
        if ($mem.IndexItem) {
            $total += [int]$mem.IndexItem.Tokens; $count += 1
            $lines.Add(('    MEMORY.md  {0,6} tok  (índice — carrega toda sessão)' -f [int]$mem.IndexItem.Tokens))
        }
        if ($mem.EntryCount -gt 0) {
            $lines.Add(('    entradas   {0,6} tok  ({1} arquivos — recall SOB DEMANDA, fora do total always-on)' -f [int]$mem.EntryTokens, [int]$mem.EntryCount))
        }
    }

    # 5) O que este script NÃO mede — declarado, nunca estimado.
    $lines.Add('')
    $lines.Add('  NÃO medível do disco (só o /context da sessão dá o número):')
    $lines.Add('    - system prompt base do Claude Code   (interno do harness)')
    $lines.Add('    - schemas das tools nativas           (interno do harness)')
    $mcp = @($session.McpServers)
    if ($mcp.Count -gt 0) {
        $lines.Add(('    - schemas dos MCP servers             ({0} em arquivo: {1})' -f $mcp.Count, ($mcp -join ', ')))
    }
    else {
        $lines.Add('    - schemas dos MCP servers             (nenhum declarado em arquivo)')
    }
    $lines.Add('      ^ conectores da conta (Gmail/Drive/chrome…) não se declaram em disco — a lista acima nunca é completa')

    return [pscustomobject]@{
        Total     = $total
        FileCount = $count
        Summary   = ('always-on MEDIDO: ~{0} tok ({1} arquivos) — + não medido, ver /context' -f $total, $count)
        Lines     = $lines.ToArray()
    }
}

# --- Orquestra (read-only; imprime; SEMPRE exit 0 quando chamada como script) -----------------
function Invoke-RulesBudget {
    [CmdletBinding()]
    param(
        [string]$Root,
        [string]$RulesDir,
        [string[]]$AnchorFiles,
        [string]$MemoryDir,
        [switch]$Detailed,
        [switch]$Quiet
    )

    # Root default: o project-scaffold (o que o framework ENTREGA a um projeto). -Root . mede a sessão
    # atual; -Root <proj> mede um projeto scaffolded real.
    if (-not $Root) {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $Root = Join-Path $repoRoot 'templates/project-scaffold'
    }
    $Root = (Resolve-Path -LiteralPath $Root -ErrorAction SilentlyContinue).Path

    if (-not $RulesDir) { $RulesDir = Join-Path $Root '.claude/rules' }
    if (-not $AnchorFiles) {
        # O ~/.claude/CLAUDE.md do USUÁRIO também é always-on (vale p/ toda sessão, de qualquer
        # projeto) — sem ele o retrato perde um arquivo inteiro e não fecha com o /context.
        $AnchorFiles = @(
            (Join-Path $Root 'CLAUDE.md')
            (Join-Path $Root 'AGENTS.md')
            (Join-Path $HOME '.claude/CLAUDE.md')
        )
    }

    $commandsDir = Join-Path $Root '.claude/commands'
    $agentsDir   = Join-Path $Root '.claude/agents'
    $skillsDir   = Join-Path $Root '.claude/skills'
    $posturesDir = Join-Path $Root '.claude/postures'

    # Memória vive fora do repo (~/.claude/projects/<slug>/memory), com o slug derivado do caminho do
    # projeto: cada [:\/] vira '-'. Ausente => componente degrada p/ vazio, sem erro.
    if (-not $MemoryDir -and $Root) {
        $slug      = ($Root -replace '[:\\/]', '-')
        $MemoryDir = Join-Path $HOME ".claude/projects/$slug/memory"
    }

    $mcpPaths = @(
        (Join-Path $Root '.mcp.json')
        (Join-Path $Root '.claude/settings.json')
        (Join-Path $Root '.claude/settings.local.json')
        (Join-Path $HOME '.claude.json')
    )

    $inv    = Get-SessionInventory -RulesDir $RulesDir -AnchorFiles $AnchorFiles `
                                   -CommandsDir $commandsDir -AgentsDir $agentsDir -SkillsDir $skillsDir `
                                   -PosturesDir $posturesDir `
                                   -MemoryDir $MemoryDir -McpConfigPaths $mcpPaths -ProjectPath $Root
    $report = Format-AlwaysOnReport -Inventory $inv -Detailed:$Detailed
    $reportText = ($report.Lines -join [Environment]::NewLine)

    if (-not $Quiet) {
        Write-Host $report.Summary
        if ($reportText) { Write-Host $reportText }
    }
    return [pscustomobject]@{
        Inventory = $inv
        Total     = $report.Total
        Summary   = $report.Summary
        Report    = $reportText
    }
}

# --- Guard: roda só quando NÃO dot-sourced. ADVISORY: exit 0 SEMPRE ---------------------------
if ($MyInvocation.InvocationName -ne '.') {
    # Splat condicional: só passa o que foi dado, p/ não bindar param vazio (anularia os defaults
    # derivados do -Root). Sem args => retrato completo do project-scaffold.
    $splat = @{ Quiet = $Quiet; Detailed = $Detailed }
    if ($Root)        { $splat.Root = $Root }
    if ($RulesDir)    { $splat.RulesDir = $RulesDir }
    if ($AnchorFiles) { $splat.AnchorFiles = $AnchorFiles }
    if ($MemoryDir)   { $splat.MemoryDir = $MemoryDir }
    $null = Invoke-RulesBudget @splat
    exit 0
}
