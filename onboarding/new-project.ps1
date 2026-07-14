<#
.SYNOPSIS
  Cria/equipa um projeto com o scaffold SDD (.claude/ + AGENTS.md + CLAUDE.md). Roda em pwsh,
  multiplataforma (A5).

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
  Atualiza um projeto EXISTENTE, PRESERVANDO o que você customizou. Exige o marcador
  .claude/.scaffold-version — recusa diretórios que não sejam um projeto scaffolded.

  Cada arquivo é classificado contra o .claude/.scaffold-manifest (o hash do que foi ENTREGUE
  na criação), o que torna o upgrade auto-contido — não precisa do template antigo, nem de git:
    intacto      você nunca mexeu          -> atualizado (fast-forward)
    novo         não existe no projeto     -> criado
    em-dia       já é o que o template quer-> pulado
    merge        .json                     -> merge (preserva sua config)
    conflito     VOCÊ editou e o template também mudou -> PRESERVADO e listado (use -Force p/ sobrescrever)
    desconhecido projeto sem manifest (anterior à v0.8.18) -> PRESERVADO (fail-safe: não dá p/ saber)

  Arquivos SEUS, fora do template, nunca são tocados. O marcador e o manifest são reescritos ao fim.

.PARAMETER Force
  Só com -Update: sobrescreve TAMBÉM os arquivos que você customizou (classe 'conflito'/'desconhecido'),
  sempre com backup .bak-*. Sem esta flag, arquivos customizados são PRESERVADOS e apenas listados.

.PARAMETER AllowNested
  Aceita, sem perguntar, criar o projeto numa SUBPASTA de mesmo nome (ex.: estar em 'meu-projeto\'
  e rodar -Path meu-projeto -> 'meu-projeto\meu-projeto'). Sem esta flag, esse caso pede confirmação
  (e, em modo não-interativo, é recusado) — evita o projeto aninhado criado por engano.

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
  .\new-project.ps1 -Path C:\dev\x -Update          # atualiza, preservando o que você customizou
  .\new-project.ps1 -Path C:\dev\x -Update -DryRun  # mostra o que o update mudaria
  .\new-project.ps1 -Path C:\dev\x -Update -Force   # sobrescreve TAMBÉM o customizado (com backup)

.NOTES
  Depois de criado, abra o Claude Code no projeto e rode /setup para preencher o contexto.
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [switch]$Update,
    [switch]$Force,
    [switch]$AllowNested,
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
$FrameworkVersion = Get-FrameworkVersion -RepoRoot $RepoRoot

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

