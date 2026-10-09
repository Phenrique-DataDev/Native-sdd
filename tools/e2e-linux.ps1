<#
.SYNOPSIS
    Runner local do gate e2e Linux: roda onboarding/tests/e2e-linux.sh em containers CRUS das
    distros suportadas, agrega e reporta passou/total — sem depender de abrir PR.

.DESCRIPTION
    O `.github/workflows/onboarding-linux.yml` já roda exatamente isto no CI (matriz de 3 distros).
    Este script é o gêmeo LOCAL: mesma fonte de verdade (o mesmo .sh, o mesmo `docker run`), para
    fechar o loop antes do push em vez de esperar o runner.

    Fonte ÚNICA das distros: a matriz `image:` do workflow é lida do YAML (Get-E2eImages) — não há
    lista duplicada aqui que possa divergir do CI.

    Cada distro devolve { Image; Ok; Passed; Total; Seconds; LogPath }. Os contadores vêm do parse
    das linhas `PASS:`/`FAIL:` que o e2e-linux.sh já emite (Measure-E2eOutput é PURA).

    -Fix delega o DIAGNÓSTICO das distros que falharam a uma sessão headless (`claude -p`), uma por
    distro, com toolset restrito. É opt-in: consome tokens e o agente headless edita arquivos.

    Flags:
      -Image <lista>  sobrescreve as distros (default: a matriz do workflow)
      -Fix            após falha, dispara `claude -p` por distro reprovada (opt-in, muta arquivos)
      -Quiet          só o resumo final (omite o log ao vivo de cada container)

    Uso por função (igual aos outros tools): `. ./tools/e2e-linux.ps1 ; Invoke-E2eLinux`.
    Como script: `pwsh tools/e2e-linux.ps1 [-Image ubuntu:24.04] [-Fix] [-Quiet]` (exit 0/1).
#>

[CmdletBinding()]
param(
    [string[]]$Image,
    [switch]$Fix,
    [switch]$Quiet
)

Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:Workflow = Join-Path $script:RepoRoot '.github/workflows/onboarding-linux.yml'

# Toolset do run headless: leitura + edição + shell. SEM Write (o -Fix corrige scripts que já
# existem, não cria arquivo novo) e sem WebFetch (o diagnóstico é do repo, não da internet).
$script:FixTools = 'Bash,Read,Edit,Grep'

