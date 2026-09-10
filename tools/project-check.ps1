<#
.SYNOPSIS
    project-check (B12-frente-3) — parte determinística do /check: verifica a CONFORMIDADE dos
    artefatos `.claude/` CURADOS no projeto-alvo (KB, agentes de domínio, settings.json) e devolve
    um veredito agregado. Read-only.

.DESCRIPTION
    Funções PURAS/read-only, dot-sourceáveis e testáveis. **Reusa os lints existentes** (dot-source de
    `kb-lint.ps1`/`agent-lint.ps1`/`config-lint.ps1`) — NÃO reimplementa parsing de frontmatter/JSON:
      - KB     : Get-KbInventory (frontmatter por-entrada: Errors→error, OverBudget→warn — advisory/B7)
                 + Invoke-KbLint (relacional: dangling-related). Get-KbInventory NÃO roda no check.ps1
                 do framework (KB do scaffold é vazia) → o /check é a porta de execução dele no alvo.
      - AGENT  : Invoke-AgentLint (frontmatter + colisão + corpo + relacional, numa chamada).
      - CONFIG : Invoke-ConfigLint (forma/permissions amplo/regra de caminho ignorada pelo
                 harness/hook arriscado) sobre settings*.json.
      - SDD    : Invoke-SddLint (orphan-build-report + build-report-sem-mapa/-mapa-vazio) —
                 relatório de feature JÁ arquivada que ficou em `.claude/sdd/reports/`, o que faz o
                 /status reportar build aberto numa feature encerrada (backstop do passo 3 do /ship,
                 2026-07-23); e BUILD_REPORT vivo sem a seção `## Não exercitado` preenchida — o mapa
                 de cobertura de onde saíram TODOS os defeitos que a revisão comprou nas rodadas 5 e
                 6 do baseline (2026-08-26).
      - LINK   : Invoke-LinkLint (broken-link) — link markdown RELATIVO apontando para arquivo que
                 não existe. O lint nasceu em 2026-08-14 no check.ps1 do FRAMEWORK, motivado por 3
                 links quebrados dos quais 2 estavam em arquivos DISTRIBUÍDOS; ficou só de um lado.
                 O scaffold entrega ~76 `.md` com links relativos, e quem editasse essas cópias
                 dentro do próprio projeto não tinha mecanismo nenhum que acusasse o erro que o lint
                 existe para pegar — a família "regra sem mecanismo" aplicada ao próprio corretivo.

                 CONFERIDO ANTES DE LIGAR (2026-08-16, projeto criado com new-project.ps1): o lint
                 roda limpo num projeto recém-criado — 0 achados, COM e SEM `git init`. A exclusão
                 não era decisão técnica (o `Select-NotGitIgnored` degrada sozinho sem git), era
                 esquecimento. O gap é LATENTE: o que sai do framework sai limpo, porque o check da
                 origem pega na origem; o dano só aparece depois que o usuário edita.
      - ENCODING: Get-EncodingFindings (no-bom-utf8 + bom-antes-do-frontmatter) — os três primeiros
                 bytes do arquivo. Entrou em 2026-08-30 (CHECK_PRODUTO_SEM_ENCODING_LINT, gate 5/5).

                 A AUSÊNCIA ANTERIOR NÃO ERA ESQUECIMENTO — era exclusão DECLARADA em 2026-08-04
                 (BOM_NAO_NASCE_COM_ARQUIVO, V4 produto ➖): "o /check do scaffold é read-only por
                 contrato… pôr o -Fix num command declarado read-only seria quebrar o contrato
                 dele, e fica de fora", com dor de cliente medida em zero porque nenhum projeto
                 scaffolded era PowerShell. A decisão estava CERTA para a regra que existia, e
                 envelheceu em 15 dias: `bom-antes-do-frontmatter` só entrou em 2026-08-19 (76f792b,
                 "tres bytes invisiveis apagavam o frontmatter de 6 commands") e vale para `.md`,
                 que TODO projeto scaffolded tem. A premissa segue verdadeira e parou de responder
                 pela pergunta.

                 O QUE ENTRA É SÓ A DETECÇÃO, e isso HONRA a decisão de 2026-08-04 em vez de
                 revertê-la: Get-EncodingFindings lê 3 bytes por arquivo e não escreve nada. O
                 `-Fix` (que escreve) continua FORA — vai como próximo passo do veredito no
                 commands/check.md, igual às outras seções.

                 CONFERIDO ANTES DE LIGAR (2026-08-30, projeto criado com new-project.ps1 v0.10.35,
                 111 arquivos): 0 achados num projeto recém-criado. Por isso NÃO entrou como `warn`
                 na 1ª versão — a única justificativa do warn era o risco de "todo projeto existente
                 passa a reprovar", e a medição o derrubou: só reprova o que o usuário/agente
                 escreveu depois. Severidade `error`, como as vizinhas.

                 E AQUI O "SEM GIT" NÃO É DEGRADAÇÃO INÓCUA COMO NO LINK ACIMA — é CEGUEIRA:
                 Get-EncodingLintTarget enumera por `git ls-files` e, sem git, devolve lista VAZIA,
                 indistinguível de "projeto limpo" (medido: mesmo projeto sem .git → 0 achados).
                 Zero achados viraria veredito `ok` e o painel diria "conforme" sobre algo que nunca
                 olhou — e `New-SddProject` SEM `-Git` é caminho suportado. Por isso a seção sonda o
                 git antes (Test-GitEnumerable) e devolve `n/a`, nunca `ok`.

    Distinto do `tools/check.ps1` (runner do FRAMEWORK: PSScriptAnalyzer + todos os lints + Pester,
    roda no repo da metodologia). Aqui o alvo é um PROJETO scaffolded e o escopo são só os lints
    aplicáveis. Seção sem alvo (ex.: KB vazia) → 'n/a' (não falha). Veredito: error→issues,
    só-warn→warnings, senão ok.

    Compatível com PowerShell 7+. Ver DESIGN_CHECK.md (B12-frente-3).
