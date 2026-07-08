<#
.SYNOPSIS
  Bootstrap remoto do Native-SDD (Windows, PowerShell 5.1+): baixa "main" do espelho publico e
  delega ao onboarding/install.ps1 - sem exigir repo clonado nem git/gh instalados.

.DESCRIPTION
  Unico script do onboarding pensado para rodar SEM nada em disco (e baixado sozinho via
  "irm <raw>/bootstrap.ps1 | iex"). Por isso NAO faz dot-source de lib.ps1/bootstrap-lib.ps1 nem
  da cascata tools/ - a logica de montar a URL fica inline neste arquivo (duplicacao intencional
  de Get-BootstrapDownloadUrl; ver DESIGN_BOOTSTRAP_REMOTO, Decisao 6 + nota de auto-suficiencia).

  APENAS CARACTERES ASCII NESTE ARQUIVO (excecao deliberada as convencoes pt-BR do resto do repo):
  e o unico script buscado como texto cru via HTTP e avaliado com Invoke-Expression ANTES de
  qualquer arquivo tocar o disco. Confirmado por teste: no Windows PowerShell 5.1,
  Invoke-RestMethod + Invoke-Expression NAO decodifica UTF-8 corretamente (nem com BOM) - um
  travessao/acento vira um caractere "smart quote" (ex.: U+201D), que o parser do PowerShell
  reconhece como delimitador de string e quebra o parse inteiro do script. No plano real,
  raw.githubusercontent.com serve o arquivo como "text/plain; charset=utf-8" e mesmo assim o
  problema se reproduz. Por isso: nada de acento, travessao, aspas curvas ou caixa de desenho
  (bloco Unicode) aqui - nem em comentario, nem em string.

  Fluxo: baixa o zip de refs/heads/main via codeload.github.com (HTTPS, anonimo), extrai num
  diretorio temporario, delega ao install.ps1 extraido (inalterado - idempotencia versionada,
  backups e opcionais sao dele) e remove o temporario ao final (mesmo em falha). Erros propagam:
  falha de download/extracao/delegacao e fatal, sem modo degradado - e o exit code do processo
  reflete a falha (ver .NOTES).

  Sem flags:
    irm https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.ps1 | iex
  Com flags (embrulha num scriptblock e aplica os parametros do install.ps1):
    iex "& { $(irm https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.ps1) } -Check"

.NOTES
  Sem Set-StrictMode/$ErrorActionPreference globais de proposito: via "irm | iex" o texto roda no
  ESCOPO DA SESSAO do usuario - preferencias globais vazariam para o shell dele. Erros sao
  garantidos por -ErrorAction Stop em cada chamada + try/catch cobrindo o corpo inteiro, que fixa
  o exit code do PROCESSO (nao so de $LASTEXITCODE) - sem isso, um erro de rede/extracao
  terminava o script mas o processo pwsh.exe/powershell.exe ainda saia com codigo 0 (achado de
  revisao adversarial: quebra qualquer automacao/CI que confie no exit code de "irm | iex").

  A delegacao a install.ps1 roda num SUBPROCESSO com -ExecutionPolicy Bypass (em vez de "&"
  in-process) por dois motivos: (1) numa maquina Windows limpa de verdade, a Execution Policy
  padrao de powershell.exe (Windows PowerShell 5.1) e Restricted - chamar um .ps1 do disco
  in-process falharia exatamente na etapa final, sem aviso; o proprio install.ps1 ja documenta
  esse caso (ver seu .NOTES) - aqui aplicamos o mesmo bypass automaticamente. (2) processo
  separado da um $LASTEXITCODE confiavel para propagar a falha do install.ps1 ate o exit code
  deste bootstrap.
#>

# URL do conteudo - inline de proposito (Decisao 6): owner/repo fixos no espelho publico;
# trocar o destino exige editar este arquivo, nunca um parametro/env solto.
$bootstrapOwner = 'Phenrique-DataDev'
$bootstrapRepo = 'Native-sdd'
$bootstrapRef = 'main'
$bootstrapUrl = "https://codeload.github.com/$bootstrapOwner/$bootstrapRepo/zip/refs/heads/$bootstrapRef"

Write-Host ''
Write-Host '=============================================='
Write-Host '   Bootstrap remoto - Native-SDD'
Write-Host '=============================================='

$tmp = Join-Path $env:TEMP ('native-sdd-' + [guid]::NewGuid())
$exitCode = 0
try {
    New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
    $zip = Join-Path $tmp 'native-sdd.zip'
    Write-Host "[INFO   ] baixando $bootstrapUrl"
    # -UseBasicParsing: compat 5.1; progress bar desligada so durante o download (restaurada no finally).
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $bootstrapUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
    }
    finally { $ProgressPreference = $prevProgress }

    Write-Host "[INFO   ] extraindo em $tmp"
    Expand-Archive -Path $zip -DestinationPath $tmp -ErrorAction Stop

    # Procura install.ps1 em QUALQUER pasta de 1o nivel extraida - nao assume que a 1a pasta
    # (ordem alfabetica do provider do filesystem) e a certa. Cobre tanto "zip sem pasta-raiz"
    # quanto "zip com pasta extra no nivel raiz" (achados de revisao adversarial).
    $installScript = Get-ChildItem -Path $tmp -Directory -ErrorAction Stop |
        ForEach-Object { Join-Path $_.FullName 'onboarding\install.ps1' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $installScript) {
        throw "estrutura inesperada apos extrair o zip - onboarding/install.ps1 nao encontrado sob $tmp"
    }

    Write-Host '[INFO   ] delegando a onboarding/install.ps1 (args repassados)'
    # Subprocesso com -ExecutionPolicy Bypass (nao "&" in-process - ver .NOTES acima).
    $psHost = (Get-Process -Id $PID).Path
    & $psHost -ExecutionPolicy Bypass -NoProfile -File $installScript @args
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Host "[FAIL   ] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

exit $exitCode