# --- PURA: extrai a matriz `image:` do YAML do workflow (fonte única das distros) --------------
function Get-E2eImagesFromYaml {
    <#
    .OUTPUTS [string[]] — as imagens listadas sob `image:` no bloco `matrix`. Vazio se não achar.
    .NOTES  Parse deliberadamente ingênuo (sem módulo de YAML): a matriz é uma lista plana de
            escalares entre aspas. Se o formato mudar, Get-E2eImages cai no default explícito.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Yaml)

    $images = [System.Collections.Generic.List[string]]::new()
    $inMatrix = $false
    foreach ($line in ($Yaml -split "`r?`n")) {
        if ($line -match '^\s*image:\s*$') { $inMatrix = $true; continue }
        if ($inMatrix) {
            if ($line -match "^\s*-\s*['`"]?([^'`"\s]+)['`"]?\s*$") { $images.Add($Matches[1]); continue }
            if ($line -match '\S') { break }   # primeira linha não-item encerra a lista
        }
    }
    return $images.ToArray()
}

# --- I/O leitura: distros do gate (workflow > fallback) ---------------------------------------
function Get-E2eImages {
    [CmdletBinding()]
    param([string]$WorkflowPath = $script:Workflow)

    if (Test-Path -LiteralPath $WorkflowPath) {
        $found = Get-E2eImagesFromYaml -Yaml (Get-Content -LiteralPath $WorkflowPath -Raw)
        if ($found.Count -gt 0) { return $found }
    }
    # Fallback só se o YAML sumir/mudar de forma: mantém o runner utilizável, mas avisa.
    Write-Warning "matriz não lida de $WorkflowPath — usando fallback embutido"
    return @('ubuntu:24.04', 'fedora:41', 'archlinux:latest')
}

# --- PURA: conta PASS/FAIL da saída do e2e-linux.sh -------------------------------------------
function Measure-E2eOutput {
    <#
    .OUTPUTS [pscustomobject] { Passed; Failed; Total } — parse das linhas `PASS:`/`FAIL:`.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)

    $lines = $Output -split "`r?`n"
    $pass = @($lines | Where-Object { $_ -match '^\s*PASS:' }).Count
    $fail = @($lines | Where-Object { $_ -match '^\s*FAIL:' }).Count
    [pscustomobject]@{ Passed = $pass; Failed = $fail; Total = $pass + $fail }
}

# --- PURA: monta o objeto-resultado de uma distro ---------------------------------------------
function New-E2eResult {
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][bool]$Ok,
        [int]$Passed = 0,
        [int]$Total = 0,
        [double]$Seconds = 0,
        [string]$LogPath = ''
    )
    # Infra: o container não chegou a rodar assert nenhum (daemon fora do ar, imagem inexistente,
    # sem rede). NÃO é o mesmo que "o onboarding regrediu" — e o -Fix não deve gastar uma sessão
    # headless caçando bug nosso num log que só diz que o Docker não subiu.
    [pscustomobject]@{
        Image   = $Image
        Ok      = $Ok
        Infra   = ((-not $Ok) -and $Total -eq 0)
        Passed  = $Passed
        Total   = $Total
        Seconds = [math]::Round($Seconds, 1)
        LogPath = $LogPath
    }
}

# --- PURA: resumo textual do conjunto ---------------------------------------------------------
function Format-E2eSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $lines.Add('=== e2e Linux (Docker) ===')
    foreach ($r in $Results) {
        if ($r.Infra) {
            $lines.Add(('{0,-6} {1,-20} não executou (erro de infra — ver log)' -f 'ERRO', $r.Image))
            continue
        }
        $mark = if ($r.Ok) { 'OK  ' } else { 'FALHOU' }
        $lines.Add(('{0,-6} {1,-20} {2}/{3} asserts  ({4}s)' -f $mark, $r.Image, $r.Passed, $r.Total, $r.Seconds))
    }
    $infra = @($Results | Where-Object { $_.Infra })
    $bad = @($Results | Where-Object { -not $_.Ok -and -not $_.Infra })
    $lines.Add('')
    if ($infra.Count -gt 0) {
        $lines.Add("INFRA: $($infra.Count) distro(s) não executaram -> $(($infra.Image) -join ', ')")
    }
    if ($bad.Count -eq 0 -and $infra.Count -eq 0) {
        $lines.Add("VEREDITO: verde em $($Results.Count) distro(s)")
    }
    elseif ($bad.Count -gt 0) {
        $lines.Add("VEREDITO: $($bad.Count)/$($Results.Count) distro(s) reprovaram -> $(($bad.Image) -join ', ')")
    }
    else {
        $lines.Add('VEREDITO: inconclusivo — nenhuma distro chegou a rodar')
    }
    return ($lines -join [Environment]::NewLine)
}

# --- PURA: prompt do run headless de diagnóstico ----------------------------------------------
function Format-FixPrompt {
    <#
    .OUTPUTS [string] — o prompt entregue ao `claude -p`. Puro p/ ser testável sem invocar a CLI.
    #>
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$LogPath
    )
    @"
O gate e2e do onboarding Linux reprovou na distro $Image.

O log completo do container está em: $LogPath
O script de teste é onboarding/tests/e2e-linux.sh; o instalador é onboarding/linux/install-clis.sh
e o miolo SO-agnóstico é onboarding/windows/apply.ps1.

Tarefa:
1. Leia o log e identifique cada assert `FAIL:`.
2. Diagnostique a causa no código do onboarding (suspeitos recorrentes: encoding de arquivo,
   detecção de arquitetura, e caminho de HOME/home-path divergente entre distros).
3. Corrija no código-fonte do onboarding — NÃO afrouxe nem remova o assert para o teste passar.
4. Se a causa for do ambiente do container e não do nosso código, diga isso e não edite nada.

Reproduza com:
  docker run --rm -v "`$PWD:/repo:ro" $Image bash /repo/onboarding/tests/e2e-linux.sh

Ao final, responda: causa-raiz, arquivos alterados e por que a correção é legítima.
"@
}

# --- I/O: roda uma distro num container cru ---------------------------------------------------
function Invoke-E2eImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$LogDir
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # O container fala UTF-8 (o .sh emite ✅/❌ e acentos). Sem isto o console PT-BR do Windows
    # decodifica em CP-850 e o log chega mojibake — o -Fix então "diagnostica" o nosso encoding a
    # partir de uma corrupção que foi a captura que introduziu.
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    try {
        # Mesma invocação do CI e do cabeçalho do e2e-linux.sh: repo montado READ-ONLY, container cru.
        # 2>&1 junta stderr: o log é o artefato que o -Fix vai ler.
        $out = docker run --rm -v "$($script:RepoRoot):/repo:ro" $Image bash /repo/onboarding/tests/e2e-linux.sh 2>&1 |
            Out-String
        $rc = $LASTEXITCODE
    }
    finally { [Console]::OutputEncoding = $prevEnc }
    $sw.Stop()

    if (-not $script:Quiet) { Write-Host $out }

    $logPath = Join-Path $LogDir ("e2e-{0}.log" -f ($Image -replace '[:/]', '-'))
    Set-Content -LiteralPath $logPath -Value $out -Encoding utf8

    $m = Measure-E2eOutput -Output $out
    New-E2eResult -Image $Image -Ok ($rc -eq 0) -Passed $m.Passed -Total $m.Total `
                  -Seconds $sw.Elapsed.TotalSeconds -LogPath $logPath
}

# --- I/O: sessão headless de diagnóstico p/ uma distro reprovada ------------------------------
function Invoke-E2eFix {
    <#
    .OUTPUTS [string] — o texto final da sessão headless ('' se a CLI não estiver disponível).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Warning '-Fix pedido mas a CLI `claude` não está no PATH — pulando o diagnóstico'
        return ''
    }

    Write-Host "▶ diagnóstico headless: $($Result.Image)"
    $prompt = Format-FixPrompt -Image $Result.Image -LogPath $Result.LogPath
    # --allowedTools restringe a superfície: shell + leitura + edição, nada de rede/escrita nova.
    $out = $prompt | claude -p --allowedTools $script:FixTools 2>&1 | Out-String
    Write-Host $out
    return $out
}

# --- Orquestração -----------------------------------------------------------------------------
function Invoke-E2eLinux {
    <#
    .OUTPUTS [pscustomobject] { Results; AllOk; Summary }
    #>
    [CmdletBinding()]
    param([string[]]$Image, [switch]$Fix, [switch]$Quiet)

    $script:Quiet = [bool]$Quiet

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'docker não encontrado no PATH — este runner precisa de containers para valer como gate'
    }

    $images = if ($Image -and $Image.Count -gt 0) { $Image } else { Get-E2eImages }

    $logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'native-sdd-e2e'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($img in $images) {
        # Sequencial de propósito: os containers competem por rede/disco, e o log intercalado de
        # 3 runs paralelos é ilegível justamente quando algo falha (que é quando se lê o log).
        if (-not $Quiet) { Write-Host "▶ $img" }
        $results.Add((Invoke-E2eImage -Image $img -LogDir $logDir))
    }

    $summary = Format-E2eSummary -Results $results.ToArray()
    Write-Host $summary
    Write-Host "logs: $logDir"

    if ($Fix) {
        # Só falha REAL de assert vira sessão headless — infra (daemon fora do ar) não é bug nosso.
        foreach ($r in ($results | Where-Object { -not $_.Ok -and -not $_.Infra })) {
            Invoke-E2eFix -Result $r | Out-Null
        }
        foreach ($r in ($results | Where-Object { $_.Infra })) {
            Write-Warning "$($r.Image): -Fix pulado (erro de infra, não de assert) — ver $($r.LogPath)"
        }
    }

    [pscustomobject]@{
        Results = $results.ToArray()
        AllOk   = (@($results | Where-Object { -not $_.Ok }).Count -eq 0)
        Summary = $summary
    }
}

# --- Guard: roda só quando NÃO dot-sourced (Pester faz `. e2e-linux.ps1`) ----------------------
# Ao contrário do check.ps1 (advisory), este é GATE: exit 1 se alguma distro reprovar. É o gêmeo
# local de um job de CI que também falha vermelho — o valor dele é justamente reprovar antes do push.
if ($MyInvocation.InvocationName -ne '.') {
    $sum = Invoke-E2eLinux -Image $Image -Fix:$Fix -Quiet:$Quiet
    exit ([int](-not $sum.AllOk))
}
