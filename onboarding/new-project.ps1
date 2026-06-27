<#
.SYNOPSIS
  Cria/equipa um projeto com o scaffold SDD (.claude/ + AGENTS.md + CLAUDE.md). Windows-first (A5).

.DESCRIPTION
  Ponte instalador -> scaffold: espelha templates/project-scaffold para o diretório-alvo,
  reutilizando as funções puras do instalador (Get-BaselineMap, Install-BaselineItem) —
  mesma idempotência, backup e merge de .json. Cria o diretório se não existir e,
  opcionalmente, inicializa um repositório git.

  Seguro em diretório já existente: cada arquivo é comparado por hash; idênticos são
  pulados e os que diferem recebem backup antes de sobrescrever. README.md do template
  não é copiado (descreve o scaffold, não o projeto).

.PARAMETER Path
  Diretório do projeto. Criado se não existir. Default: diretório atual.

.PARAMETER Update
  Atualiza um projeto EXISTENTE: re-espelha o scaffold sobre ele, dirigido por diff.
  Exige o marcador .claude/.scaffold-version (gerado na criação) — recusa diretórios que
  não sejam um projeto scaffolded. Só sobrescreve o que difere (com backup); idênticos são
  pulados. Mostra de qual commit do framework o projeto veio e atualiza o marcador ao fim.

.PARAMETER Git
  Inicializa git (init + commit inicial) se ainda não for um repositório.

.PARAMETER Open
  Abre o VS Code (code) no projeto ao terminar. Ignorado em -Check/-DryRun.

.PARAMETER Check
  Não escreve nada; só relata o que falta.

.PARAMETER DryRun
  Mostra cada ação que faria, sem executar.

.PARAMETER Help
  Mostra esta ajuda.

.EXAMPLE
  .\new-project.ps1 -Path C:\dev\meu-projeto        # cria e equipa
  .\new-project.ps1 -Path . -Git                    # no dir atual + git init
  .\new-project.ps1 -Path C:\dev\x -Check           # só verifica
  .\new-project.ps1 -Path C:\dev\x -DryRun          # simula
  .\new-project.ps1 -Path C:\dev\x -Update          # atualiza projeto existente (upgrade do scaffold)
  .\new-project.ps1 -Path C:\dev\x -Update -DryRun  # mostra o que o update mudaria

.NOTES
  Depois de criado, abra o Claude Code no projeto e rode /setup para preencher o contexto.
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [switch]$Update,
    [switch]$Git,
    [switch]$Open,
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    return
}

# Reusa os helpers puros/testados do instalador.
. (Join-Path $PSScriptRoot 'windows\lib.ps1')

Write-Host ''
Write-Host '╔══════════════════════════════════════════╗'
if ($Update) {
    Write-Host '║   Atualizar projeto · scaffold SDD (A7)   ║'
} else {
    Write-Host '║   Novo projeto · scaffold SDD (A5)        ║'
}
Write-Host '╚══════════════════════════════════════════╝'

$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SourceRoot = Join-Path $RepoRoot 'templates\project-scaffold'

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    Write-Step FAIL "Scaffold não encontrado: $SourceRoot"
    exit 2
}

$action = if ($Update) { 'ATUALIZAÇÃO' } else { 'CRIAÇÃO' }
$mode = if ($Check) { 'CHECK (sem alterações)' } elseif ($DryRun) { 'DRY-RUN (sem alterações)' } else { $action }

Write-Host ''
Write-Step INFO "Modo: $mode | Git: $Git"
Write-Step INFO "PowerShell: $($PSVersionTable.PSVersion) | ExecutionPolicy: $(Get-ExecutionPolicy)"
Write-Step INFO "Origem: $SourceRoot"

# --- Resolve o diretório-alvo (pode ainda não existir) -------------------
$dirExists = Test-Path -LiteralPath $Path -PathType Container
if ($Update -and -not $dirExists) {
    # -Update opera sobre um projeto EXISTENTE; nunca cria diretório.
    Write-Step FAIL "diretório não existe: $Path — use o modo de criação (sem -Update)"
    exit 2
}
if (-not $dirExists) {
    if ($Check)      { Write-Step INFO "diretório alvo faltando: $Path (seria criado)" }
    elseif ($DryRun) { Write-Step DRY  "mkdir $Path" }
    else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Step OK "diretório criado: $Path"
        $dirExists = $true
    }
}
# Caminho absoluto. Em Check/DryRun o dir pode não existir → resolve manualmente
# (sem combinar com o cwd quando o $Path já é absoluto).
$DestRoot = if (Test-Path -LiteralPath $Path) {
    (Resolve-Path -LiteralPath $Path).Path
} elseif ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}
Write-Step INFO "Destino: $DestRoot"

