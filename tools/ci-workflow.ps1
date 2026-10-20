<#
.SYNOPSIS
    ci-workflow — gera o `.github/workflows/ci.yml` mínimo que o /setup e o /adapt OFERECEM (opt-in)
    ao projeto do usuário: roda no CI os mesmos comandos de verificação que o agente roda local.

.DESCRIPTION
    Funções dot-sourceáveis e testáveis (SCAFFOLD_SEM_CI, 2026-10-19):
      - Test-CiOfferApplicable : o projeto deve RECEBER a oferta? Remote no github.com, sem CI
                              nenhum, fora de monorepo, sem stack que dependa de credencial (dbt,
                              terraform). Recusa com motivo; Docker vira ressalva a perguntar.
      - Get-CiSetupActions  : PURA — stack (Tech do Get-StackSignals) → actions de setup do runtime.
                              Só python/dbt, node e go; o resto não ganha step (não inventa versão).
      - New-CiWorkflowYaml  : PURA — comandos → texto do workflow. Cada comando entra como bloco
                              literal (`run: |`), então `:`, `#` e aspas não quebram o YAML.
      - Install-CiWorkflow  : grava `.github/workflows/ci.yml`. **Nunca sobrescreve**: se já existe
                              qualquer workflow, recusa e devolve o motivo.

    Os comandos vêm do usuário (confirmados no /setup rodando uma vez), não de um template por stack.
    Versões das actions conferidas nas releases em 2026-10-19 (`gh api repos/actions/<a>/releases/latest`).
    Compatível com PowerShell 7+.
#>

Set-StrictMode -Version Latest

# Reusa a detecção de stack, monorepo e CI existente (Get-StackSignals/Get-WorkspaceLayout/
# Get-ProjectHygiene) do adapt.ps1 — não reimplementa.
$script:CiAdaptPath = Join-Path $PSScriptRoot 'adapt.ps1'
if (-not (Test-Path -LiteralPath $script:CiAdaptPath -PathType Leaf)) {
    throw "ci-workflow.ps1 requer tools/adapt.ps1 (não encontrado em $script:CiAdaptPath)."
}
. $script:CiAdaptPath
. (Join-Path $PSScriptRoot 'verification.ps1')   # o nudge só reoferece com teste declarado

$script:CiCheckoutAction = 'actions/checkout@v7'

# O "não" do usuário, versionado: sem ele o nudge do SessionStart cobraria o CI em toda sessão.
$script:CiDeclinedMarker = '.claude/ci-offer-declined'
$script:CiRunners = @('ubuntu-24.04', 'windows-2025')

# Stack cujo teste quase sempre precisa de credencial de fora (warehouse, cloud): o runner não tem, e
# o CI nasceria vermelho mesmo com o comando verde local.
$script:CiCredentialStacks = [ordered]@{
    dbt       = 'o dbt test precisa de conexão com o warehouse'
    terraform = 'o plan/validate com provider precisa de credencial de cloud'
}

# Tech (Get-StackSignals) → step de setup. dbt é Python. Versão "flutuante" de propósito (3.x, lts/*,
# go.mod): fixar um número aqui seria escolher pelo usuário.
$script:CiSetupMap = [ordered]@{
    python = [pscustomobject]@{ Uses = 'actions/setup-python@v7'; With = [ordered]@{ 'python-version' = '3.x' } }
    dbt    = [pscustomobject]@{ Uses = 'actions/setup-python@v7'; With = [ordered]@{ 'python-version' = '3.x' } }
    node   = [pscustomobject]@{ Uses = 'actions/setup-node@v7';   With = [ordered]@{ 'node-version' = 'lts/*' } }
    go     = [pscustomobject]@{ Uses = 'actions/setup-go@v7';     With = [ordered]@{ 'go-version-file' = 'go.mod' } }
}