# --- Guarda de aninhamento por nome duplicado -----------------------------
# `nsp meu-projeto` rodado de DENTRO de 'meu-projeto\' cria 'meu-projeto\meu-projeto' (o -Path é
# relativo ao cwd). Achado em uso real (2026-07-12): comando copiado/colado sem atenção → a raiz do
# projeto não é a que o usuário pensa, e o Claude Code carrega dois CLAUDE.md/AGENTS.md. Antes isso
# passava em silêncio, enterrado em 101 linhas de [OK] baseline. Agora: confirma (interativo) ou
# recusa (não-interativo, salvo -AllowNested) — nunca cria a estrutura errada sem o usuário saber.
$cwd = (Get-Location).Path
if (-not $Update -and
    -not (Test-Path -LiteralPath $Path -PathType Container) -and
    (Test-SameNameNesting -Path $Path -CurrentDir $cwd)) {

    $wouldBe = Join-Path $cwd $Path
    Write-Host ''
    Write-Step WARN "Você está em '$cwd' e pediu -Path '$Path'."
    Write-Step WARN "Isso criaria '$wouldBe' — projeto ANINHADO (a raiz não seria a pasta atual)."

    # Terminal de verdade = pode perguntar. SDD_ASSUME_INTERACTIVE=1 é um seam de TESTE: força este
    # ramo com stdin vindo de pipe, para o menu (e o Read-Host) serem exercíveis de forma automatizada
    # — sem ele, todo teste cai no ramo não-interativo e o menu nunca rodaria.
    $interactive = ($env:SDD_ASSUME_INTERACTIVE -eq '1') -or
                   ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
    if ($Check -or $DryRun) {
        Write-Step INFO "Em execução real, isto pediria confirmação (ou use -Path . para equipar a pasta atual)."
    }
    elseif ($AllowNested) {
        Write-Step INFO '-AllowNested: seguindo com a subpasta, como pedido.'
    }
    elseif (-not $interactive) {
        Write-Step FAIL 'Ambíguo em modo não-interativo. Use -Path . (equipar a pasta atual) ou -AllowNested (criar a subpasta mesmo).'
        exit 2
    }
    else {
        Write-Host ''
        Write-Host "  [1] Equipar a pasta ATUAL   -> $cwd   (provavelmente o que você quer)"
        Write-Host "  [2] Criar a subpasta mesmo  -> $wouldBe"
        Write-Host '  [3] Cancelar'
        # I/O numa linha; a decisão (e o default fail-closed) vive em Resolve-NestingChoice (testada).
        switch (Resolve-NestingChoice -Choice (Read-Host 'Escolha [1/2/3]')) {
            'use-current' { $Path = '.'; Write-Step OK "equipando a pasta atual: $cwd" }
            'nested'      { Write-Step OK "criando a subpasta: $wouldBe" }
            default       { Write-Step INFO 'cancelado — nada foi escrito.'; exit 0 }
        }
    }
}

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

# Scaffold dentro de scaffold: legítimo em casos raros (monorepo), mas quase sempre é engano — e o
# Claude Code carrega os DOIS contratos (o do pai e o do filho) na mesma sessão. Avisa, nunca barra.
if (-not $Update) {
    $ancestor = Find-ScaffoldedAncestor -Dir $DestRoot
    if ($ancestor) {
        Write-Step WARN "'$DestRoot' fica DENTRO de um projeto scaffolded ('$ancestor')."
        Write-Step WARN 'O agente pode carregar os dois AGENTS.md/CLAUDE.md na mesma sessão. Intencional? (monorepo) Senão, cancele e escolha outro destino.'
    }
}