# --- Guarda + relatório do modo -Update (upgrade dirigido por diff) -------
if ($Update) {
    $prev = Read-ScaffoldVersion -Path $DestRoot
    if (-not $prev) {
        Write-Step FAIL "não é um projeto scaffolded: .claude\.scaffold-version ausente em $DestRoot"
        Write-Step INFO "para equipar um projeto do zero, rode sem -Update."
        exit 2
    }
    Write-Step INFO "Projeto gerado do framework commit: $($prev.FrameworkCommit) (em $($prev.GeneratedAt))"

    $plan = @(Get-ScaffoldUpdatePlan -SourceRoot $SourceRoot -DestRoot $DestRoot)
    $nNew = @($plan | Where-Object Status -eq 'new').Count
    $nChg = @($plan | Where-Object Status -eq 'changed').Count
    if ($plan.Count -eq 0) {
        Write-Step OK "scaffold já atualizado — nada a fazer (0 novos, 0 alterados)."
    }
    else {
        Write-Step INFO "Upgrade dirigido por diff: $nNew novo(s), $nChg alterado(s)"
        foreach ($p in $plan) { Write-Step INFO "  [$($p.Status)] $($p.Rel)" }
    }
}
Write-Host ''

$summary = New-InstallSummary
$watch   = [System.Diagnostics.Stopwatch]::StartNew()

# --- Espelha o scaffold (CLAUDE.md -> raiz; .claude/** -> .claude/**) -----
$map = Get-BaselineMap -SourceRoot $SourceRoot -DestRoot $DestRoot
if (-not $map -or @($map).Count -eq 0) {
    Write-Step INFO 'Nenhum artefato no scaffold.'
}
else {
    foreach ($item in $map) {
        Install-BaselineItem -Item $item -Summary $summary -Check:$Check -DryRun:$DryRun
    }
}

# --- Marcador de versão do scaffold (.claude/.scaffold-version) -----------
# Não está no scaffold-fonte (é gerado), então não passa pelo Get-BaselineMap.
$versionFile = Join-Path $DestRoot '.claude\.scaffold-version'
if ($Check)      { Write-Step INFO 'baseline: .claude\.scaffold-version (gerado)' }
elseif ($DryRun) { Write-Step DRY  'escreve: .claude\.scaffold-version' }
else {
    # Commit do framework (se o clone for um repo git); senão 'unknown'.
    $commit = 'unknown'
    if (Test-CommandExists 'git') {
        $rev = git -C $RepoRoot rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $rev) { $commit = $rev.Trim() }
    }
    try {
        $content = Get-ScaffoldVersionContent -RepoRoot $RepoRoot -Commit $commit
        $vDir = Split-Path -Parent $versionFile
        if (-not (Test-Path -LiteralPath $vDir)) { New-Item -ItemType Directory -Path $vDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($versionFile, $content, [System.Text.UTF8Encoding]::new($false))
        Write-Step OK "baseline: .claude\.scaffold-version (commit $commit)"
        $summary.Installed++
    }
    catch {
        Write-Step WARN ".scaffold-version não gravado — $($_.Exception.Message)"
        $summary.Warn++
    }
}

# --- git init opcional ----------------------------------------------------
if ($Git) {
    Write-Host ''
    $isRepo = Test-Path -LiteralPath (Join-Path $DestRoot '.git')
    if ($isRepo) {
        Write-Step SKIP 'git já inicializado'
        $summary.Skipped++
    }
    elseif (-not (Test-CommandExists 'git')) {
        Write-Step WARN 'git ausente — pulei a inicialização do repositório'
        $summary.Warn++
    }
    elseif ($Check)  { Write-Step INFO 'git init (faltando)' }
    elseif ($DryRun) { Write-Step DRY  'git init + commit inicial' }
    else {
        # git é exe nativo: não lança exceção, só seta $LASTEXITCODE.
        git -C $DestRoot init --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Step FAIL "git init (exit $LASTEXITCODE)"
            $summary.Failed++
            $summary.Failures += 'git:init'
        }
        else {
            git -C $DestRoot add -A 2>&1 | Out-Null
            git -C $DestRoot commit --quiet -m 'chore: scaffold SDD inicial' 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Step OK 'git inicializado + commit inicial'
                $summary.Installed++
            }
            else {
                # Causa comum: user.name/email não configurados. Init valeu; commit fica p/ o usuário.
                Write-Step WARN 'git init feito, mas o commit inicial falhou — configure user.name/email e commite manualmente'
                $summary.Warn++
            }
        }
    }
}