function Get-CiSetupActions {
    <#
    .SYNOPSIS
        Actions de setup para a stack informada, sem repetir (python+dbt = um setup-python).
        Tech fora do mapa não gera step.
    .OUTPUTS
        [pscustomobject[]] { Uses; With }
    #>
    [CmdletBinding()]
    param([string[]]$Tech = @())

    $seen = @{}
    $result = foreach ($t in $Tech) {
        $key = "$t".ToLowerInvariant()
        if (-not $script:CiSetupMap.Contains($key)) { continue }
        $action = $script:CiSetupMap[$key]
        if ($seen.ContainsKey($action.Uses)) { continue }
        $seen[$action.Uses] = $true
        $action
    }
    return @($result)
}

function Get-CiRemoteHost {
    # Host do remote `origin` (https ou ssh), ou $null sem git/remote. Seam mockável nos testes.
    param([Parameter(Mandatory)][string]$Root)
    $url = git -C $Root remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($url)) { return $null }
    if ("$url" -match '^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Test-CiOfferApplicable {
    <#
    .SYNOPSIS
        O /setup e o /adapt devem OFERECER o CI neste projeto? Só com remote no github.com, sem CI
        nenhum (GitHub, GitLab ou Azure), fora de monorepo e sem stack que dependa de credencial.
        Cada recusa vem com o motivo, para o agente dizer ao usuário em vez de ficar calado.
    .OUTPUTS
        [pscustomobject] { Offer; Reasons[]; Tech[]; Caveats[] }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $reasons = [System.Collections.Generic.List[string]]::new()
    $caveats = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath (Join-Path $Root $script:CiDeclinedMarker) -PathType Leaf) {
        $reasons.Add("o usuário recusou antes ($script:CiDeclinedMarker): apague o arquivo para reoferecer")
    }

    $remoteHost = Get-CiRemoteHost -Root $Root
    if (-not $remoteHost) { $reasons.Add('sem remote origin: o Actions só existe depois do repositório no GitHub — ofereça de novo depois do push') }
    elseif ($remoteHost -ne 'github.com') { $reasons.Add("remote em $remoteHost, não no GitHub: o workflow gerado é do GitHub Actions") }

    $hygiene = Get-ProjectHygiene -Root $Root
    if ($hygiene.HasCI) { $reasons.Add("já existe CI: $($hygiene.Evidence.CI -join ', ')") }

    if ($null -ne (Get-WorkspaceLayout -Root $Root)) {
        $reasons.Add('monorepo: um job na raiz não cobre os pacotes; o CI é por pacote e fica com o usuário')
    }

    # ForEach, não `.Tech`: sem stack reconhecida o resultado é vazio, e `.Tech` lança sob StrictMode
    $tech = @(Get-StackSignals -Root $Root | ForEach-Object { $_.Tech })
    foreach ($t in $tech) {
        if ($script:CiCredentialStacks.Contains($t)) { $reasons.Add("stack ${t}: $($script:CiCredentialStacks[$t])") }
    }
    if ($tech -contains 'docker') { $caveats.Add('há Docker/compose: pergunte se os testes sobem algum serviço (banco, API); se sim, não ofereça') }
    if ($tech.Count -eq 0) { $caveats.Add('nenhuma stack reconhecida: o runner não ganha setup de runtime') }

    return [pscustomobject]@{
        Offer   = ($reasons.Count -eq 0)
        Reasons = @($reasons)
        Tech    = $tech
        Caveats = @($caveats)
    }
}

function Test-CiNudgeApplicable {
    <#
    .SYNOPSIS
        Versão BARATA do predicado, para o hook curation-nudge (roda a cada SessionStart): sem a
        varredura recursiva de stack/monorepo do Test-CiOfferApplicable. Verdadeiro só com remote no
        github.com, nenhum CI na raiz, teste declarado em `## Verificação` e sem recusa registrada.
        É o gatilho para o agente rodar o passo 6 do /setup, que mede tudo antes de perguntar.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    if (Test-Path -LiteralPath (Join-Path $Root $script:CiDeclinedMarker) -PathType Leaf) { return $false }
    foreach ($f in '.gitlab-ci.yml', 'azure-pipelines.yml') {
        if (Test-Path -LiteralPath (Join-Path $Root $f) -PathType Leaf) { return $false }
    }
    $wf = Join-Path $Root '.github' 'workflows'
    if (Test-Path -LiteralPath $wf -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $wf -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.yml', '.yaml' }).Count -gt 0) { return $false }
    }
    if (-not (Get-ProjectVerification -Root $Root).Declared) { return $false }
    return ((Get-CiRemoteHost -Root $Root) -eq 'github.com')
}

