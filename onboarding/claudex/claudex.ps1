<#
.SYNOPSIS
  claudex — lança o `claude` com um perfil de modelo/provider Anthropic-compatível, escopando
  as env vars só no processo filho. Camada FINA: PowerShell puro, sem proxy, sem OAuth de
  terceiro (fase futura gated), zero dependência externa.

.DESCRIPTION
  O Claude Code lê ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_DEFAULT_{OPUS,SONNET,
  HAIKU}_MODEL no START do processo. Este wrapper resolve o perfil (~/.claude/claudex/
  profiles.psd1), resolve o segredo pela SecretRef (cred:/env:/file:, nunca versionado), seta as
  env vars APENAS no processo filho e lança o `claude` — restaurando o env do shell ao final.

  Registrado como função `claudex` no $PROFILE pelo instalador (-WithClaudex), no mesmo molde de
  New-SddProject/nsp. Uso:
    claudex [-Profile <nome>] [-List] [-Check] [<args do claude...>]

.PARAMETER Profile
  Nome do perfil no profiles.psd1. Default: 'claude' (passthrough puro, nenhum env setado).

.PARAMETER List
  Lista os perfis disponíveis e o backend de cada (não lança o claude).

.PARAMETER Check
  Doctor: para cada perfil, diz se o segredo resolve (sem imprimir o valor) e se o backend é
  suportado nesta fase (não lança o claude).

.PARAMETER ClaudeArgs
  Tudo que não for flag NOSSA (-Profile, -List, -Check, -ClaudeCommand, nome exato) é repassado
  ao `claude` verbatim. `--` é aceito como separador explícito, mas não é obrigatório.

.EXAMPLE
  claudex -List
  claudex -Check
  claudex                                   # perfil 'claude' (passthrough), interativo
  claudex -p "resuma isto"                  # -p vai pro claude (--print), NÃO vira perfil
  claudex -c                                # -c vai pro claude (--continue)
  claudex -Profile local -p "oi"            # perfil nosso + flag do claude, sem ambiguidade
  claudex -- --help                         # `--` explícito também funciona
#>

# SEM param() e SEM [CmdletBinding()] DE PROPÓSITO — ver a nota grande em Split-ClaudexArgs
# (claudex-lib.ps1). Resumo: o prefix matching do binder do PowerShell sequestrava as flags
# mais comuns do Claude Code (`-p` casava com -Profile; `-c` ficava ambíguo entre
# -Check/-ClaudeCommand/-ClaudeArgs) antes de elas chegarem ao `claude`. Declarar qualquer
# parâmetro aqui reintroduz o problema — inclusive [CmdletBinding()], que registra os common
# parameters (-Verbose, -Debug...) e faz `-v`/`-d` voltarem a colidir. O script recebe tudo
# verbatim em $args e nós mesmos separamos, com regra de igualdade exata.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'claudex-lib.ps1')

$parsed = Split-ClaudexArgs -Argv $args
if ($parsed.Error) {
    Write-Host "[claudex] $($parsed.Error)" -ForegroundColor Red
    exit 2
}
$ProfileName   = $parsed.ProfileName
$List          = $parsed.List
$Check         = $parsed.Check
$Login         = $parsed.Login
$ClaudeCommand = $parsed.ClaudeCommand
$ClaudeArgs    = @($parsed.ClaudeArgs)

$profilesPath = Join-Path (Get-ClaudexHome) 'profiles.psd1'
$secretsDir   = Join-Path (Get-ClaudexHome) 'secrets'

