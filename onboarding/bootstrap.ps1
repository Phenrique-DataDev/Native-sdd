<#
.SYNOPSIS
  Bootstrap remoto do Native-SDD (Windows, PowerShell 5.1+): baixa a ultima release (tag) do
  espelho publico e delega ao onboarding/install.ps1 - sem exigir repo clonado nem git/gh
  instalados. A main so com opt-in explicito (-Ref main).

.DESCRIPTION
  Unico script do onboarding pensado para rodar SEM nada em disco (e baixado sozinho via
  "irm <raw>/bootstrap.ps1 | iex"). Por isso NAO faz dot-source de lib.ps1/bootstrap-lib.ps1 nem
  da cascata tools/ - as funcoes puras (Split-BootstrapArgs, Get-BootstrapTagName,
  Get-BootstrapDownloadUrl, Test-BootstrapNonInteractive) ficam inline neste arquivo, copias
  exatas das de bootstrap-lib.ps1 (duplicacao intencional; ver DESIGN_BOOTSTRAP_REMOTO, Decisao 6
  + nota de auto-suficiencia). O teste de paridade compara as duas copias pelo AST.

  APENAS CARACTERES ASCII NESTE ARQUIVO (excecao deliberada as convencoes pt-BR do resto do repo):
  e o unico script buscado como texto cru via HTTP e avaliado com Invoke-Expression ANTES de
  qualquer arquivo tocar o disco. Confirmado por teste: no Windows PowerShell 5.1,
  Invoke-RestMethod + Invoke-Expression NAO decodifica UTF-8 corretamente (nem com BOM) - um
  travessao/acento vira um caractere "smart quote" (ex.: U+201D), que o parser do PowerShell
  reconhece como delimitador de string e quebra o parse inteiro do script. No plano real,
  raw.githubusercontent.com serve o arquivo como "text/plain; charset=utf-8" e mesmo assim o
  problema se reproduz. Por isso: nada de acento, travessao, aspas curvas ou caixa de desenho
  (bloco Unicode) aqui - nem em comentario, nem em string.

  Fluxo: resolve a ultima release pela API do GitHub (releases/latest, campo tag_name), baixa o
  zip de refs/tags/<tag> via codeload.github.com (HTTPS, anonimo) e imprime a tag. Com -Ref
  <branch> (opt-in explicito, ex.: -Ref main) pula a API e baixa refs/heads/<branch>. Se a API
  falhar (rate limit, rede, espelho sem release), o bootstrap FALHA citando o -Ref main - nunca
  cai na main em silencio. O -Ref e consumido aqui; os demais args vao ao install.ps1. Extrai num
  diretorio temporario e MOVE o conteudo extraido para um cache permanente em
  "~/.claude/.native-sdd-src" (substitui qualquer conteudo anterior) ANTES de delegar ao
  install.ps1 - depois disso sim delega, a partir do cache permanente, e remove o temporario
  (mesmo em falha). Erros propagam: falha de download/extracao/delegacao e fatal, sem modo
  degradado - e o exit code do processo reflete a falha (ver .NOTES).

  POR QUE UM CACHE PERMANENTE (nao so temporario): o install.ps1, ao rodar, grava no $PROFILE do
  usuario um atalho global (New-SddProject / nsp) que aponta de volta para a pasta de onde ele foi
  executado ($env:SDD_WORKFLOW_HOME). Se essa pasta fosse o diretorio temporario (que este script
  apaga ao terminar), o atalho ficaria orfao - apontando para um caminho que deixa de existir
  assim que o bootstrap termina. Achado em uso real (2026-07-07): rodar o bootstrap sem -Check
  deixava o New-SddProject/nsp quebrado logo em seguida. O cache permanente resolve isso: o
  atalho aponta para um caminho que sobrevive.

  Sem flags:
    irm https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.ps1 | iex
  Com flags (embrulha num scriptblock e aplica os parametros do install.ps1):
    iex "& { $(irm https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.ps1) } -Check"
  Branch main em vez da ultima release (opt-in; combina com os demais flags):
    iex "& { $(irm https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.ps1) } -Ref main"

