<#
.SYNOPSIS
    Lint de conformidade dos commands à camada tools/ (B11): nenhum command faz dot-source
    CRU de `tools/*.ps1` — deve resolver pela cascata `$toolsRoot` (rules/tooling.md).

.DESCRIPTION
    Funções PURAS (recebem texto Markdown, sem tocar disco) + um I/O fino que varre os
    diretórios de commands e de **rules**. Espelha tools/config-lint.ps1 / tools/agent-lint.ps1
    (sem módulo externo).

    ESCOPO DAS RULES (2026-08-10): a regra `raw-tools-dotsource` nasceu mirando só commands, e
    `rules/orchestration.md` — a rule mais pesada do always-on — trazia `. tools/orchestrate.ps1`
    num bloco executável, passando incólume. Medido num projeto recém-criado: o snippet falha com
    "The term 'tools/orchestrate.ps1' is not recognized". Nas rules a varredura é `-FencedOnly`
    (só dentro de ```/~~~): uma rule legitimamente CITA o antipadrão em prosa — `tooling.md`
    §"O que NÃO fazer" faz exatamente isso. `missing-description` NÃO se aplica a rules.

    Motivação: no projeto-alvo o `cwd` é o projeto e `tools/` não está por path relativo. Um
    `. tools/X.ps1` cru não resolve → curadoria degrada em silêncio. A cascata (rules/tooling.md)
    resolve `$toolsRoot` (relativo → $env:SDD_WORKFLOW_HOME → degradação); este lint garante que
    nenhum command volte ao path cru (regressão).

    O que é VIOLAÇÃO (error, bloqueia o CI):
      - dot-source de path literal `tools/…​.ps1`  (ex.: `. tools/kb-lint.ps1`, `. ./tools/reflect.ps1`,
        inline `` `. tools/telemetry.ps1; …` ``). Casado por âncora de dot-source (início de linha,
        backtick de code-span ou `;`) + `.` + espaço + `tools/…​.ps1`.
      - `missing-description`: command sem `description:` não-vazio no frontmatter YAML. O picker `/`
        do Claude Code mostra essa linha; sem ela, o comando degrada no menu. Cobre frontmatter
        ausente, chave ausente ou valor vazio/só-aspas.

    O que NÃO é violação (não casa, por construção):
      - `. "$toolsRoot/X.ps1"`            → após `. ` vem `"$toolsRoot/`, não `tools/`.
      - camada de KB homônima `` `tools/` `` → não tem `.ps1` após.
      - prosa referencial ("valide com `tools/kb-lint.ps1`", "funções em `tools/x.ps1`") → o
        `tools/` não é precedido pelo operador de dot-source (`. `).

    Severidade: só `error` (alvo determinístico/binário; sem `warn`). Gate bloqueia o CI.
#>

Set-StrictMode -Version Latest

# Dot-source CRU de tools/: âncora (início de linha | backtick de code-span | ';') + '. ' +
# ('./'?) + 'tools/' + nome + '.ps1'. Single-quoted: '' = aspas simples literal; backtick literal.
$script:RxRawToolsDotSource = '(?:^|`|;)\s*\.\s+(?:\./)?tools/[^\s"''`;]*\.ps1'

function Test-HasFrontmatterDescription {
    <#
    .SYNOPSIS  $true se o TEXTO tem frontmatter YAML (--- na 1ª linha) com `description:`
               de valor não-vazio (após remover aspas e espaços). PURA (só texto).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    # Frontmatter = bloco entre o primeiro '---' (1ª linha) e o próximo '---'.
    $m = [regex]::Match($Text, '(?s)\A---\r?\n(.*?)\r?\n---\r?\n')
    if (-not $m.Success) { return $false }
    $fm = $m.Groups[1].Value
    foreach ($line in ($fm -split "\r?\n")) {
        $d = [regex]::Match($line, '^\s*description:\s*(.*)$')
        if (-not $d.Success) { continue }
        $val = $d.Groups[1].Value.Trim().Trim('"').Trim("'").Trim()
        return -not [string]::IsNullOrWhiteSpace($val)
    }
    return $false
}

function New-CommandFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-RawDotSourceFindings {
    <#
    .SYNOPSIS  Varre o TEXTO por dot-source cru de tools/. Tag Path "$Source#L<n>". PURA.
    .DESCRIPTION
        Extraída de Get-CommandLintFindings para servir também às RULES, que não têm
        `description:` no frontmatter e portanto não podem reusar a função inteira. A regra
        (e o regex) continuam em fonte única aqui.
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source,
        [switch]$FencedOnly
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return $findings.ToArray() }

    $lineNo = 0
    $inFence = $false
    foreach ($line in ($Text -split "\r?\n")) {
        $lineNo++
        # -FencedOnly: só linhas dentro de ```/~~~ contam. Uma RULE legitimamente CITA o
        # antipadrão em prosa — `rules/tooling.md` §"O que NÃO fazer" escreve `. tools/<script>.ps1`
        # como exemplo do que evitar. Punir isso puniria a regra por documentar a si mesma.
        if ($line.TrimStart() -match '^(```|~~~)') { $inFence = -not $inFence; continue }
        if ($FencedOnly -and -not $inFence) { continue }

        $m = [regex]::Matches($line, $script:RxRawToolsDotSource)
        foreach ($hit in $m) {
            $findings.Add((New-CommandFinding -Severity error -Rule raw-tools-dotsource `
                        -Path "$Source#L$lineNo" `
                        -Message "dot-source cru de tools/ ($($hit.Value.Trim())) — use a cascata `$toolsRoot (rules/tooling.md)"))
        }
    }
    return $findings.ToArray()
}

