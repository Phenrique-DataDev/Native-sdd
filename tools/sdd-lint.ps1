<#
.SYNOPSIS
    sdd-lint — invariantes do ciclo SDD sobre `.claude/sdd/`: (1) relatório de build de feature JÁ
    ARQUIVADA não pode continuar em `reports/`; (2) todo BUILD_REPORT declara o que NÃO exercitou.

.DESCRIPTION
    O `/ship` (passo 3) MOVE os artefatos da feature para `archive/<FEATURE>/`. Enquanto o passo
    era ambíguo ("mova/aponte") e ninguém verificava, o relatório ficava para trás e o `/status`
    passava a mentir: feature encerrada aparecendo como *build em andamento*, com o "próximo passo"
    sugerindo `/ship` de algo já shipado (observado em uso real, 2026-07-23).

    É a família "regra sem mecanismo" que esta metodologia batiza, aplicada ao próprio `/ship`:
    a redação do command é a disciplina, este lint é o backstop determinístico. Molde do
    `resync-lint.ps1` — casca fina sobre a fonte única da detecção (`Get-OrphanBuildReports`,
    em `status.ps1`), sem reimplementar o casamento de slug.

    --- Mapa de cobertura (2026-08-26) ---

    A seção `## Não exercitado` do BUILD_REPORT é a peça mais barata do ciclo e a que mais dirige:
    nas rodadas 5 e 6 do `ORCHESTRATE_BASELINE`, **todos** os checks que a revisão comprou estavam
    na superfície que o executor havia declarado como não-coberta (R5: `R05` encoding e `CLI03`
    traceback; R6: o único defeito que o juiz pegava, o delimitador diferente de vírgula). Custo:
    dezenas de tokens. Enquanto isso vivia só na prosa do template, era **convenção** — e convenção
    não é mecanismo (lição do `RULES_LIST_SEM_MECANISMO`).

    Duas regras, porque colar o cabeçalho e deixar o placeholder do template embaixo é o modo de
    falha barato: `build-report-sem-mapa` (seção ausente) e `build-report-mapa-vazio` (seção sem
    nada além de notas do template e placeholders `{...}` por preencher).

    Só varre `reports/` — o `archive/` é histórico imutável e não pode reprovar retroativamente.
    Como o `/ship` move o relatório para o archive, o universo afetado é exatamente o que ainda
    está em construção — que é onde a seção serve para alguma coisa.

    Regras emitidas: `orphan-build-report`, `build-report-sem-mapa`, `build-report-mapa-vazio`
    (todas error). Sem `.claude/sdd/` no alvo, não há findings — o lint é inerte fora de um projeto
    SDD (o `/check` do scaffold roda em projeto real; o `check.ps1` do framework roda no dogfood da
    própria raiz).
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'status.ps1')   # Get-OrphanBuildReports, Resolve-ReportOwnerKey