try {
    $profiles = Import-ClaudexProfiles -Path $profilesPath
}
catch {
    Write-Host "[claudex] $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

# Schema inválido é fatal p/ List/Check/launch: melhor abortar claro que agir sobre config quebrada.
$schemaErrors = @(Get-ClaudexSchemaError -Profiles $profiles)
if ($schemaErrors.Count -gt 0) {
    Write-Host '[claudex] profiles.psd1 inválido:' -ForegroundColor Red
    foreach ($e in $schemaErrors) { Write-Host "  - $e" -ForegroundColor Red }
    exit 2
}

if ($List) {
    Write-Host (Format-ClaudexList -Profiles $profiles)
    exit 0
}

# --- -Login <provider>: OAuth de assinatura pelo binário do cliproxy ------------------------
# Ato do USUÁRIO, não nosso: abre o browser, ele autentica na conta dele, e a credencial fica no
# auth-dir do motor. O claudex só resolve a flag certa e o auth-dir — nunca vê a credencial.
if (-not [string]::IsNullOrWhiteSpace($Login)) {
    $flag = Get-ClaudexLoginFlag -Provider $Login
    if (-not $flag) {
        Write-Host "[claudex] provider '$Login' não suportado no -Login. Válidos: $((Get-ClaudexLoginProviderList) -join ', ')" -ForegroundColor Red
        exit 2
    }
    # Normaliza p/ um CAMINHO: Get-Command devolve .Source, Get-ChildItem devolve .FullName.
    $binPath = $null
    $cmd = Get-Command 'cli-proxy-api' -ErrorAction SilentlyContinue
    if ($cmd) { $binPath = [string]$cmd.Source }
    if (-not $binPath) {
        # Instalado pelo onboarding fora do PATH? Procura no caminho versionado antes de desistir.
        $toolsDir = Join-Path (Join-Path (Split-Path -Parent (Get-ClaudexHome)) 'tools') 'cliproxy'
        $cand = if (Test-Path -LiteralPath $toolsDir) {
            Get-ChildItem -LiteralPath $toolsDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('cli-proxy-api', 'cli-proxy-api.exe') } |
                Sort-Object FullName -Descending | Select-Object -First 1
        } else { $null }
        if (-not $cand) {
            Write-Host '[claudex] motor cliproxy não encontrado. Instale com: .\onboarding\install.ps1 -WithCliProxy' -ForegroundColor Red
            exit 2
        }
        $binPath = [string]$cand.FullName
    }
    $authDir = Join-Path (Get-ClaudexHome) 'auth/cliproxy'
    if (-not (Test-Path -LiteralPath $authDir -PathType Container)) {
        New-Item -ItemType Directory -Path $authDir -Force | Out-Null
    }
    # Config mínima só p/ o login saber onde gravar a credencial. Gerada com as MESMAS travas de
    # cloaking do caminho de lançamento — não existe porta lateral por onde o cloaking volte.
    $loginCfgDir = Join-Path ([System.IO.Path]::GetTempPath()) ("claudex-login-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $loginCfgDir -Force | Out-Null
    $loginCfg = Join-Path $loginCfgDir 'config.yaml'
    try {
        Set-Content -LiteralPath $loginCfg -Encoding utf8 -Value (
            New-ClaudexCliProxyConfig -ProfileObj @{ Name = 'login'; Engine = 'cliproxy' } `
                -LocalKey (New-ClaudexLocalKey) -Port 8317 -UpstreamKey '' -AuthDir $authDir
        )
        Write-Host "[claudex] login OAuth ($Login) via $flag — abrindo o browser; autentique na SUA conta."
        Write-Host "[claudex] a credencial fica em $authDir — o claudex nunca a lê, só aponta o motor p/ lá."
        # Statement solto (sem atribuição): capturar o retorno redireciona o stdout do processo
        # filho e quebra o fluxo interativo do OAuth — mesma armadilha do bug de 2026-07-19.
        & $binPath $flag '-config' $loginCfg
    }
    finally {
        Remove-Item -LiteralPath $loginCfgDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit $LASTEXITCODE
}

if ($Check) {
    Write-Host 'claudex -Check (doctor):'
    foreach ($p in $profiles) {
        $backend = if ($p.ContainsKey('Backend')) { [string]$p['Backend'] } else { '' }
        $resolves = $false
        if ($backend -in @('direct', 'proxy') -and $p.ContainsKey('SecretRef')) {
            $resolves = Test-ClaudexSecretResolves -SecretRef ([string]$p['SecretRef']) -SecretsDir $secretsDir
        }
        # O motor do proxy está instalado? É a causa nº 1 de perfil 'proxy' que não sobe.
        $enginePresent = $false
        if ($backend -eq 'proxy') {
            $eng  = if ($p.ContainsKey('Engine')) { [string]$p['Engine'] } else { '' }
            $spec = Get-ClaudexEngineSpec -Engine $eng
            if ($null -ne $spec) {
                $enginePresent = [bool](Get-Command ([string]$spec['Command']) -ErrorAction SilentlyContinue)
            }
        }
        # Credencial POR MODELO (formato `Catalog`): sem isto o doctor olha só o SecretRef do
        # perfil e reporta "sem SecretRef" p/ um perfil cheio de chaves — inclusive chave
        # quebrada saindo como [ok]. Achado em uso real, 2026-07-19.
        $catalogSecrets = @{}
        if ($backend -eq 'proxy') {
            foreach ($e in @(Get-ClaudexCatalog -ProfileObj $p)) {
                if (-not [string]::IsNullOrWhiteSpace($e['SecretRef'])) {
                    $catalogSecrets[[string]$e['Name']] = Test-ClaudexSecretResolves -SecretRef ([string]$e['SecretRef']) -SecretsDir $secretsDir
                }
            }
        }
        Write-Host (Format-ClaudexDoctorLine -ProfileObj $p -SecretResolves $resolves -EnginePresent $enginePresent -CatalogSecrets $catalogSecrets)
    }
    exit 0
}

# --- Lançamento --------------------------------------------------------------------------
try {
    $profileObj = Get-ClaudexProfile -Profiles $profiles -Name $ProfileName
}
catch {
    Write-Host "[claudex] $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$backend = if ($profileObj.ContainsKey('Backend')) { [string]$profileObj['Backend'] } else { '' }
if (-not (Test-ClaudexBackendSupported -Backend $backend)) {
    Write-Host "[claudex] perfil '$ProfileName': backend '$backend' não é suportado nesta fase (só none/direct)." -ForegroundColor Red
    exit 2
}

# Resolve o segredo ANTES de tocar em qualquer env — nunca lança o claude com auth vazio.
# Em 'proxy' o segredo é a chave do provider UPSTREAM (vai só p/ o motor, nunca p/ o claude) e
# pode ser ausente de propósito: o cliproxy autentica por OAuth, com credencial no auth-dir dele.
$token = ''
if ($backend -in @('direct', 'proxy')) {
    $ref = if ($profileObj.ContainsKey('SecretRef')) { [string]$profileObj['SecretRef'] } else { '' }
    $secretOptional = ($backend -eq 'proxy' -and [string]::IsNullOrWhiteSpace($ref))
    if (-not $secretOptional) {
        try {
            $token = Resolve-ClaudexSecret -SecretRef $ref -SecretsDir $secretsDir
        }
        catch {
            Write-Host "[claudex] perfil '$ProfileName': $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '[claudex] abortado — o claude NÃO foi lançado (auth não resolvido).' -ForegroundColor Red
            exit 3
        }
    }
}

# --- Backend 'proxy': sobe o motor tradutor ANTES de lançar o claude ----------------------
# Ordem importa: o motor tem que estar aceitando conexão antes do claude nascer, senão a
# primeira requisição dele falha. Start-ClaudexProxy só retorna com a porta já aberta.
$proxyProc = $null
$runtimeDir = $null
$envVars = $null
try {
    if ($backend -eq 'proxy') {
        $engine = [string]$profileObj['Engine']
        $spec   = Get-ClaudexEngineSpec -Engine $engine
        try {
            $port     = Get-ClaudexEnginePort -ProfileObj $profileObj
            $localKey = New-ClaudexLocalKey
            $authDir  = Join-Path (Get-ClaudexHome) "auth/$engine"
            $null     = New-Item -ItemType Directory -Path $authDir -Force -ErrorAction SilentlyContinue

            # Uma chave POR MODELO do catálogo — modelos de providers diferentes convivem no
            # mesmo perfil, cada um com a sua credencial. Falha em resolver = aborta antes de
            # subir nada: nunca lançamos o claude com um modelo do catálogo sem auth.
            $catalog   = @(Get-ClaudexCatalog -ProfileObj $profileObj)
            $modelKeys = @{}
            foreach ($entry in $catalog) {
                if ([string]::IsNullOrWhiteSpace($entry['SecretRef'])) { continue }
                $envVarName = Get-ClaudexSecretEnvName -ModelName $entry['Name']
                $modelKeys[$envVarName] = Resolve-ClaudexSecret -SecretRef $entry['SecretRef'] -SecretsDir $secretsDir
            }

            $runtimeDir = New-ClaudexRuntimeDir
            $cfgPath    = Join-Path $runtimeDir ([string]$spec['ConfigName'])
            $cfgText    = New-ClaudexEngineConfig -ProfileObj $profileObj -LocalKey $localKey `
                              -Port $port -UpstreamKey $token -AuthDir $authDir
            Set-Content -LiteralPath $cfgPath -Value $cfgText -Encoding UTF8 -NoNewline:$false

            Write-Host "[claudex] subindo motor '$engine' na porta $port..." -ForegroundColor DarkGray
            $proxyProc = Start-ClaudexProxy -EngineSpec $spec -ConfigPath $cfgPath -Port $port `
                             -UpstreamKey $token -ModelKeys $modelKeys -AuthDir $authDir
            Write-Host "[claudex] motor pronto — $($catalog.Count) modelo(s): $(($catalog | ForEach-Object { $_['Name'] }) -join ', ')" -ForegroundColor DarkGray
            Write-Host "[claudex] troque com /model <nome> dentro da sessão." -ForegroundColor DarkGray
        }
        catch {
            Write-Host "[claudex] perfil '$ProfileName': $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '[claudex] abortado — o claude NÃO foi lançado (proxy não subiu).' -ForegroundColor Red
            exit 4
        }
        $envVars = Get-ClaudexEnvForProfile -ProfileObj $profileObj -LocalKey $localKey -Port $port
    }
    else {
        $envVars = Get-ClaudexEnvForProfile -ProfileObj $profileObj -Token $token
    }

    # Statement SOLTO de propósito — NUNCA `$exit = Invoke-ClaudexLaunch ...` (ver nota grande em
    # Invoke-ClaudexLaunch/claudex-lib.ps1: capturar o retorno força redirecionar o stdout do `claude`
    # para um pipe, quebrando a detecção de TTY dele e derrubando pro modo --print sem querer).
    # try/finally NÃO redireciona stream nenhum — só a atribuição redirecionaria. Seguro aqui.
    Invoke-ClaudexLaunch -EnvVars $envVars -ClaudeArgs $ClaudeArgs -ClaudeCommand $ClaudeCommand
}
finally {
    # O motor é filho DESTA sessão: morre junto, sempre — inclusive se o claude crashar ou o
    # usuário der Ctrl+C. Senão sobra proxy órfão segurando a porta no próximo lançamento.
    Stop-ClaudexProxy -Process $proxyProc
    Remove-ClaudexRuntimeDir -Path $runtimeDir
}

if (Test-Path variable:LASTEXITCODE) { exit $LASTEXITCODE } else { exit 0 }