function Get-CommandLintFindings {
    <#
    .SYNOPSIS  Varre o TEXTO de um command por dot-source cru de tools/. Tag Path "$Source#L<n>".
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return $findings.ToArray() }

    if (-not (Test-HasFrontmatterDescription -Text $Text)) {
        $findings.Add((New-CommandFinding -Severity error -Rule missing-description `
                    -Path "$Source#L1" `
                    -Message 'frontmatter sem `description:` não-vazio — o picker `/` exibe essa linha'))
    }

    foreach ($f in (Get-RawDotSourceFindings -Text $Text -Source $Source)) { $findings.Add($f) }
    return $findings.ToArray()
}

function Get-OrphanPostureFindings {
    <#
    .SYNOPSIS
        Toda postura de `.claude/postures/` precisa de uma PORTA: um command que a leia, OU uma
        rule (always-on) que mande lê-la. Sem porta, a regra não é carregada por ninguém — ela
        **não existe na prática**, mesmo estando no disco.

        É a falha que a metodologia batiza de "regra sem mecanismo", virada mecanismo. Rules em
        `.claude/rules/` não precisam disto (o harness as varre); posturas, por definição, só chegam
        ao contexto se alguém as ler.

        Complementa o `dangling-related` do kb-lint: lá se checa referência QUEBRADA (aponta p/ algo
        que não existe); aqui, referência AUSENTE (existe algo que ninguém aponta).
    .OUTPUTS
        [pscustomobject[]] (vazio = toda postura tem porta)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PosturesDir,
        [Parameter(Mandatory)][string]$CommandsDir,
        [string]$RulesDir
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    # Sem posturas (ou sem o diretório) => nada a cobrar. Projeto pode legitimamente não usar o padrão.
    if (-not (Test-Path -LiteralPath $PosturesDir -PathType Container)) { return $findings.ToArray() }
    $postures = @(Get-ChildItem -LiteralPath $PosturesDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($postures.Count -eq 0) { return $findings.ToArray() }

    # Sem porta possível, toda postura vira órfã (fail-closed, não passa por omissão).
    #
    # DUAS origens de porta, e a distinção é sobre CARGA, não sobre hierarquia:
    #   - COMMAND: o corpo entra no contexto quando invocado; um `Read` da postura ali é porta.
    #   - RULE:    `.claude/rules/` é always-on por construção do harness, então uma rule que MANDA
    #              ler a postura entrega a instrução em toda sessão — porta igualmente real. É o
    #              padrão das rules condicionais (predicado na rule, disciplina na postura).
    # Um link em AGENTS.md NÃO conta: lá é referência para humano, não instrução carregada.
    #
    # O casamento é pelo PATH `postures/<nome>` — não pelo nome solto do arquivo. Casar só o nome
    # dava FALSO NEGATIVO: os commands citam `../rules/semantic-search.md` (a rule), e isso
    # satisfazia a busca por "semantic-search.md" como se a POSTURA tivesse porta.
    $portalText = ''
    foreach ($dir in @($CommandsDir, $RulesDir)) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $portalText += (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }) -join "`n"
    }

    foreach ($p in $postures) {
        if ($portalText -and $portalText.Contains("postures/$($p.Name)")) { continue }
        $findings.Add((New-CommandFinding -Severity error -Rule orphan-posture `
                    -Path "$($p.Name)#/" `
                    -Message 'postura sem porta: nenhum command nem rule aponta para `postures/<nome>` — regra sem mecanismo (some em silêncio). Dê a ela um command que faça Read, uma rule que mande lê-la, ou mova-a de volta p/ .claude/rules/'))
    }
    return $findings.ToArray()
}