# --- Guarda + relatório do modo -Update (upgrade dirigido por diff) -------
if ($Update) {
    $prev = Read-ScaffoldVersion -Path $DestRoot
    if (-not $prev) {
        # ADOÇÃO (achado no IAIMG, 2026-07-13): projeto scaffolded que nasceu ANTES do marcador (A6).
        # Recusá-lo deixava o upgrade inútil justamente nos projetos ANTIGOS — os que mais precisam —
        # e a mensagem antiga ("rode sem -Update") empurrava o usuário para o modo CRIAÇÃO, que
        # sobrescreve tudo que difere SEM classificar. Adotar é seguro por construção: sem manifest,
        # todo arquivo que difere cai em 'desconhecido' -> preservado.
        if (Test-ScaffoldedProject -Path $DestRoot) {
            Write-Step WARN "sem .claude\.scaffold-version, mas isto É um projeto scaffolded (tem .claude\rules\)."
            Write-Step OK   'ADOTANDO: nada que você tenha editado será sobrescrito; o marcador e o manifest são gravados ao fim.'
        }
        else {
            Write-Step FAIL "não é um projeto scaffolded: nem .claude\.scaffold-version nem .claude\rules\ em $DestRoot"
            Write-Step INFO 'para equipar um projeto do zero, rode sem -Update.'
            exit 2
        }
    }
    else {
        Write-Step INFO "Projeto gerado do framework commit: $($prev.FrameworkCommit) (em $($prev.GeneratedAt))"
        # 'unknown' = projeto criado antes da v0.8.17 (o campo não existia) — é "não sei", não "igual".
        $fromLabel = if ($prev.TemplateVersion -eq 'unknown') { 'desconhecida (projeto anterior à v0.8.17)' } else { "v$($prev.TemplateVersion)" }
        Write-Step INFO "Versão do template: $fromLabel -> v$FrameworkVersion (framework atual)"
    }

    # Classificação por arquivo (manifest $null = projeto legado, sem baseline -> tudo vira 'hold').
    $manifest = Read-ScaffoldManifest -Path $DestRoot
    if (-not $manifest) {
        Write-Step WARN 'sem .claude\.scaffold-manifest (projeto anterior à v0.8.18): não dá para saber o que VOCÊ editou.'
        Write-Step WARN 'Nada que difira será sobrescrito. O manifest é gravado ao fim — o próximo -Update já classifica.'
    }
    $upgrade = @(Get-ScaffoldUpgradePlan -SourceRoot $SourceRoot -DestRoot $DestRoot -Manifest $manifest)

    # Classes que TÊM fonte no template (dá para copiar). As demais ('removido'/'orfao'/'local'/
    # 'ausente') existem só no destino — mandá-las para o UpgradeApply pediria copiar de um Src $null.
    $comFonte = @('novo', 'intacto', 'em-dia', 'conflito', 'desconhecido')

    $script:UpgradeApply = @{}   # Rel -> $true para os que PODEM ser escritos
    foreach ($p in $upgrade | Where-Object { $_.Class -in $comFonte -and ($_.Action -eq 'apply' -or $Force) }) {
        $script:UpgradeApply[$p.Rel] = $true
    }

    # Rel -> Class, para a mensagem do SKIP dizer a VERDADE sobre cada arquivo. Sem isto, o pulo era
    # anunciado como "preservado (customizado)" para TUDO que não fosse 'apply' — inclusive 'em-dia'
    # (byte-idêntico ao template: o usuário nunca tocou) e 'gerado' (o /sync-context manda neles).
    # Um projeto perfeitamente em dia imprimia dezenas de linhas acusando o usuário de ter
    # customizado arquivos que ele nunca abriu (medido no IAIMG: 84 'em-dia' + 4 'gerado' rotulados
    # como customizados, contra 6 conflitos reais). A saída assusta e mente sobre o estado.
    $script:UpgradeClass = @{}
    foreach ($p in $upgrade) { $script:UpgradeClass[$p.Rel] = $p.Class }

    # RETIRADAS (v0.8.23): o template deixou de entregar o arquivo. 'removido' = nós entregamos e o
    # usuário não mexeu -> sai. 'orfao' = ele editou -> só sai com -Force (e com backup), senão fica.
    $script:UpgradeDelete = @($upgrade |
        Where-Object { $_.Action -eq 'delete' -or ($_.Class -eq 'orfao' -and $Force) } |
        ForEach-Object { $_.Rel })

    # SÓ os 'hold' ficam fora do manifest — são os que ele NÃO pode fotografar (senão a customização
    # vira baseline e o próximo -Update a sobrescreve achando que é 'intacto'). Com -Force nada é
    # preservado -> lista vazia.
    #
    # 'em-dia' NÃO entra aqui, e a distinção importa: o disco já é EXATAMENTE o que o template
    # entrega, então "o que entregamos" É o hash do disco — registrá-lo é a verdade. Mantendo o hash
    # ANTIGO (bug até v0.8.21), um arquivo que alguém deixou em dia À MÃO viraria FALSO 'conflito' no
    # próximo update do template (baseline velho ≠ disco ≠ template novo). Achado ao corrigir o
    # curation-nudge.ps1 do IAIMG à mão — o merge cirúrgico é justamente o caso que produz isso.
    #
    # ForEach-Object e não @(...).Rel: sob Set-StrictMode -Latest, acessar .Rel numa coleção VAZIA lança.
    $script:ManifestSkip = @($upgrade | Where-Object { $_.Action -eq 'hold' -and -not $Force } | ForEach-Object { $_.Rel })
    $script:ManifestPrev = $manifest

    $hold  = @($upgrade | Where-Object Action -eq 'hold')
    $write = @($upgrade | Where-Object { $_.Action -eq 'apply' -and $_.Class -ne 'merge' })
    $del   = @($upgrade | Where-Object Action -eq 'delete')
    $ger   = @($upgrade | Where-Object Class -eq 'gerado')

    Write-Step INFO "Plano: $(@($write).Count) a atualizar, $(@($del).Count) a remover, $(@($hold).Count) preservado(s), $(@($upgrade | Where-Object Class -eq 'em-dia').Count) em dia, $(@($ger).Count) gerado(s)"
    foreach ($p in ($upgrade | Where-Object Class -in @('novo', 'intacto'))) {
        Write-Step INFO "  [$($p.Class)] $($p.Rel)"
    }
    foreach ($p in $del) {
        Write-Step INFO "  [removido do template] $($p.Rel)"
    }
    if ($ger.Count -gt 0) {
        # NÃO entram na lista de "preservados" abaixo: aquela pede uma decisão sua. Estes não pedem
        # nada — o /sync-context do projeto os regenera, e é assim que devem ser.
        Write-Step SKIP "Gerados pelo projeto (o /sync-context cuida deles — nada a decidir):"
        foreach ($p in $ger) { Write-Step SKIP "  [gerado] $($p.Rel)" }
    }
    if ($hold.Count -gt 0) {
        Write-Host ''
        Write-Step WARN "NÃO serão tocados — você editou estes arquivos (o template também mudou):"
        foreach ($p in $hold) { Write-Step WARN "  [$($p.Class)] $($p.Rel)" }
        if ($Force) {
            Write-Step WARN '-Force: serão SOBRESCRITOS mesmo assim (com backup .bak-*).'
        }
        else {
            Write-Step INFO 'Compare à mão e reaplique o que quiser; ou use -Force para sobrescrever (com backup).'
        }
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
        # No -Update, só escreve o que a classificação liberou ('apply'). O que o usuário customizou
        # ('hold') é PRESERVADO — antes da v0.8.18 era sobrescrito com backup, o que na prática
        # significava "seu trabalho vira um .bak-* que ninguém vai reabrir".
        if ($Update -and -not $script:UpgradeApply.ContainsKey($item.Rel)) {
            # A mensagem sai da CLASSE, nunca de "não é apply" — ver $script:UpgradeClass acima.
            $classe = $script:UpgradeClass[$item.Rel]
            $motivo = switch ($classe) {
                'em-dia'       { 'já em dia (idêntico ao template)' }
                'gerado'       { 'gerado pelo projeto (o /sync-context cuida)' }
                'local'        { 'só existe no seu projeto' }
                'conflito'     { 'PRESERVADO — você editou e o template mudou' }
                'desconhecido' { 'PRESERVADO — sem baseline para comparar' }
                'orfao'        { 'PRESERVADO — saiu do template, mas você editou' }
                default        { "preservado ($classe)" }
            }
            Write-Step SKIP "$motivo`: $($item.Rel)"
            $summary.Skipped++
            continue
        }
        Install-BaselineItem -Item $item -Summary $summary -Check:$Check -DryRun:$DryRun
    }
}