function New-SddFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-SddLintFindings {
    <#
    .SYNOPSIS  PURA: órfãos (de Get-OrphanBuildReports) -> findings orphan-build-report.
    .OUTPUTS   [pscustomobject[]] (vazio = invariante intacta).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Orphans)

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($o in $Orphans) {
        $findings.Add((New-SddFinding -Severity error -Rule 'orphan-build-report' -Path ([string]$o.Path) `
                    -Message ("feature '$($o.Feature)' ja tem SHIPPED em archive/ — mova este relatorio para " +
                        ".claude/sdd/archive/$($o.Feature)/ (entrega em levas: N relatorios convivem no mesmo diretorio)")))
    }
    return $findings.ToArray()
}

function Format-SddLintReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'sdd-lint: ok (nenhum orfao; todo BUILD_REPORT vivo declara o que nao exercitou)' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("sdd-lint: $(@($Findings).Count) achado(s)")
    foreach ($f in $Findings) { $lines.Add(("  [{0}] {1} - {2} ({3})" -f $f.Severity, $f.Rule, $f.Message, $f.Path)) }
    return ($lines -join [Environment]::NewLine)
}

function Test-SddLintGate {
    <#
    .SYNOPSIS  PURA: passa quando não há finding `error`.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -eq 0)
}

function Test-CoverageMapHeading {
    <#
    .SYNOPSIS  PURA: $true se a linha e o cabecalho da secao do mapa de cobertura (pt-BR ou ingles).
    .DESCRIPTION
        Tolerante ao acento porque o predicado nao pode depender de encoding: este repositorio ja
        perdeu o frontmatter de 6 commands para tres bytes invisiveis (`BOM_CEGA_FRONTMATTER`), e um
        lint que so reconhecesse "Nao exercitado" com til deixaria passar o relatorio salvo sem ele.

        Tolerante ao IDIOMA por uniao, e aqui a uniao e' segura -- diferente do par faca/nao-faca do
        `agent-lint`, que precisou de SELECAO por heading. A diferenca e' o alvo: la o predicado
        varre corpo livre (`\bdo\b` casou 31 vezes em portugues); aqui varre so' a linha de um
        heading, e "not exercised" tem 0 ocorrencia no corpus pt-BR inteiro (medido 2026-08-28, 83
        arquivos). Uniao onde nao colide, selecao onde colide -- nao o contrario.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    return ($Line -match '^\s{0,3}#{2,4}\s*(N[ãa]o\s+exercitado|Not\s+exercised)')
}

function Test-SectionBodyFilled {
    <#
    .SYNOPSIS  PURA: $true se o corpo da secao tem conteudo do AUTOR (nao so o template).
    .DESCRIPTION
        Descarta, nesta ordem: linha em branco; nota do template (`>`); separador de tabela
        (`|---|`) e a linha imediatamente ANTERIOR a ele (o cabecalho da tabela, que vem pronto);
        e qualquer conteudo entre chaves (`{...}`), que e o placeholder por preencher. O que
        sobrar depois disso foi alguem que escreveu -- inclusive um "Nenhuma -- a CLI so aceita
        CSV UTF-8", que e uma resposta legitima e forte.
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Body)

    $doTemplate = [System.Collections.Generic.HashSet[int]]::new()
    for ($i = 0; $i -lt $Body.Count; $i++) {
        if ($Body[$i] -match '^\s*\|[\s\-:|]+\|\s*$') {
            [void]$doTemplate.Add($i)
            if ($i -gt 0) { [void]$doTemplate.Add($i - 1) }
        }
    }

    for ($i = 0; $i -lt $Body.Count; $i++) {
        if ($doTemplate.Contains($i)) { continue }
        $line = $Body[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s{0,3}>') { continue }
        $bare = ($line -replace '\{[^}]*\}', '') -replace '[|\s\-:*_`]', ''
        if ($bare.Length -gt 0) { return $true }
    }
    return $false
}

function Get-CoverageMapFindings {
    <#
    .SYNOPSIS  PURA: (caminho + linhas de UM BUILD_REPORT) -> findings do mapa de cobertura.
    .OUTPUTS   [pscustomobject[]] (vazio = a secao existe e esta preenchida).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )

    $head = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (Test-CoverageMapHeading -Line $Lines[$i]) { $head = $i; break }
    }

    if ($head -lt 0) {
        return @(New-SddFinding -Severity error -Rule 'build-report-sem-mapa' -Path $Path `
                -Message ('BUILD_REPORT sem a secao "## Nao exercitado" -- declare o que o codigo ' +
                    'aceita e voce nao executou (ou "Nenhuma -- <o que sustenta>"): e dela que a ' +
                    'revisao parte, e foi de la que sairam TODOS os checks que a revisao comprou ' +
                    'nas rodadas 5 e 6'))
    }

    $body = [System.Collections.Generic.List[string]]::new()
    for ($i = $head + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s{0,3}#{1,2}\s') { break }   # proxima secao de mesmo nivel ou acima
        $body.Add($Lines[$i])
    }

    if (-not (Test-SectionBodyFilled -Body $body.ToArray())) {
        return @(New-SddFinding -Severity error -Rule 'build-report-mapa-vazio' -Path $Path `
                -Message ('secao "## Nao exercitado" presente mas so com o placeholder do template ' +
                    '-- cabecalho colado nao e mapa de cobertura'))
    }

    return @()
}

function Get-BuildReportPath {
    <#
    .SYNOPSIS  I/O: os BUILD_REPORT_*.md vivos em `.claude/sdd/reports/` (o archive nao entra).
    .OUTPUTS   [string[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $dir = Join-Path $Root '.claude/sdd/reports'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter 'BUILD_REPORT_*.md' -File -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -ExpandProperty FullName)
}

function Invoke-SddLint {
    <#
    .SYNOPSIS  Driver: le o alvo e devolve os findings das tres regras. Read-only.
    .OUTPUTS   [pscustomobject[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @(Get-SddLintFindings -Orphans @(Get-OrphanBuildReports -Root $Root))) { $findings.Add($f) }
    foreach ($p in @(Get-BuildReportPath -Root $Root)) {
        $lines = @(Get-Content -LiteralPath $p -Encoding utf8 -ErrorAction SilentlyContinue)
        foreach ($f in @(Get-CoverageMapFindings -Path $p -Lines $lines)) { $findings.Add($f) }
    }
    return $findings.ToArray()
}