# --- Ativa o git pre-commit anti-segredo (core.hooksPath) -----------------
# O scaffold traz .githooks/ (pre-commit + secret-scan.ps1). Apontar core.hooksPath para ela
# habilita a rede deterministica do #1. So faz sentido se o destino for um repo git.
if (Test-Path -LiteralPath (Join-Path $DestRoot '.git')) {
    Write-Host ''
    if (-not (Test-CommandExists 'git')) {
        Write-Step WARN 'git ausente — core.hooksPath nao configurado (pre-commit anti-segredo inativo)'
        $summary.Warn++
    }
    elseif ($Check)  { Write-Step INFO 'git config core.hooksPath .githooks (faltando/atualizar)' }
    elseif ($DryRun) { Write-Step DRY  'git config core.hooksPath .githooks' }
    else {
        $current = (git -C $DestRoot config --local --get core.hooksPath 2>$null)
        if ($LASTEXITCODE -eq 0 -and $current -and $current.Trim() -eq '.githooks') {
            Write-Step SKIP 'core.hooksPath ja aponta para .githooks'
            $summary.Skipped++
        }
        else {
            git -C $DestRoot config --local core.hooksPath .githooks 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Step OK 'pre-commit anti-segredo ativado (core.hooksPath -> .githooks)'
                $summary.Installed++
            }
            else {
                Write-Step WARN "nao consegui setar core.hooksPath (exit $LASTEXITCODE) — rode: git config core.hooksPath .githooks"
                $summary.Warn++
            }
        }
    }
}
elseif (-not $Git) {
    # Sem repo git E sem -Git: core.hooksPath nao pode ser configurado, entao o pre-commit
    # anti-segredo fica INATIVO. Antes isso era pulado EM SILENCIO (validacao E2E eixo 4 / idea #7);
    # agora avisa com a proxima acao concreta. (Com -Git, o bloco de git acima ja reporta o estado.)
    Write-Host ''
    $hooksHint = "sem repositorio git: o pre-commit anti-segredo NAO esta ativo. Apos 'git init', rode: git config core.hooksPath .githooks (ou crie/equipe com -Git)."
    if ($Check)      { Write-Step INFO $hooksHint }
    elseif ($DryRun) { Write-Step DRY  $hooksHint }
    else             { Write-Step WARN $hooksHint; $summary.Warn++ }
}

# --- Abre o VS Code opcional ----------------------------------------------
if ($Open) {
    Write-Host ''
    if ($Check)      { Write-Step INFO "abriria o VS Code em $DestRoot" }
    elseif ($DryRun) { Write-Step DRY  "code $DestRoot" }
    elseif (-not (Test-CommandExists 'code')) {
        Write-Step WARN "'code' (VS Code) não encontrado no PATH — abra o projeto manualmente"
        $summary.Warn++
    }
    else {
        # code é exe nativo: não lança exceção, só seta $LASTEXITCODE.
        code $DestRoot 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Step OK "VS Code aberto em $DestRoot" }
        else {
            Write-Step WARN "falha ao abrir o VS Code (exit $LASTEXITCODE) — abra manualmente"
            $summary.Warn++
        }
    }
}

$watch.Stop()
Write-Summary -Summary $summary -Elapsed $watch.Elapsed

if (-not $Check -and -not $DryRun) {
    Write-Host ''
    if ($Update) {
        Write-Step INFO "Scaffold atualizado em '$DestRoot'. Revise o git diff; arquivos alterados têm backup (.bak-*)."
    }
    else {
        Write-Step INFO "Pronto. Abra o Claude Code em '$DestRoot' e rode /setup para preencher o contexto."
    }
}

if ($summary.Failed -gt 0) { exit 1 } else { exit 0 }