function Get-DanglingPostureFindings {
    <#
    .SYNOPSIS
        O INVERSO do orphan-posture: aqui a PORTA existe e a POSTURA não. Uma rule/command que
        aponta para `postures/x.md` inexistente promete uma disciplina que ninguém vai carregar —
        e falha em silêncio, porque o leitor só descobre ao tentar o `Read`.

        Virou risco real com as rules CONDICIONAIS (2026-08-10): a rule guarda o predicado e delega
        o conteúdo à postura. Renomear ou apagar a postura esvazia a regra sem que nada acuse.
    .OUTPUTS
        [pscustomobject[]] (vazio = todo ponteiro resolve)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PosturesDir,
        [Parameter(Mandatory)][string]$CommandsDir,
        [string]$RulesDir
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($dir in @($CommandsDir, $RulesDir)) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $label = Split-Path $dir -Leaf
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            foreach ($m in [regex]::Matches($text, 'postures/([\w.-]+\.md)')) {
                $name = $m.Groups[1].Value
                if (Test-Path -LiteralPath (Join-Path $PosturesDir $name) -PathType Leaf) { continue }
                $findings.Add((New-CommandFinding -Severity error -Rule dangling-posture-pointer `
                            -Path "$label/$($f.Name)#/" `
                            -Message "aponta para ``postures/$name``, que não existe — a disciplina prometida não carrega para ninguém"))
            }
        }
    }
    return $findings.ToArray()
}

function Format-CommandLintReport {
    <# .SYNOPSIS  Painel legível dos achados, agrupado por arquivo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'command-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $byFile = $Findings | Group-Object { ($_.Path -split '#', 2)[0] }
    foreach ($g in $byFile) {
        $lines.Add("• $($g.Name)")
        foreach ($f in $g.Group) {
            $node = ($f.Path -split '#', 2)[1]
            $lines.Add("    [$($f.Severity)] $($f.Rule) $node — $($f.Message)")
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-CommandLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-CommandLint {
    <#
    .SYNOPSIS  I/O fino: varre todos os *.md de -Dir e agrega os achados. Checa também as posturas
               órfãs (`-PosturesDir`; default: `../postures` ao lado do dir de commands).
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$PosturesDir,
        [string]$RulesDir
    )

    $all = @()
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return @(New-CommandFinding -Severity error -Rule missing-dir -Path "$Dir#/" `
                -Message "diretório de commands inexistente")
    }

    # `.claude/commands` -> `.claude/postures` (irmão). Ausente => a checagem fica inerte.
    if (-not $PosturesDir) { $PosturesDir = Join-Path (Split-Path $Dir -Parent) 'postures' }
    if (-not $RulesDir) { $RulesDir = Join-Path (Split-Path $Dir -Parent) 'rules' }
    $all += Get-OrphanPostureFindings -PosturesDir $PosturesDir -CommandsDir $Dir -RulesDir $RulesDir
    $all += Get-DanglingPostureFindings -PosturesDir $PosturesDir -CommandsDir $Dir -RulesDir $RulesDir

    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        }
        catch {
            $all += New-CommandFinding -Severity error -Rule unreadable -Path "$($file.Name)#/" `
                -Message "arquivo ilegível: $($_.Exception.Message)"
            continue
        }
        $all += Get-CommandLintFindings -Text $text -Source $file.Name
    }

    # RULES: mesma regra de dot-source cru, escopo que faltava. `orchestration.md` trazia
    # `. tools/orchestrate.ps1` num bloco executável e passava porque este lint só varria
    # commands — no projeto scaffolded aquilo falha com "is not recognized" (medido).
    # Só `raw-tools-dotsource`: rules não têm `description:` no frontmatter.
    if (Test-Path -LiteralPath $RulesDir -PathType Container) {
        foreach ($rule in @(Get-ChildItem -LiteralPath $RulesDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            try { $ruleText = Get-Content -LiteralPath $rule.FullName -Raw -ErrorAction Stop }
            catch {
                $all += New-CommandFinding -Severity error -Rule unreadable -Path "rules/$($rule.Name)#/" `
                    -Message "arquivo ilegível: $($_.Exception.Message)"
                continue
            }
            $all += Get-RawDotSourceFindings -Text $ruleText -Source "rules/$($rule.Name)" -FencedOnly
        }
    }
    return @($all)
}