.NOTES
  Release, nao main (BOOTSTRAP_BAIXA_A_MAIN, 2026-10-18): reverte a Decisao 1 do
  DESIGN_BOOTSTRAP_REMOTO ("codeload de main, sem pinar versao"). Com main, qualquer push mudava o
  que o usuario executava. O custo aceito e o que a Decisao 1 evitava: uma chamada anonima a
  api.github.com (limite de 60/h por IP) e um modo de falha a mais - tratado falhando alto, com a
  saida -Ref main na mensagem.

  Sem Set-StrictMode/$ErrorActionPreference globais de proposito: via "irm | iex" o texto roda no
  ESCOPO DA SESSAO do usuario - preferencias globais vazariam para o shell dele. Erros sao
  garantidos por -ErrorAction Stop em cada chamada + try/catch cobrindo o corpo inteiro, que fixa
  o exit code do PROCESSO (nao so de $LASTEXITCODE) - sem isso, um erro de rede/extracao
  terminava o script mas o processo pwsh.exe/powershell.exe ainda saia com codigo 0 (achado de
  revisao adversarial: quebra qualquer automacao/CI que confie no exit code de "irm | iex").
  O exit so roda quando o processo foi aberto para executar e sair (Test-BootstrapNonInteractive,
  no fim do arquivo): colado num terminal interativo, ele fecharia a janela de quem colou, entao
  ali o codigo vai so para o $LASTEXITCODE.

  A delegacao a install.ps1 roda num SUBPROCESSO com -ExecutionPolicy Bypass (em vez de "&"
  in-process) por dois motivos: (1) numa maquina Windows limpa de verdade, a Execution Policy
  padrao de powershell.exe (Windows PowerShell 5.1) e Restricted - chamar um .ps1 do disco
  in-process falharia exatamente na etapa final, sem aviso; o proprio install.ps1 ja documenta
  esse caso (ver seu .NOTES) - aqui aplicamos o mesmo bypass automaticamente. (2) processo
  separado da um $LASTEXITCODE confiavel para propagar a falha do install.ps1 ate o exit code
  deste bootstrap.

  Tradeoff aceito: duas instancias deste bootstrap rodando em paralelo na mesma maquina podem
  colidir no cache permanente (uma apaga/substitui o que a outra acabou de escrever). Risco baixo
  (ninguem roda o mesmo bootstrap 2x ao mesmo tempo por acaso) - sem lock/mutex por YAGNI.
#>

# URL do conteudo - inline de proposito (Decisao 6): owner/repo fixos no espelho publico;
# trocar o destino exige editar este arquivo, nunca um parametro/env solto.
$bootstrapOwner = 'Phenrique-DataDev'
$bootstrapRepo = 'Native-sdd'
$bootstrapApiUrl = "https://api.github.com/repos/$bootstrapOwner/$bootstrapRepo/releases/latest"

# Copia exata de Split-BootstrapArgs em bootstrap-lib.ps1 (o teste de paridade compara as duas).
function Split-BootstrapArgs {
    # Separa o opt-in "-Ref <branch>" (consumido aqui) dos args que seguem para o install.ps1.
    # Sem -Ref, Ref volta vazio = ultima release. "-Ref:main" chega como "-Ref:" + "main" (medido
    # em 2026-10-18 no pwsh 7 e no 5.1), por isso os dois tokens levam o valor seguinte.
    param([object[]]$InputArgs)
    $ref = ''
    $rest = @()
    $list = @($InputArgs)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $token = $list[$i]
        if ($token -is [string] -and ($token -eq '-Ref' -or $token -eq '-Ref:')) {
            if ($i + 1 -ge $list.Count) { throw '-Ref exige um valor (ex.: -Ref main)' }
            $i++
            $ref = [string]$list[$i]
            if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { throw "-Ref com valor invalido: '$ref' (ex.: -Ref main)" }
            continue
        }
        $rest += , $token
    }
    return @{ Ref = $ref; Rest = $rest }
}

# Copia exata de Get-BootstrapTagName em bootstrap-lib.ps1 (o teste de paridade compara as duas).
function Get-BootstrapTagName {
    # tag_name do JSON de /releases/latest da API do GitHub, ou $null se faltar ou for invalido.
    # Regex (nao ConvertFrom-Json) de proposito: e a mesma leitura do bootstrap.sh (sed, sem jq).
    param([string]$Json)
    if ($Json -match '"tag_name"\s*:\s*"([A-Za-z0-9._-]+)"') { return $Matches[1] }
    return $null
}

