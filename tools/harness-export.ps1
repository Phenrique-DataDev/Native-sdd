<#
.SYNOPSIS
    Exporta a camada de workflow do scaffold para o dialeto de OUTRO harness (hoje: Codex CLI).

.DESCRIPTION
    O Claude Code carrega `.claude/commands/*.md` como slash commands. O Codex NAO tem command
    definido por usuario -- o `SlashCommand` dele e' enum fechado (codex-rs/tui/src/slash_command.rs).
    O ponto de extensao do Codex e' SKILL: `.agents/skills/<nome>/SKILL.md`, descoberto por walk do
    cwd ate a raiz do projeto (codex-rs/core-skills/src/loader.rs).

    Este script GERA `.agents/skills/` a partir de `.claude/commands/` -- gerador, nao copia. Manter
    os 30 SKILL.md commitados no scaffold seria duplicacao a sincronizar a mao, e a doutrina do repo
    e' fonte unica. Reexecute depois de mexer nos commands.

    NAO instalado por padrao e NAO chamado por nenhum command: e' opt-in de quem usa outro harness.

.NOTES
    Medido em 2026-08-04 (codex-cli 0.146.0), e o que NAO foi medido esta' declarado em
    docs/HARNESS-CONTRACT.md: o payload de EDICAO DE ARQUIVO do Codex (tool_name/file_path) nao pode
    ser medido nesta maquina -- o sandbox de escrita do Windows foi removido do Codex e o caminho
    alternativo exige flag de bypass. Por isso `Get-CodexHooksConfig` so' emite os eventos com
    payload MEDIDO (SessionStart, PreToolUse/Bash) e declara o resto como nao-verificado.
#>

Set-StrictMode -Version Latest

# Afordances que so' existem no Claude Code. Uma skill gerada a partir de um command que as usa
# carrega um aviso -- melhor degradar declarando do que entregar instrucao que o harness nao cumpre.
$script:ClaudeOnlyAffordance = [ordered]@{
    'Agent'    = 'delega a subagentes pela tool `Agent` (o Codex nao expoe equivalente por skill)'
    'Workflow' = 'orquestra pela tool `Workflow` (nao existe no Codex)'
    'Artifact' = 'publica pela tool `Artifact` (nao existe no Codex)'
}

# --- PURA: separa frontmatter YAML simples do corpo -------------------------------------------
function Read-CommandDocument {
    <# .SYNOPSIS  Texto de um command -> { Name, Description, ArgumentHint, Body }. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $description = ''
    $argumentHint = ''
    $tools = ''
    $body = $Text

    $linhas = $Text -split "`r?`n"
    if ($linhas.Count -gt 0 -and $linhas[0].Trim() -eq '---') {
        $fim = -1
        for ($i = 1; $i -lt $linhas.Count; $i++) {
            if ($linhas[$i].Trim() -eq '---') { $fim = $i; break }
        }
        if ($fim -gt 0) {
            foreach ($linha in $linhas[1..($fim - 1)]) {
                if ($linha -match '^\s*description\s*:\s*(.+)$') { $description = $Matches[1].Trim().Trim('"', "'") }
                elseif ($linha -match '^\s*argument-hint\s*:\s*(.+)$') { $argumentHint = $Matches[1].Trim().Trim('"', "'") }
                elseif ($linha -match '^\s*tools\s*:\s*(.+)$') { $tools = $Matches[1].Trim() }
            }
            $resto = if ($fim + 1 -lt $linhas.Count) { $linhas[($fim + 1)..($linhas.Count - 1)] } else { @() }
            $body = ($resto -join "`n").TrimStart("`n")
        }
    }

    return [pscustomobject]@{
        Name         = $Name
        Description  = $description
        ArgumentHint = $argumentHint
        Tools        = $tools
        Body         = $body
    }
}