# --- Retiradas: o template deixou de entregar o arquivo (v0.8.23) ---------
# Sem isto o upgrade só sabia ADICIONAR, e uma rule que o framework removeu ficava no projeto para
# sempre — o corte de always-on nunca chegava a quem já tinha projeto. Só apagamos o que ESTÁ NO
# BASELINE (nós entregamos) e o usuário não editou; o resto é dele (ver Get-ScaffoldFileClass).
if ($Update -and $script:UpgradeDelete.Count -gt 0) {
    foreach ($rel in $script:UpgradeDelete) {
        $target = Join-Path $DestRoot $rel
        if (-not (Test-Path -LiteralPath $target)) { continue }
        if ($Check)      { Write-Step INFO "removeria (saiu do template): $rel"; continue }
        if ($DryRun)     { Write-Step DRY  "remove (saiu do template): $rel"; continue }
        try {
            Backup-File -Path $target      # nunca apaga sem deixar o .bak-*
            Remove-Item -LiteralPath $target -Force
            Write-Step OK "removido (saiu do template): $rel"
            $summary.Installed++
        }
        catch {
            Write-Step WARN "falhou ao remover ${rel}: $($_.Exception.Message)"
        }
    }
}

# --- Manifest do scaffold (.claude/.scaffold-manifest) --------------------
# Gravado DEPOIS de espelhar: registra o hash de cada arquivo COMO FICOU NO DESTINO — o baseline que
# o próximo -Update usa para saber o que o usuário customizou. Sem isto, o upgrade é chute.
if ($Check)      { Write-Step INFO 'baseline: .claude\.scaffold-manifest (gerado)' }
elseif ($DryRun) { Write-Step DRY  'escreve: .claude\.scaffold-manifest' }
else {
    try {
        $manifestFile = Join-Path $DestRoot '.claude\.scaffold-manifest'
        # Na CRIAÇÃO nada é preservado (escrevemos tudo) -> Skip vazio, sem baseline anterior.
        $mSkip = if ($Update) { $script:ManifestSkip } else { @() }
        $mPrev = if ($Update) { $script:ManifestPrev } else { $null }
        $mContent = Get-ScaffoldManifestContent -Map $map -Previous $mPrev -Skip $mSkip
        $mDir = Split-Path -Parent $manifestFile
        if (-not (Test-Path -LiteralPath $mDir)) { New-Item -ItemType Directory -Path $mDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($manifestFile, $mContent, [System.Text.UTF8Encoding]::new($false))
        Write-Step OK "baseline: .claude\.scaffold-manifest ($(@($map).Count) arquivos)"
        $summary.Installed++
    }
    catch {
        # NÃO é um warning qualquer: sem manifest não há baseline, e sem baseline o próximo -Update
        # não consegue distinguir "o template evoluiu" de "o usuário editou" — tudo cai em
        # 'desconhecido' e o upgrade vira chute. Isto já degradou MUDO uma vez (v0.8.25: um .gitkeep
        # vazio quebrava o hash e o resumo ainda dizia "Falhou: 0"), então aqui grita.
        Write-Step FAIL ".scaffold-manifest NÃO gravado — $($_.Exception.Message)"
        Write-Step FAIL 'Sem baseline, o próximo -Update não saberá o que você customizou. Isto precisa ser corrigido.'
        $summary.Failed++
    }
}

# --- Marcador de versão do scaffold (.claude/.scaffold-version) -----------
# Não está no scaffold-fonte (é gerado), então não passa pelo Get-BaselineMap.
$versionFile = Join-Path $DestRoot '.claude\.scaffold-version'
if ($Check)      { Write-Step INFO 'baseline: .claude\.scaffold-version (gerado)' }
elseif ($DryRun) { Write-Step DRY  "escreve: .claude\.scaffold-version (template_version: $FrameworkVersion)" }
else {
    # Commit do framework (se o clone for um repo git); senão 'unknown'.
    $commit = 'unknown'
    if (Test-CommandExists 'git') {
        $rev = git -C $RepoRoot rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $rev) { $commit = $rev.Trim() }
    }
    try {
        $content = Get-ScaffoldVersionContent -RepoRoot $RepoRoot -Commit $commit -Version $FrameworkVersion
        $vDir = Split-Path -Parent $versionFile
        if (-not (Test-Path -LiteralPath $vDir)) { New-Item -ItemType Directory -Path $vDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($versionFile, $content, [System.Text.UTF8Encoding]::new($false))
        Write-Step OK "baseline: .claude\.scaffold-version (v$FrameworkVersion, commit $commit)"
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