function ConvertTo-CiRunBlock {
    # Comando → linhas de um bloco literal YAML, indentado sob `run: |`. Normaliza CRLF.
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$Indent)
    $lines = ($Command.Trim() -replace "`r`n", "`n") -split "`n"
    return ($lines | ForEach-Object { if ($_.Trim()) { "$Indent$($_.TrimEnd())" } else { '' } }) -join "`n"
}

function New-CiWorkflowYaml {
    <#
    .SYNOPSIS
        Texto do workflow de CI: checkout → setup do runtime → install? → lint? → test.
        Lança se -TestCommand vier vazio (CI sem verificação é decoração).
    .OUTPUTS
        [string] (LF, termina em newline)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TestCommand,
        [string]$LintCommand,
        [string]$InstallCommand,
        [string[]]$Tech = @(),
        [string]$DefaultBranch = 'main',
        [string]$Runner = 'ubuntu-24.04'
    )

    if ([string]::IsNullOrWhiteSpace($TestCommand)) {
        throw 'New-CiWorkflowYaml: -TestCommand é obrigatório — sem ele o CI não verifica nada.'
    }
    if ($Runner -notin $script:CiRunners) {
        throw "New-CiWorkflowYaml: -Runner '$Runner' fora de: $($script:CiRunners -join ', ')."
    }
    if ([string]::IsNullOrWhiteSpace($DefaultBranch)) { $DefaultBranch = 'main' }

    $sb = [System.Text.StringBuilder]::new()
    $add = { param($l) [void]$sb.Append($l).Append("`n") }

    & $add '# Gerado pelo /setup (Native-SDD) a partir dos comandos de verificação do projeto.'
    & $add '# O arquivo é seu: o framework não o regrava.'
    & $add 'name: ci'
    & $add ''
    & $add 'on:'
    & $add '  push:'
    & $add "    branches: [$DefaultBranch]"
    & $add '  pull_request:'
    & $add ''
    & $add 'permissions:'
    & $add '  contents: read'
    & $add ''
    & $add 'concurrency:'
    & $add '  group: ci-${{ github.ref }}'
    & $add '  cancel-in-progress: true'
    & $add ''
    & $add 'jobs:'
    & $add '  verify:'
    & $add "    runs-on: $Runner"
    & $add '    timeout-minutes: 15'
    & $add '    steps:'
    & $add "      - uses: $script:CiCheckoutAction"

    foreach ($setup in (Get-CiSetupActions -Tech $Tech)) {
        & $add "      - uses: $($setup.Uses)"
        & $add '        with:'
        foreach ($k in $setup.With.Keys) { & $add "          ${k}: '$($setup.With[$k])'" }
    }

    $steps = [ordered]@{ install = $InstallCommand; lint = $LintCommand; test = $TestCommand }
    foreach ($name in $steps.Keys) {
        $cmd = $steps[$name]
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        & $add "      - name: $name"
        & $add '        run: |'
        & $add (ConvertTo-CiRunBlock -Command $cmd -Indent '          ')
    }

    return $sb.ToString()
}

function Install-CiWorkflow {
    <#
    .SYNOPSIS
        Grava `.github/workflows/ci.yml` em -Root (UTF-8 sem BOM, LF). Recusa se a pasta
        `.github/workflows/` já tem qualquer .yml/.yaml — o CI que existe é do usuário.
    .OUTPUTS
        [pscustomobject] { Written; Path; Reason }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Content
    )

    $dir  = Join-Path $Root '.github' 'workflows'
    $path = Join-Path $dir 'ci.yml'

    if (Test-Path -LiteralPath $dir -PathType Container) {
        $existing = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.yml', '.yaml' })
        if ($existing.Count -gt 0) {
            return [pscustomobject]@{
                Written = $false
                Path    = $path
                Reason  = "já existe workflow: $(($existing.Name | Sort-Object) -join ', ') — nada foi gravado"
            }
        }
    }

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $text = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Written = $true; Path = $path; Reason = '' }
}