# --- PURA: quais afordances Claude-only o corpo usa? ------------------------------------------
function Get-ClaudeOnlyAffordance {
    <# .SYNOPSIS  Corpo do command -> lista de avisos de degradacao (vazia se nenhuma). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    $achados = @()
    foreach ($chave in $script:ClaudeOnlyAffordance.Keys) {
        if ($Body -match "\b$chave\b") { $achados += "``$chave`` — $($script:ClaudeOnlyAffordance[$chave])" }
    }
    return , @($achados)
}

# --- PURA: command -> conteudo de um SKILL.md do Codex -----------------------------------------
function ConvertTo-CodexSkillContent {
    <# .SYNOPSIS  Documento de command -> texto do SKILL.md (frontmatter name/description + corpo). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)

    $desc = if ($Document.Description) { $Document.Description } else { "Fluxo $($Document.Name) do scaffold SDD." }
    if ($desc -notmatch '[.!?]$') { $desc = "$desc." }
    if ($Document.ArgumentHint) { $desc = "$desc Argumento: $($Document.ArgumentHint)." }
    # Frontmatter do Codex e' YAML: aspas duplas exigem escape para nao quebrar o parse.
    $descYaml = $desc -replace '"', '\"'

    $avisos = Get-ClaudeOnlyAffordance -Body $Document.Body

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine("name: $($Document.Name)")
    [void]$sb.AppendLine("description: `"$descYaml`"")
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("<!-- GERADO por tools/harness-export.ps1 a partir de .claude/commands/$($Document.Name).md.")
    [void]$sb.AppendLine('     NAO edite aqui: edite o command e reexporte. Fonte unica e o command. -->')
    [void]$sb.AppendLine('')
    if ($Document.ArgumentHint) {
        # '$ARGUMENTS' fica em string LITERAL: em string interpolada o StrictMode reprova a variavel.
        [void]$sb.AppendLine("> **Argumento:** $($Document.ArgumentHint). No Claude Code vem por " + '`$ARGUMENTS`;')
        [void]$sb.AppendLine('> aqui, peca ao usuario se ele nao tiver dito.')
        [void]$sb.AppendLine('')
    }
    if ($avisos.Count -gt 0) {
        [void]$sb.AppendLine('> **Degradacao neste harness** — o fluxo abaixo foi escrito para o Claude Code e usa:')
        foreach ($aviso in $avisos) { [void]$sb.AppendLine("> - $aviso") }
        [void]$sb.AppendLine('>')
        [void]$sb.AppendLine('> Execute o passo voce mesmo, em sequencia, em vez de delegar. O resto do contrato vale igual.')
        [void]$sb.AppendLine('')
    }
    [void]$sb.Append($Document.Body)
    return $sb.ToString()
}

# --- PURA: diretorio de commands -> plano de exportacao ---------------------------------------
function Get-CodexSkillPlan {
    <# .SYNOPSIS  Lista de nomes de command -> alvos relativos em .agents/skills/. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CommandName)
    $plano = foreach ($nome in ($CommandName | Sort-Object)) {
        [pscustomobject]@{
            Name      = $nome
            # ${nome} com chaves: sem elas o parser le `$nome.md` como acesso a propriedade.
            SourceRel = ".claude/commands/${nome}.md"
            TargetRel = ".agents/skills/${nome}/SKILL.md"
        }
    }
    return , @($plano)
}

# --- PURA: config de hooks do Codex, SO com os eventos de payload medido ----------------------
function Get-CodexHooksConfig {
    <#
    .SYNOPSIS
        Gera o conteudo de .codex/hooks.json para os hooks de projeto do scaffold.
    .DESCRIPTION
        O settings.json do Claude Code usa ${CLAUDE_PROJECT_DIR}, que NAO existe no Codex -- por isso
        os caminhos aqui sao absolutos, resolvidos na geracao. Mova o projeto => reexporte.

        Emite SO os eventos cujo payload foi MEDIDO no codex-cli 0.146.0 (SessionStart; PreToolUse
        com tool_name=Bash). Write/Edit ficam de fora com o porque escrito no proprio arquivo: o
        payload de edicao nao pode ser medido nesta maquina, e hook que le um campo que talvez nao
        exista degrada em silencio -- exatamente o modo de falha que o gate de confianca do Codex ja
        cria uma vez.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SessionStartHook
    )
    $raiz = ($ProjectRoot -replace '\\', '/').TrimEnd('/')
    $hooks = foreach ($h in $SessionStartHook) {
        [ordered]@{ type = 'command'; command = "pwsh -NoProfile -File $raiz/.claude/hooks/$h" }
    }
    $obj = [ordered]@{
        '_comment'          = 'GERADO por tools/harness-export.ps1. Caminhos ABSOLUTOS: o Codex nao tem ${CLAUDE_PROJECT_DIR}. Moveu o projeto, reexporte.'
        '_comment_confianca' = 'COPIAR NAO BASTA: o Codex gateia hook por confianca. Rode /hooks no Codex e confie, ou use --dangerously-bypass-hook-trust em automacao. A confianca e por HASH do command: mudou a linha, para de rodar.'
        '_comment_escopo'   = 'So eventos de payload MEDIDO (SessionStart). PostToolUse/PreToolUse de Write|Edit ficaram de fora: o payload de edicao de arquivo do Codex nao foi verificado -- ver docs/HARNESS-CONTRACT.md. Hook que le campo inexistente degrada em silencio.'
        hooks               = [ordered]@{ SessionStart = @([ordered]@{ hooks = @($hooks) }) }
    }
    return ($obj | ConvertTo-Json -Depth 8)
}

# ==============================================================================================
#  AGENT ROLES -- .claude/agents/*.md  ->  $CODEX_HOME/agents/<slug>/<nome>.toml
#
#  MEDIDO no codex-cli 0.146.0 (2026-08-05), e o que foi medido contradiz o que este repositorio
#  afirmava sobre o assunto:
#
#  1. O parser de agente em MARKDOWN (external-agent-migration/src/subagents.rs), que o backlog
#     citava como "os 12 agentes ja tem o frontmatter que o Codex le", e' o formato LEGADO -- a
#     feature flag `external_migration` esta' `removed` nesta versao. O formato ATUAL e' TOML
#     (codex-rs/core/src/config/agent_roles.rs).
#  2. A descoberta e' GLOBAL, nao por projeto. Sonda: um .toml com campo invalido em
#     `$CODEX_HOME/agents/` faz o Codex emitir `warning: Ignoring malformed agent role definition`
#     nomeando o arquivo; o MESMO arquivo em `<projeto>/.agents/` ou `<projeto>/.codex/agents/`
#     nao produz nada -- nem com o projeto sendo repo git e `trust_level = "trusted"`. Por isso
#     este export escreve no CODEX_HOME, e nao dentro do projeto: gerar onde o Codex nao le seria
#     entregar guard inerte de novo (o defeito dos `.example` de hook, achado em 2026-08-04).
#  3. Colisao de `name` e' SILENCIOSA: dois arquivos com `name = "code-reviewer"` em subpastas
#     diferentes => o Codex expoe UM so', sem aviso. Como o namespace e' global e o scaffold e'
#     por projeto, o `name` sai prefixado com o slug do projeto -- sem isso, o segundo projeto
#     scaffolded apagaria os agentes do primeiro sem dizer nada.
#  4. `sandbox_mode` aceita `read-only` | `workspace-write` | `danger-full-access` (a lista veio da
#     propria mensagem de erro do Codex ao recusar um valor invalido).
#  5. Nao ha equivalente do `tools:` do Claude Code. O role ACEITA uma chave `tools`, mas ela e' a
#     struct `ToolsToml` (liga/desliga ferramenta NATIVA: shell, apply_patch, view_image, plan) --
#     `tools = "Read, Grep"` faz o Codex descartar o role inteiro com `invalid type: string [...]
#     expected struct ToolsToml`, medido. Por isso o allowlist vira TEXTO nas instrucoes, e so' o
#     ler-vs-escrever vira `sandbox_mode`. NAO medido: se `tools = { ... }` dentro de um role surte
#     efeito -- campo desconhecido ali passa em silencio, entao a sonda de erro nao decide.
# ==============================================================================================

# --- PURA: texto -> string basica TOML ---------------------------------------------------------
function ConvertTo-TomlBasicString {
    <# .SYNOPSIS  Escapa para string TOML de uma linha (aspas duplas). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $limpo = $Text -replace '\r?\n', ' '
    $limpo = $limpo -replace '\\', '\\'
    $limpo = $limpo -replace '"', '\"'
    return "`"$limpo`""
}

# --- PURA: texto -> string multi-linha TOML ----------------------------------------------------
function ConvertTo-TomlMultilineString {
    <#
    .SYNOPSIS
        Corpo markdown -> string multi-linha TOML.
    .DESCRIPTION
        Usa a forma LITERAL (''') por padrao: dentro dela nada e' escapado, entao barras, aspas,
        `$` e crase do markdown chegam intactos ao modelo. So' cai para a forma basica (""") se o
        corpo contiver a propria sequencia de fechamento -- ai' o escape e' inevitavel.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -notmatch "'''") {
        return "'''`n$Text`n'''"
    }
    $escapado = $Text -replace '\\', '\\'
    $escapado = $escapado -replace '"', '\"'
    return "`"`"`"`n$escapado`n`"`"`""
}

# --- PURA: nome livre -> slug seguro para namespace de role ------------------------------------

# Letras que NAO tem forma decomposta (o FormD nao as separa em base+diacritico). Minusculas so':
# chave de hashtable no PowerShell e' case-insensitive, entao 'ø'/'Ø' colidiriam no literal -- e o
# fold ja roda depois do ToLowerInvariant.
$script:CodexSlugNaoDecompoe = [ordered]@{
    'ß' = 'ss'; 'ø' = 'o'; 'æ' = 'ae'; 'œ' = 'oe'; 'đ' = 'd'; 'ł' = 'l'; 'þ' = 'th'; 'ð' = 'd'
}

function ConvertTo-CodexAsciiFold {
    <#
    .SYNOPSIS  PURA: texto -> minusculas sem diacritico. 'Ação' -> 'acao', 'café' -> 'cafe'.
    .DESCRIPTION
        Decomposicao Unicode (FormD) separa a letra da marca ('á' -> 'a' + U+0301); descartar as
        marcas (NonSpacingMark) devolve a letra base. NAO usa code page (Latin1/1252): aquilo mapeia
        por byte e o resultado passa a depender da configuracao da maquina -- o slug tem de ser o
        MESMO em qualquer host, porque e' chave de um namespace global.
    .OUTPUTS   [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $t = $Text.ToLowerInvariant()
    foreach ($k in $script:CodexSlugNaoDecompoe.Keys) { $t = $t.Replace($k, $script:CodexSlugNaoDecompoe[$k]) }
    $d = $t.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new($d.Length)
    foreach ($ch in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function ConvertTo-CodexRoleSlug {
    <#
    .SYNOPSIS  Nome de projeto -> slug [a-z0-9-] (o namespace de role e' global).
    .DESCRIPTION
        TRANSLITERA antes de filtrar. Ate a v0.10.32 o filtro `[^a-z0-9]+` rodava direto sobre o
        texto e todo diacritico virava SEPARADOR -- 'gestão-de-usuários' saia 'gest-o-de-usu-rios',
        'café' perdia a ultima letra, e o pior: 'Ação' e 'Aço' saiam AMBOS como 'a-o'.

        Colisao aqui nao e' cosmetica. O HE-022 mediu no codex-cli 0.146.0 que dois roles com o
        mesmo `name` em subpastas distintas fazem o Codex expor UM so', sem aviso -- e o prefixo de
        projeto existe justamente para impedir isso. Com o slug antigo o prefixo NAO protegia: dois
        projetos do mesmo dono chamados `Ação/` e `Aço/` geravam `a-o-debugger` os dois, e um
        apagava os agentes do outro em silencio.

        Fallback com IDENTIDADE, nao fixo. Nome que folda para vazio (CJK, cirilico, emoji) nao pode
        cair todo em 'projeto': isso seria a mesma colisao silenciosa em outro alfabeto -- fechar o
        defeito pela metade. O sufixo e' o SHA-256 do texto ORIGINAL, entao continua deterministico
        (mesmo nome, mesmo slug, em qualquer maquina) e dois nomes distintos nunca colidem.

        LIMITE DECLARADO: nao ha transliteracao de escrita nao-latina -- um projeto `日本語/` recebe
        `projeto-<hash>`, que e' unico mas ilegivel. Legibilidade custaria uma tabela por escrita;
        unicidade e' o que o namespace global exige, e e' o que esta garantido.
    .OUTPUTS   [string] casando ^[a-z0-9-]+$, nunca vazio.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $slug = ((ConvertTo-CodexAsciiFold -Text $Text) -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug) { return $slug }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    }
    finally { $sha.Dispose() }
    return ('projeto-' + (($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join ''))
}

function ConvertTo-CodexRoleSlugLegacy {
    <#
    .SYNOPSIS  PURA: o slug COMO ERA ate a v0.10.32. Existe so' para achar a pasta que ele deixou.
    .DESCRIPTION
        `Export-CodexHarness` so' ESCREVE -- nunca removeu nada do CODEX_HOME. Trocar o algoritmo do
        slug sem isto deixaria `~/.codex/agents/a-o/` no disco de quem ja exportou, com os roles
        antigos AINDA registrados no namespace global: a lista de agentes dobraria em vez de ser
        corrigida. Esta funcao e' o que permite detectar essa pasta e avisar. NAO apaga: o
        CODEX_HOME e' do usuario, e apagar por conta seria decidir por ele.
    .OUTPUTS   [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { $slug = 'projeto' }
    return $slug
}

# --- PURA: allowlist de tools do Claude Code -> sandbox_mode do Codex --------------------------
function Get-CodexSandboxMode {
    <#
    .SYNOPSIS
        Linha `tools:` de um agente -> valor de `sandbox_mode`.
    .DESCRIPTION
        O Codex NAO tem allowlist declarativa por ferramenta; o mais proximo e' o sandbox. Agente
        que nao pede Edit/Write/NotebookEdit vira `read-only`.

        `tools:` AUSENTE significa "todas as ferramentas" no Claude Code -- por isso o vazio cai em
        `workspace-write`, e nao no default restritivo: rebaixar um agente que escreve para
        read-only o faria falhar em silencio no meio do trabalho.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tools)
    if (-not $Tools.Trim()) { return 'workspace-write' }
    if ($Tools -match '\b(Edit|Write|NotebookEdit)\b') { return 'workspace-write' }
    return 'read-only'
}

# --- PURA: agente do scaffold -> conteudo de um role .toml do Codex ----------------------------
function ConvertTo-CodexAgentRole {
    <# .SYNOPSIS  Documento de agente + nome de role -> texto do .toml. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$RoleName
    )
    $sandbox = Get-CodexSandboxMode -Tools $Document.Tools
    $avisos = Get-ClaudeOnlyAffordance -Body $Document.Body

    $cabecalho = [System.Text.StringBuilder]::new()
    [void]$cabecalho.AppendLine("<!-- GERADO por tools/harness-export.ps1 a partir de .claude/agents/$($Document.Name).md.")
    [void]$cabecalho.AppendLine('     NAO edite aqui: edite o agente e reexporte. Fonte unica e o agente. -->')
    [void]$cabecalho.AppendLine('')
    if ($Document.Tools) {
        # Declarar a degradacao vale mais que fingir paridade: o `tools:` restringe POR FERRAMENTA,
        # o `sandbox_mode` so' separa ler de escrever.
        [void]$cabecalho.AppendLine("> **Ferramentas no Claude Code:** $($Document.Tools). Neste harness a restricao equivalente")
        [void]$cabecalho.AppendLine("> e' apenas ``sandbox_mode = `"$sandbox`"``: o ``[tools]`` do Codex liga/desliga ferramenta")
        [void]$cabecalho.AppendLine('> NATIVA (shell, apply_patch, view_image, plan) e nao aceita esta lista de nomes. Respeite')
        [void]$cabecalho.AppendLine('> o escopo acima por conta propria.')
        [void]$cabecalho.AppendLine('')
    }
    if ($avisos.Count -gt 0) {
        [void]$cabecalho.AppendLine('> **Degradacao neste harness** — o texto abaixo foi escrito para o Claude Code e usa:')
        foreach ($aviso in $avisos) { [void]$cabecalho.AppendLine("> - $aviso") }
        [void]$cabecalho.AppendLine('>')
        [void]$cabecalho.AppendLine('> Execute o passo voce mesmo, em vez de delegar.')
        [void]$cabecalho.AppendLine('')
    }

    $instrucoes = $cabecalho.ToString() + $Document.Body

    $desc = if ($Document.Description) { $Document.Description } else { "Agente $($Document.Name) do scaffold SDD." }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# GERADO por tools/harness-export.ps1 a partir de .claude/agents/$($Document.Name).md.")
    [void]$sb.AppendLine('# Reexporte depois de mexer no agente -- este arquivo nao e a fonte.')
    [void]$sb.AppendLine("name = $(ConvertTo-TomlBasicString -Text $RoleName)")
    [void]$sb.AppendLine("description = $(ConvertTo-TomlBasicString -Text $desc)")
    [void]$sb.AppendLine("sandbox_mode = `"$sandbox`"")
    [void]$sb.AppendLine("developer_instructions = $(ConvertTo-TomlMultilineString -Text $instrucoes)")
    return $sb.ToString()
}

# --- PURA: nomes de agente -> plano de roles ---------------------------------------------------
function Get-CodexAgentPlan {
    <# .SYNOPSIS  Nomes de agente + slug do projeto -> alvos relativos ao CODEX_HOME. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AgentName,
        [Parameter(Mandatory)][string]$ProjectSlug
    )
    $plano = foreach ($nome in ($AgentName | Sort-Object)) {
        [pscustomobject]@{
            Name      = $nome
            # Prefixo obrigatorio: o namespace de role e' GLOBAL e a colisao e' silenciosa.
            RoleName  = "$ProjectSlug-$nome"
            SourceRel = ".claude/agents/${nome}.md"
            TargetRel = "agents/$ProjectSlug/${nome}.toml"
        }
    }
    return , @($plano)
}

# --- EFEITO: instala os agent roles no CODEX_HOME ----------------------------------------------
function Export-CodexAgentRole {
    <#
    .SYNOPSIS
        Gera os agent roles .toml de um projeto scaffolded dentro do CODEX_HOME.
    .PARAMETER ProjectRoot
        Raiz do projeto scaffolded (o que tem .claude/agents/).
    .PARAMETER CodexHome
        Default: $env:CODEX_HOME, senao ~/.codex. Escreve em <CodexHome>/agents/<slug>/.
    .PARAMETER DryRun
        Nao escreve; devolve o plano.
    .NOTES
        Escreve FORA do projeto de proposito -- ver o bloco MEDIDO acima: no 0.146.0 o Codex so'
        descobre role no CODEX_HOME. Arquivo que nao carrega name+description e' PULADO, que e'
        exatamente o criterio do `agent_metadata` do Codex (e o que descarta o AGENT_MAP.md gerado).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$CodexHome,
        [switch]$DryRun
    )
    $agentDir = Join-Path $ProjectRoot '.claude/agents'
    if (-not (Test-Path -LiteralPath $agentDir -PathType Container)) {
        throw "Nao encontrei $agentDir -- este nao parece um projeto scaffolded."
    }
    if (-not $CodexHome) {
        $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    }

    $nomePasta = Split-Path -Leaf ($ProjectRoot.TrimEnd('\', '/'))
    $slug = ConvertTo-CodexRoleSlug -Text $nomePasta

    # MIGRACAO (v0.10.33): a pasta que o slug ANTIGO deixou. So' existe se este projeto ja foi
    # exportado antes da correcao E o nome tem diacritico. Read-only de proposito -- ver o .NOTES
    # do ConvertTo-CodexRoleSlugLegacy: apagar no CODEX_HOME e' decisao do usuario, nao nossa.
    $slugLegado = ConvertTo-CodexRoleSlugLegacy -Text $nomePasta
    $roleDirLegado = $null
    if ($slugLegado -ne $slug) {
        $candidato = Join-Path $CodexHome "agents/$slugLegado"
        if (Test-Path -LiteralPath $candidato -PathType Container) { $roleDirLegado = $candidato }
    }
    $arquivos = @(Get-ChildItem -LiteralPath $agentDir -Filter '*.md' -File)
    $plano = Get-CodexAgentPlan -AgentName @($arquivos | ForEach-Object { $_.BaseName }) -ProjectSlug $slug

    $escritos = @()
    $pulados = @()
    foreach ($item in $plano) {
        $origem = Join-Path $ProjectRoot $item.SourceRel
        $doc = Read-CommandDocument -Name $item.Name -Text (Get-Content -LiteralPath $origem -Raw)
        if (-not $doc.Description) { $pulados += $item.Name; continue }

        $conteudo = ConvertTo-CodexAgentRole -Document $doc -RoleName $item.RoleName
        $destino = Join-Path $CodexHome $item.TargetRel
        if (-not $DryRun) {
            $pasta = Split-Path -Parent $destino
            if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
            # Sem BOM, pela mesma razao das skills: o parser do Codex nao espera bytes antes do
            # conteudo. E' o oposto da convencao deste repo (BOM sempre) -- por isso esta' escrito.
            [System.IO.File]::WriteAllText($destino, $conteudo, (New-Object System.Text.UTF8Encoding $false))
        }
        $escritos += $item.TargetRel
    }

    return [pscustomobject]@{
        RoleCount     = $escritos.Count
        Roles         = $escritos
        Skipped       = $pulados
        CodexHome     = $CodexHome
        ProjectSlug   = $slug
        # $null quando nao ha o que migrar (o caso normal). Caminho da pasta de roles que o slug
        # anterior deixou -- quem chama decide o que dizer; esta funcao nao apaga nada.
        StaleRoleDir  = $roleDirLegado
        LegacySlug    = $slugLegado
        DryRun        = [bool]$DryRun
    }
}

# --- EFEITO: escreve o export no projeto -------------------------------------------------------
function Export-CodexHarness {
    <#
    .SYNOPSIS
        Gera .agents/skills/ (a partir de .claude/commands/) e .codex/hooks.json num projeto.
    .PARAMETER ProjectRoot
        Raiz do projeto scaffolded (o que tem .claude/).
    .PARAMETER InstallAgentRole
        TAMBEM instala os agentes de .claude/agents/ como agent roles do Codex. OPT-IN porque
        escreve FORA do projeto (no CODEX_HOME) -- e' o unico lugar onde o 0.146.0 os descobre.
    .PARAMETER CodexHome
        Destino dos agent roles quando -InstallAgentRole. Default: $env:CODEX_HOME, senao ~/.codex.
    .PARAMETER DryRun
        Nao escreve; devolve o plano.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$InstallAgentRole,
        [string]$CodexHome,
        [switch]$DryRun
    )
    $commandDir = Join-Path $ProjectRoot '.claude/commands'
    if (-not (Test-Path -LiteralPath $commandDir -PathType Container)) {
        throw "Nao encontrei $commandDir -- este nao parece um projeto scaffolded."
    }

    $arquivos = @(Get-ChildItem -LiteralPath $commandDir -Filter '*.md' -File)
    $plano = Get-CodexSkillPlan -CommandName @($arquivos | ForEach-Object { $_.BaseName })

    $escritos = @()
    foreach ($item in $plano) {
        $origem = Join-Path $ProjectRoot $item.SourceRel
        $doc = Read-CommandDocument -Name $item.Name -Text (Get-Content -LiteralPath $origem -Raw)
        $conteudo = ConvertTo-CodexSkillContent -Document $doc
        $destino = Join-Path $ProjectRoot $item.TargetRel
        if (-not $DryRun) {
            $pasta = Split-Path -Parent $destino
            if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
            # UTF-8 SEM BOM, de proposito. O parser de frontmatter do Codex faz
            # `content.strip_prefix("---\n")` (external-agent-migration/src/subagents.rs): um BOM
            # antes do `---` faz o strip falhar, o arquivo perde name/description e a skill nao
            # carrega. E' o oposto da convencao deste repo (BOM sempre) -- por isso esta escrito.
            [System.IO.File]::WriteAllText($destino, $conteudo, (New-Object System.Text.UTF8Encoding $false))
        }
        $escritos += $item.TargetRel
    }

    $hookDir = Join-Path $ProjectRoot '.claude/hooks'
    $sessionStart = @()
    if (Test-Path -LiteralPath $hookDir -PathType Container) {
        $sessionStart = @(Get-ChildItem -LiteralPath $hookDir -Filter '*.ps1' -File |
                Where-Object { $_.BaseName -in @('curation-nudge', 'peer-heartbeat') } |
                ForEach-Object { $_.Name })
    }
    $hooksJson = Get-CodexHooksConfig -ProjectRoot $ProjectRoot -SessionStartHook $sessionStart
    $hooksPath = Join-Path $ProjectRoot '.codex/hooks.json'
    if (-not $DryRun) {
        $pasta = Split-Path -Parent $hooksPath
        if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
        [System.IO.File]::WriteAllText($hooksPath, $hooksJson, (New-Object System.Text.UTF8Encoding $true))
    }

    $roles = $null
    if ($InstallAgentRole) {
        $roles = Export-CodexAgentRole -ProjectRoot $ProjectRoot -CodexHome $CodexHome -DryRun:$DryRun
    }

    return [pscustomobject]@{
        SkillCount = $escritos.Count
        Skills     = $escritos
        HooksPath  = '.codex/hooks.json'
        HookCount  = $sessionStart.Count
        RoleCount  = if ($roles) { $roles.RoleCount } else { 0 }
        AgentRole  = $roles
        DryRun     = [bool]$DryRun
    }
}

# Roda so' quando executado como script (nao no dot-source dos testes/commands).
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s') {
    $posicionais = @($args | Where-Object { $_ -notmatch '^-' })
    $alvo = if ($posicionais.Count -gt 0) { $posicionais[0] } else { (Get-Location).Path }
    $comAgentes = [bool](@($args | Where-Object { $_ -match '^-(InstallAgentRole|Agents)$' }).Count)
    $r = Export-CodexHarness -ProjectRoot $alvo -InstallAgentRole:$comAgentes
    Write-Output "Exportadas $($r.SkillCount) skills para .agents/skills/ e $($r.HookCount) hook(s) para $($r.HooksPath)."
    if ($comAgentes) {
        Write-Output "Instalados $($r.RoleCount) agent role(s) em $($r.AgentRole.CodexHome)/agents/$($r.AgentRole.ProjectSlug)/ (prefixo de nome: $($r.AgentRole.ProjectSlug)-)."
        if ($r.AgentRole.StaleRoleDir) {
            # O namespace de role e' GLOBAL: enquanto a pasta antiga existir, o Codex lista os dois
            # conjuntos. Nao apagamos por conta -- o CODEX_HOME e' do usuario.
            Write-Output ''
            Write-Warning ("MIGRACAO: o slug deste projeto mudou de '$($r.AgentRole.LegacySlug)' para " +
                "'$($r.AgentRole.ProjectSlug)' (diacriticos agora sao transliterados, nao viram '-'). " +
                "Os roles ANTIGOS continuam registrados e o Codex vai listar os dois conjuntos.")
            Write-Output "  Confira e remova quando quiser:  Remove-Item -LiteralPath '$($r.AgentRole.StaleRoleDir)' -Recurse"
        }
    }
    else {
        Write-Output "Agent roles NAO instalados (opt-in): rode com -InstallAgentRole. Eles vao para o CODEX_HOME, fora do projeto."
    }
}