#>

Set-StrictMode -Version Latest

# Reusa os lints aplicáveis ao alvo. Cada *-lint.ps1 só define funções (sem side-effects no boot).
# `link-lint.ps1` dot-sourceia `pii-lint.ps1` por conta própria (Select-NotGitIgnored, fonte única).
foreach ($dep in @('kb-lint.ps1', 'agent-lint.ps1', 'config-lint.ps1', 'sdd-lint.ps1', 'link-lint.ps1', 'encoding-lint.ps1')) {
    $p = Join-Path $PSScriptRoot $dep
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "project-check.ps1 requer tools/$dep (não encontrado em $p)."
    }
    . $p
}

# --- PURA: finding uniforme (mesmo shape de New-KbFinding/New-AgentFinding/New-ConfigFinding) -----
function New-CheckFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

# --- PURA: Get-KbInventory[] -> finding[] (Errors=>error, OverBudget=>warn advisory/B7, D-003) -----
function ConvertFrom-KbInventory {
    <#
    .SYNOPSIS  Converte o inventário da KB no shape de finding do /check.
    .OUTPUTS   finding[] (vazio = todas as entradas válidas e dentro do budget)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory)

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Inventory) {
        $src = if ($e.PSObject.Properties['Path'] -and $e.Path) { [string]$e.Path } else { '<kb>' }
        if ($e.PSObject.Properties['Valid'] -and -not $e.Valid) {
            foreach ($msg in @($e.Errors)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$msg)) {
                    $findings.Add((New-CheckFinding -Severity error -Rule 'frontmatter' -Path $src -Message ([string]$msg)))
                }
            }
        }
        # OverBudget é ADVISORY (B7: educar, não barrar) -> warn, nunca error (D-003).
        if ($e.PSObject.Properties['OverBudget'] -and $e.OverBudget) {
            $findings.Add((New-CheckFinding -Severity warn -Rule 'over-budget' -Path $src `
                        -Message 'entrada acima do orçamento de tamanho sugerido (advisory)'))
        }
    }
    return $findings.ToArray()
}

# --- PURA: agrega severidades de um conjunto de findings -> veredito (D-004) ----------------------
function Get-CheckVerdict {
    <#
    .SYNOPSIS  ≥1 error => 'issues'; 0 error ∧ ≥1 warn => 'warnings'; senão 'ok'.
    .OUTPUTS   [string] ok | warnings | issues
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { return 'issues' }
    if (@($Findings | Where-Object { $_.Severity -eq 'warn' }).Count -gt 0) { return 'warnings' }
    return 'ok'
}

# --- I/O: roda o(s) lint(s) de uma seção -> { Name; Status; Findings } (fail-safe) ----------------
function Test-GitEnumerable {
    <#
    .SYNOPSIS  I/O: $true se `git` responde E $Root está dentro de uma work tree — ou seja, se
               `Get-EncodingLintTarget` pode de fato enumerar alguma coisa.
    .DESCRIPTION
        Existe por UM motivo, e ele é a diferença entre `n/a` e uma mentira. `Get-EncodingLintTarget`
        enumera por `git ls-files` e engole a falha devolvendo `@()` — o que é indistinguível de
        "projeto sem nenhum arquivo a checar". Zero achados vira veredito `ok`, e o painel passaria a
        imprimir "CONFORME" sobre um projeto que a seção NUNCA OLHOU.

        Não é hipótese: medido em 2026-08-30 num projeto scaffolded real, o mesmo diretório devolve 2
        achados com `.git` e 0 sem. E `New-SddProject` sem `-Git` é caminho suportado, então o modo
        de falha é o caminho comum de quem ainda não versionou.

        É a MESMA classe do zero silencioso que o IDIOMA_PARSER_MONOLINGUE fechou (um BACKLOG em
        inglês fazia o /status reportar `Open=0` com a fila cheia): o instrumento não erra, ele
        responde sobre um conjunto vazio e o leitor lê como aprovação.
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    try {
        $out = & git -C $Root rev-parse --is-inside-work-tree 2>$null
        return ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq 'true')
    }
    catch { return $false }   # git ausente do PATH: mesma resposta, mesma razão
}

function Get-CheckSection {
    <#
    .SYNOPSIS  Verifica uma seção ('kb'|'agent'|'config'|'sdd'|'link'|'encoding'). Alvo ausente => 'n/a' (não falha).
    .OUTPUTS   pscustomobject { Name; Status; Findings[] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('kb', 'agent', 'config', 'sdd', 'link', 'encoding')][string]$Kind,
        [Parameter(Mandatory)][string]$Root
    )

    $claude = Join-Path $Root '.claude'
    try {
        switch ($Kind) {
            'kb' {
                $dir = Join-Path $claude 'kb'
                # "A KB tem entradas?" pela MESMA fonte única do lint/inventário/grafo (Get-KbEntryFile).
                $hasEntries = @(Get-KbEntryFile -Dir $dir).Count -gt 0
                if (-not $hasEntries) { return [pscustomobject]@{ Name = 'kb'; Status = 'n/a'; Findings = @() } }
                $f = @()
                $f += ConvertFrom-KbInventory -Inventory @(Get-KbInventory -Dir $dir)
                $f += @(Invoke-KbLint -Dir $dir)
            }
            'agent' {
                $dir = Join-Path $claude 'agents'
                $hasAgents = (Test-Path -LiteralPath $dir -PathType Container) -and
                    @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') }).Count -gt 0
                if (-not $hasAgents) { return [pscustomobject]@{ Name = 'agent'; Status = 'n/a'; Findings = @() } }
                $f = @(Invoke-AgentLint -Dir $dir)
            }
            'config' {
                $paths = @('settings.json', 'settings.local.json') |
                    ForEach-Object { Join-Path $claude $_ } |
                    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
                if (@($paths).Count -eq 0) { return [pscustomobject]@{ Name = 'config'; Status = 'n/a'; Findings = @() } }
                $f = @(Invoke-ConfigLint -Path @($paths))
            }
            'sdd' {
                # Invariante do /ship passo 3: relatório de feature já arquivada não fica em reports/.
                $sdd = Join-Path $claude 'sdd'
                if (-not (Test-Path -LiteralPath $sdd -PathType Container)) {
                    return [pscustomobject]@{ Name = 'sdd'; Status = 'n/a'; Findings = @() }
                }
                $f = @(Invoke-SddLint -Root $Root)
            }
            'link' {
                # Varre o PROJETO inteiro, não só `.claude/` — os links quebrados que motivaram o
                # lint estavam em command, postura e README, e o scaffold entrega `docs/` e `inbox/`
                # com links também. `Get-LinkLintTarget` já tira o gitignored e o `.claude/sdd/
                # archive/` (histórico imutável), então um projeto com `node_modules`/`.venv` não
                # vira falso-positivo — só paga a enumeração antes do filtro.
                $md = @(Get-LinkLintTarget -Root $Root)
                if ($md.Count -eq 0) { return [pscustomobject]@{ Name = 'link'; Status = 'n/a'; Findings = @() } }
                $f = @(Get-LinkLintFindings -Files $md -Root (Resolve-Path -LiteralPath $Root).Path)
            }
            'encoding' {
                # SEM GIT É `n/a` COM MOTIVO — e o motivo é a parte que importa.
                #
                # A 1ª versão desta guarda só devolvia `n/a`, e a MUTAÇÃO a derrubou: removê-la
                # deixava a suíte verde, porque o `$targets.Count -eq 0` logo abaixo devolve `n/a`
                # do mesmo jeito. Ou seja, era mecanismo sem efeito observável — e a distinção que
                # ela existe para fazer estava sendo perdida justamente no painel: "não há o que
                # checar" e "não consegui olhar" saíam com a MESMA frase (`sem alvo no projeto`),
                # que no segundo caso é falsa — os arquivos estão lá, o git é que não está.
                #
                # Por isso a seção carrega `Note`: o usuário sem git precisa ler o que fazer
                # (`git init`), não um "n/a" que se lê como aprovação. É o que torna a guarda
                # verificável — sem a `Note`, ela não tem como reprovar mutação nenhuma.
                if (-not (Test-GitEnumerable -Root $Root)) {
                    return [pscustomobject]@{
                        Name     = 'encoding'
                        Status   = 'n/a'
                        Findings = @()
                        Note     = 'sem git - nao foi possivel enumerar os arquivos do projeto; rode `git init` para ativar esta secao'
                    }
                }
                # Caminho ABSOLUTO: `Get-EncodingFindings` recorta o prefixo do root por Substring
                # para montar o path relativo do finding, e um `.` como root deixaria o recorte
                # de 1 caractere errado no painel.
                $abs = (Resolve-Path -LiteralPath $Root).Path
                $targets = @(Get-EncodingLintTarget -RepoRoot $abs)
                if ($targets.Count -eq 0) { return [pscustomobject]@{ Name = 'encoding'; Status = 'n/a'; Findings = @() } }
                # Só a DETECÇÃO (lê 3 bytes/arquivo). O `-Fix` escreve e fica fora do /check, que é
                # read-only por contrato — a decisão de 2026-08-04, honrada e não revertida.
                $f = @(Get-EncodingFindings -Path $targets -RepoRoot $abs)
            }
        }
        $f = @($f)
        return [pscustomobject]@{ Name = $Kind; Status = (Get-CheckVerdict -Findings $f); Findings = $f }
    }
    catch {
        # Fail-safe: falha interna da seção não aborta o painel (D / Error Handling).
        $fin = @(New-CheckFinding -Severity error -Rule 'section-failed' -Path $Kind `
                -Message "falha ao verificar a seção '$Kind': $($_.Exception.Message)")
        return [pscustomobject]@{ Name = $Kind; Status = 'error-internal'; Findings = $fin }
    }
}

# --- I/O: monta o report agregado (6 seções + veredito global) -----------------------------------
function Get-ProjectCheckReport {
    <#
    .SYNOPSIS  Verifica kb/agent/config/sdd/link/encoding do projeto em -Root e agrega o veredito. Read-only.
    .OUTPUTS   pscustomobject { Root; Sections[]; Verdict }
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Root = '.')

    $sections = @(
        Get-CheckSection -Kind kb     -Root $Root
        Get-CheckSection -Kind agent  -Root $Root
        Get-CheckSection -Kind config -Root $Root
        Get-CheckSection -Kind sdd    -Root $Root
        Get-CheckSection -Kind link   -Root $Root
        Get-CheckSection -Kind encoding -Root $Root
    )
    # Veredito global só sobre seções que rodaram (n/a não contribui).
    $allFindings = @($sections | Where-Object { $_.Status -ne 'n/a' } | ForEach-Object { $_.Findings } | Where-Object { $_ })
    return [pscustomobject]@{
        Root     = $Root
        Sections = $sections
        Verdict  = (Get-CheckVerdict -Findings @($allFindings))
    }
}

# --- PURA: formata o painel determinístico -------------------------------------------------------
function Format-ProjectCheckReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][psobject]$Report)

    $bar = ('=' * 50)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($bar)
    $root = if ($Report -and $Report.Root) { $Report.Root } else { '.' }
    $lines.Add("CHECK - conformidade da curadoria - $root")
    $lines.Add($bar)

    if ($null -eq $Report) {
        $lines.Add('  indisponivel (camada tools/ nao resolvida?)')
        return ($lines -join [Environment]::NewLine)
    }

    foreach ($s in @($Report.Sections)) {
        $label = $s.Name.PadRight(8)
        if ($s.Status -eq 'n/a') {
            # `Note` distingue "não há alvo" de "não consegui olhar" — as duas coisas são `n/a`, e
            # só a segunda pede ação do usuário. Sem isto o painel dizia `sem alvo no projeto` para
            # um projeto CHEIO de arquivos que a seção não conseguiu enumerar.
            $note = if ($s.PSObject.Properties['Note'] -and $s.Note) { [string]$s.Note } else { 'sem alvo no projeto' }
            $lines.Add("  $label : n/a ($note)")
            continue
        }
        $errs = @($s.Findings | Where-Object { $_.Severity -eq 'error' }).Count
        $warns = @($s.Findings | Where-Object { $_.Severity -eq 'warn' }).Count
        $lines.Add(("  {0} : {1} | {2} error / {3} warn" -f $label, $s.Status, $errs, $warns))
        foreach ($f in @($s.Findings)) {
            $lines.Add(("      [{0}] {1} - {2} ({3})" -f $f.Severity, $f.Rule, $f.Message, $f.Path))
        }
    }

    $lines.Add($bar)
    $verdict = if ($Report.Verdict) { $Report.Verdict } else { 'ok' }
    switch ($verdict) {
        'issues' { $lines.Add('  VEREDITO: ISSUES - ha inconformidade (error). Corrija antes de confiar na curadoria.') }
        'warnings' { $lines.Add('  VEREDITO: CONFORME COM AVISOS - so warnings (advisory). Revisar opcional.') }
        default { $lines.Add('  VEREDITO: CONFORME - artefatos curados em ordem.') }
    }
    return ($lines -join [Environment]::NewLine)
}

# Uso por função (igual aos outros tools, ex.: status/reflect): dot-source + chamada —
#   . ./tools/project-check.ps1 ; Format-ProjectCheckReport (Get-ProjectCheckReport -Root .)
# Sem entry-point de script: o comando /check resolve $toolsRoot e dot-sources este arquivo.