# Copia exata de Get-BootstrapDownloadUrl em bootstrap-lib.ps1 (o teste de paridade compara as duas).
function Get-BootstrapDownloadUrl {
    # URL do codeload.github.com: refs/tags/<Tag> (o padrao, a ultima release) ou refs/heads/<Branch>
    # (opt-in explicito, -Ref main). Pura: so monta string, nunca lanca, sempre https:// (AT-004).
    # Sem Tag nem Branch devolve $null - nunca cai na main por omissao. Owner/Repo default = espelho
    # publico (Decisao 6: o default nunca aponta ao canonico privado).
    param(
        [string]$Owner = 'Phenrique-DataDev',
        [string]$Repo = 'Native-sdd',
        [string]$Tag = '',
        [string]$Branch = '',
        [string]$Format = 'zip'
    )
    if ($Branch) { return "https://codeload.github.com/$Owner/$Repo/$Format/refs/heads/$Branch" }
    if ($Tag) { return "https://codeload.github.com/$Owner/$Repo/$Format/refs/tags/$Tag" }
    return $null
}

Write-Host ''
Write-Host '=============================================='
Write-Host '   Bootstrap remoto - Native-SDD'
Write-Host '=============================================='

$tmp = Join-Path $env:TEMP ('native-sdd-' + [guid]::NewGuid())
$permanent = Join-Path $env:USERPROFILE '.claude\.native-sdd-src'
$exitCode = 0
try {
    # -Ref e do bootstrap, nao do install.ps1: sai da lista antes do repasse.
    $bootstrapArgs = Split-BootstrapArgs -InputArgs $args
    $installArgs = $bootstrapArgs.Rest
    New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
    $zip = Join-Path $tmp 'native-sdd.zip'
    # -UseBasicParsing: compat 5.1; progress bar desligada so durante a rede (restaurada no finally).
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        if ($bootstrapArgs.Ref) {
            $bootstrapUrl = Get-BootstrapDownloadUrl -Owner $bootstrapOwner -Repo $bootstrapRepo -Branch $bootstrapArgs.Ref
            Write-Host "[INFO   ] ref: branch $($bootstrapArgs.Ref) (opt-in -Ref; conteudo nao versionado por release)"
        }
        else {
            # Padrao: a ultima release com tag. Falha da API e fatal - nunca cai na main em silencio.
            Write-Host "[INFO   ] consultando a ultima release em $bootstrapApiUrl"
            try {
                $releaseJson = (Invoke-WebRequest -Uri $bootstrapApiUrl -UseBasicParsing -ErrorAction Stop).Content
            }
            catch {
                throw "nao foi possivel consultar a ultima release ($($_.Exception.Message)). Para baixar o branch main em vez da release, rode de novo com -Ref main"
            }
            $bootstrapTag = Get-BootstrapTagName -Json $releaseJson
            if (-not $bootstrapTag) {
                throw "a resposta de $bootstrapApiUrl nao trouxe um tag_name valido. Para baixar o branch main em vez da release, rode de novo com -Ref main"
            }
            $bootstrapUrl = Get-BootstrapDownloadUrl -Owner $bootstrapOwner -Repo $bootstrapRepo -Tag $bootstrapTag
            Write-Host "[INFO   ] release: $bootstrapTag"
        }
        Write-Host "[INFO   ] baixando $bootstrapUrl"
        Invoke-WebRequest -Uri $bootstrapUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
    }
    finally { $ProgressPreference = $prevProgress }

    Write-Host "[INFO   ] extraindo em $tmp"
    Expand-Archive -Path $zip -DestinationPath $tmp -ErrorAction Stop

    # Procura install.ps1 em QUALQUER pasta de 1o nivel extraida - nao assume que a 1a pasta
    # (ordem alfabetica do provider do filesystem) e a certa. Cobre tanto "zip sem pasta-raiz"
    # quanto "zip com pasta extra no nivel raiz" (achados de revisao adversarial).
    $topDir = Get-ChildItem -Path $tmp -Directory -ErrorAction Stop |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'onboarding\install.ps1') } |
        Select-Object -First 1
    if (-not $topDir) {
        throw "estrutura inesperada apos extrair o zip - onboarding/install.ps1 nao encontrado sob $tmp"
    }

    # Move (nao copia) o conteudo extraido para o cache permanente - substitui qualquer versao
    # anterior (sempre reflete o ultimo bootstrap rodado: a release resolvida, ou o -Ref pedido).
    # Ver .DESCRIPTION acima para o motivo (shim do $PROFILE).
    Write-Host "[INFO   ] persistindo em $permanent"
    if (Test-Path -LiteralPath $permanent) {
        Remove-Item -Recurse -Force -LiteralPath $permanent -ErrorAction Stop
    }
    New-Item -ItemType Directory -Path (Split-Path $permanent -Parent) -Force -ErrorAction Stop | Out-Null
    Move-Item -LiteralPath $topDir.FullName -Destination $permanent -Force -ErrorAction Stop
    $installScript = Join-Path $permanent 'onboarding\install.ps1'

    Write-Host '[INFO   ] delegando a onboarding/install.ps1 (args repassados)'
    # Subprocesso com -ExecutionPolicy Bypass (nao "&" in-process - ver .NOTES acima).
    $psHost = (Get-Process -Id $PID).Path
    & $psHost -ExecutionPolicy Bypass -NoProfile -File $installScript @installArgs
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Host "[FAIL   ] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# Copia exata de Test-BootstrapNonInteractive em bootstrap-lib.ps1 (inline pelo mesmo motivo da
# URL; o teste de paridade compara as duas).
function Test-BootstrapNonInteractive {
    # $true quando o processo foi aberto para rodar um comando e sair (-Command, -File,
    # -EncodedCommand, -NonInteractive): ai o exit fixa o exit code do processo, que a automacao
    # le. Sem essas flags, ou com -NoExit, a sessao e interativa e o exit fecharia a janela de quem
    # colou o "irm | iex". Aceita os prefixos que o host aceita (-c, -f, -e, -ec, -noni, -noe) e
    # os separadores -, -- e /. O que vem depois de -Command/-File e o comando, nao flag do host.
    param([string[]]$CommandLineArgs)
    $runsAndExits = $false
    foreach ($arg in @($CommandLineArgs | Select-Object -Skip 1)) {
        if ($arg -notmatch '^(--|-|/)([A-Za-z]+)$') { continue }
        $word = $Matches[2].ToLowerInvariant()
        if ($word.Length -ge 3 -and 'noexit'.StartsWith($word, [System.StringComparison]::Ordinal)) { return $false }
        if ($word.Length -ge 4 -and 'noninteractive'.StartsWith($word, [System.StringComparison]::Ordinal)) { $runsAndExits = $true; continue }
        if ($word -eq 'ec' -or
            'command'.StartsWith($word, [System.StringComparison]::Ordinal) -or
            'file'.StartsWith($word, [System.StringComparison]::Ordinal) -or
            'encodedcommand'.StartsWith($word, [System.StringComparison]::Ordinal)) { $runsAndExits = $true; break }
    }
    return $runsAndExits
}

# Processo aberto so para rodar o bootstrap (pwsh -Command, CI): exit, para o exit code do processo
# refletir a falha. Sessao interativa (o "irm | iex" colado no terminal): o exit fecharia a janela
# de quem colou e levaria junto a mensagem de erro, entao so o $LASTEXITCODE recebe o codigo.
$bootstrapExits = Test-BootstrapNonInteractive -CommandLineArgs ([Environment]::GetCommandLineArgs())
# Via "irm | iex" as funcoes caem na sessao do usuario: sai tudo que este script definiu.
foreach ($bootstrapFn in 'Test-BootstrapNonInteractive', 'Split-BootstrapArgs', 'Get-BootstrapTagName', 'Get-BootstrapDownloadUrl') {
    Remove-Item -Path "Function:\$bootstrapFn" -ErrorAction SilentlyContinue
}
if ($bootstrapExits) { exit $exitCode }
$global:LASTEXITCODE = $exitCode
if ($exitCode -ne 0) {
    Write-Host "[FAIL   ] bootstrap terminou com codigo $exitCode - leia o erro acima" -ForegroundColor Red
}
