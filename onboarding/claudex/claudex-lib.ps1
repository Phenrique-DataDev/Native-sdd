# claudex-lib.ps1 — funções puras/reutilizáveis do wrapper `claudex` (troca fina de
# modelo/provider Anthropic-compatível). APENAS DEFINE funções (sem efeito colateral ao
# carregar) — dot-source seguro, testável com Pester. Zero dependência externa.
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.
#
# DESIGN (âncora): o Claude Code lê ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN /
# ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL no START do processo. A troca real é AO LANÇAR
# uma nova sessão `claude`, escopando essas env vars só no processo filho — não existe troca
# no meio de uma sessão viva (isso exigiria proxy, fase futura fora de escopo).

Set-StrictMode -Version Latest

# --- Parsing dos argumentos do CLI (PURA) ------------------------------------------------
function Split-ClaudexArgs {
    <#
      PURA. Separa os argumentos DO CLAUDEX dos que são repassados ao `claude`.

      POR QUE PARSING MANUAL, e não um param() normal (bug real, 2026-07-19):
      o binder do PowerShell faz *prefix matching* em nome de parâmetro. Com um param()
      declarando -ProfileName/-Check/-ClaudeCommand/-ClaudeArgs, as flags MAIS COMUNS do
      Claude Code eram sequestradas antes de chegar nele:
        claudex -p "prompt"  ->  '-p' casava com -Profile; "prompt" virava nome de perfil
                                 ("perfil 'prompt' não encontrado")
        claudex -c           ->  "parameter name 'c' is ambiguous. Possible matches include:
                                 -Check, -ClaudeCommand, -ClaudeArgs"
      `-p` (--print) e `-c` (--continue) são justamente as duas flags mais usadas. Passar
      `--` contornava, mas exigir `--` sempre é uma armadilha (e a doc dizia o contrário).
      O `pwsh -File claudex.ps1 -- ...` ainda quebrava de outro jeito: o `--` chega literal
      e o binder reclama de "parameter name '' is ambiguous".

      REGRA (previsível, sem adivinhação): só reconhecemos como NOSSO um token que bata
      EXATAMENTE (case-insensitive) com um nome conhecido, nas formas -nome ou --nome.
      Qualquer outro token — inclusive `--` — encerra o parsing: ele e todo o resto vão
      para o `claude` verbatim. Sem prefixo, sem abreviação, sem ambiguidade.

      Devolve hashtable: ProfileName, List, Check, ClaudeCommand, ClaudeArgs, Error.
    #>
    param([AllowNull()][string[]]$Argv)

    # ProfileName VAZIO = "não pedi perfil nenhum" — quem chama resolve o default lendo o
    # profiles.psd1 (Get-ClaudexDefaultProfileName). Esta função é PURA e não lê disco, então
    # ela não pode saber qual perfil está marcado `Default = $true`; fixar 'claude' aqui era
    # justamente o que fazia `claudex` sozinho cair sempre em passthrough.
    $out = @{
        ProfileName   = ''
        List          = $false
        Check         = $false
        Login         = ''
        ClaudeCommand = 'claude'
        ClaudeArgs    = @()
        Error         = ''
    }
    $list = @($Argv)
    $i = 0
    while ($i -lt $list.Count) {
        $tok = [string]$list[$i]
        # Normaliza -nome / --nome; qualquer coisa fora disso não é flag nossa.
        $norm = if ($tok -match '^--?([A-Za-z][A-Za-z0-9]*)$') { $Matches[1].ToLowerInvariant() } else { '' }

        switch ($norm) {
            { $_ -in @('profile', 'profilename') } {
                if ($i + 1 -ge $list.Count) { $out.Error = "faltou o nome do perfil depois de '$tok'"; return $out }
                $out.ProfileName = [string]$list[$i + 1]; $i += 2; continue
            }
            'claudecommand' {
                if ($i + 1 -ge $list.Count) { $out.Error = "faltou o valor depois de '$tok'"; return $out }
                $out.ClaudeCommand = [string]$list[$i + 1]; $i += 2; continue
            }
            'list'  { $out.List = $true;  $i++; continue }
            'check' { $out.Check = $true; $i++; continue }
            'login' {
                # -Login <provider>: dispara o fluxo OAuth do motor cliproxy (abre o browser).
                if ($i + 1 -ge $list.Count) { $out.Error = "faltou o provider depois de '$tok' (claude | codex | gemini | kimi | xai)"; return $out }
                $out.Login = [string]$list[$i + 1]; $i += 2; continue
            }
            default {
                # Token desconhecido (ou `--`): daqui pra frente é tudo do claude.
                $rest = @()
                # `--` é separador por hábito — consome sem repassar. Qualquer outra coisa passa.
                $start = if ($tok -eq '--') { $i + 1 } else { $i }
                for ($j = $start; $j -lt $list.Count; $j++) { $rest += [string]$list[$j] }
                $out.ClaudeArgs = $rest
                return $out
            }
        }
    }
    return $out
}

# --- Home do claudex (~/.claude/claudex), agnóstico de SO --------------------------------
function Get-ClaudexHome {
    # EFEITO (leve): resolve a raiz de config do claudex. Parametrizável p/ testes via -HomePath.
    param([string]$HomePath = '')
    if ([string]::IsNullOrWhiteSpace($HomePath)) {
        $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
        $HomePath = if ($onWindows) { $env:USERPROFILE } else { $env:HOME }
    }
    return (Join-Path (Join-Path $HomePath '.claude') 'claudex')
}

# --- Carga dos perfis (.psd1) ------------------------------------------------------------
function Import-ClaudexProfiles {
    # Lê o profiles.psd1 (dado, sem execução de código: Import-PowerShellDataFile). Retorna o
    # array de perfis (hashtables). Ausente/ilegível -> throw com mensagem acionável.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "claudex não configurado: '$Path' ausente. Rode: .\onboarding\install.ps1 -WithClaudex"
    }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    if (-not $data.ContainsKey('Profiles')) {
        throw "profiles.psd1 inválido: falta a chave 'Profiles' ($Path)"
    }
    return @($data.Profiles)
}

# --- Validação de schema (PURA) ----------------------------------------------------------
function Get-ClaudexSchemaError {
    # Devolve a lista de problemas (vazia = válido). Regras: perfil 'claude' sempre presente;
    # cada perfil tem Name não-vazio e Backend em {none,direct,proxy}; 'direct' exige SecretRef;
    # 'proxy' exige Engine conhecido, Port válida (se dada) e pelo menos 1 modelo mapeado.
    param([AllowNull()]$Profiles)
    $errors = [System.Collections.Generic.List[string]]::new()
    $list = @($Profiles)
    if ($list.Count -eq 0) { $errors.Add('nenhum perfil definido'); return $errors.ToArray() }

    $names = @()
    foreach ($p in $list) {
        $name = if ($p -is [hashtable] -and $p.ContainsKey('Name')) { [string]$p['Name'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($name)) { $errors.Add('perfil sem Name'); continue }
        $names += $name

        $backend = if ($p.ContainsKey('Backend')) { [string]$p['Backend'] } else { '' }
        if ($backend -notin @('none', 'direct', 'proxy')) {
            $errors.Add("perfil '$name': Backend inválido '$backend' (esperado: none | direct | proxy)")
            continue
        }
        if ($backend -eq 'direct') {
            $ref = if ($p.ContainsKey('SecretRef')) { [string]$p['SecretRef'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($ref)) {
                $errors.Add("perfil '$name': Backend 'direct' exige SecretRef não-vazio")
            }
        }
        if ($backend -eq 'proxy') {
            $engine = if ($p.ContainsKey('Engine')) { [string]$p['Engine'] } else { '' }
            if ($null -eq (Get-ClaudexEngineSpec -Engine $engine)) {
                $errors.Add("perfil '$name': Backend 'proxy' exige Engine válido (litellm | cliproxy), veio '$engine'")
            }
            else {
                # Porta só é validada com Engine válido (Get-ClaudexEnginePort precisa do spec).
                try { $null = Get-ClaudexEnginePort -ProfileObj $p }
                catch { $errors.Add($_.Exception.Message) }
            }
            # O CATÁLOGO é o que importa: pelo menos 1 modelo, cada um com Provider.
            $catalog = @(Get-ClaudexCatalog -ProfileObj $p)
            if ($catalog.Count -eq 0) {
                $errors.Add("perfil '$name': Backend 'proxy' exige ao menos um modelo (Catalog, ou Models + Provider)")
            }
            foreach ($e in $catalog) {
                if ([string]::IsNullOrWhiteSpace($e['Provider'])) {
                    $errors.Add("perfil '$name': modelo '$($e['Name'])' sem Provider (ex.: openai, anthropic, ollama_chat, oauth)")
                }
                # `oauth` não é um provider como os outros: é a instrução "esta entrada vem da
                # minha conta logada, pelo cliproxy interno". Duas consequências viram regra:
                elseif ([string]$e['Provider'] -ieq 'oauth') {
                    # 1. A credencial JÁ é o login no auth-dir. Um SecretRef aqui seria uma chave
                    #    que ninguém lê — silêncio pior que erro, porque parece configurado.
                    if (-not [string]::IsNullOrWhiteSpace($e['SecretRef'])) {
                        $errors.Add("perfil '$name': modelo '$($e['Name'])' é Provider 'oauth' e não usa SecretRef — a credencial vem do login (claudex -Login <provider>), guardada no auth-dir do motor.")
                    }
                    # 2. Quem alcança o cliproxy é o litellm, como front. Um perfil OAuth com
                    #    Engine 'cliproxy' pediria que o motor encadeasse a si mesmo.
                    if ($engine -ne 'litellm') {
                        $errors.Add("perfil '$name': modelo '$($e['Name'])' é Provider 'oauth', que exige Engine 'litellm' (o front encadeia o cliproxy interno); veio '$engine'")
                    }
                }
            }
            # Porta do sidecar: validada aqui, não no meio do lançamento. E não pode colidir com
            # a do front — dois motores na mesma porta é um erro que só apareceria como "porta já
            # está em uso" depois de o primeiro já ter subido.
            if (Test-ClaudexNeedsSidecar -ProfileObj $p) {
                try {
                    $sPort = Get-ClaudexSidecarPort -ProfileObj $p
                    $fPort = try { Get-ClaudexEnginePort -ProfileObj $p } catch { 0 }
                    if ($fPort -gt 0 -and $sPort -eq $fPort) {
                        $errors.Add("perfil '$name': SidecarPort ($sPort) é igual à porta do motor front — use portas diferentes.")
                    }
                }
                catch { $errors.Add($_.Exception.Message) }
            }
            # Slot tem que apontar p/ um modelo QUE EXISTE no catálogo (achado ao vivo,
            # 2026-07-19): slot apontando p/ nome desconhecido faz o claude pedir esse nome ao
            # motor, que responde 400 'Invalid model name'. Slot AUSENTE agora é legítimo —
            # significa "não remapeia", e o modelo Anthropic original passa direto (útil quando
            # o catálogo tem uma entrada 'anthropic' atendendo justamente isso).
            $nomes = @($catalog | ForEach-Object { $_['Name'] })
            # `DefaultModel` vira ANTHROPIC_MODEL: é o modelo em que a sessão ABRE. Apontar p/
            # fora do catálogo faz a PRIMEIRA mensagem morrer em 400 — o pior lugar para o erro
            # aparecer, porque parece que "o claudex não funciona".
            if ($p.ContainsKey('DefaultModel')) {
                $dm = [string]$p['DefaultModel']
                if (-not [string]::IsNullOrWhiteSpace($dm) -and $nomes -notcontains $dm) {
                    $errors.Add("perfil '$name': DefaultModel '$dm' não está no catálogo. Modelos disponíveis: $($nomes -join ', ')")
                }
            }
            foreach ($kv in (Get-ClaudexSlots -ProfileObj $p).GetEnumerator()) {
                if ($nomes -notcontains $kv.Value) {
                    $errors.Add("perfil '$name': slot $($kv.Key) aponta p/ '$($kv.Value)', que não está no catálogo. Modelos disponíveis: $($nomes -join ', ')")
                }
            }
            # Cloaking/identity-confuse do CLIProxyAPI existem para ESCONDER do provider o que a
            # requisição é (ver a nota em New-ClaudexCliProxyConfig). O claudex desliga os três na
            # config que gera; aqui fechamos a outra porta: um perfil NÃO pode pedir para religar.
            # Sem esta trava, o desligamento seria só um default — e default se contorna calado.
            foreach ($proibido in @('Cloak', 'CloakMode', 'IdentityConfuse', 'DisableClaudeCloakMode')) {
                if ($p.ContainsKey($proibido)) {
                    $errors.Add("perfil '$name': '$proibido' não é suportado. O claudex usa o motor p/ traduzir protocolo e usar a credencial da SUA conta, não p/ disfarçar tráfego ao provider — cloaking fica desligado por construção.")
                }
            }
        }
    }
    if ('claude' -notin $names) { $errors.Add("perfil 'claude' (passthrough) é obrigatório e está ausente") }
    # `Default = $true` em mais de um perfil não tem resposta certa — qual dos dois o `claudex`
    # sem flag lançaria? Reprovar é melhor que escolher o primeiro em silêncio.
    $defaults = @(@($Profiles) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Default') -and [bool]$_['Default'] } | ForEach-Object { [string]$_['Name'] })
    if ($defaults.Count -gt 1) {
        $errors.Add("mais de um perfil marcado 'Default = `$true' ($($defaults -join ', ')) — só um pode ser o default do `claudex` sem flag.")
    }
    return $errors.ToArray()
}

function Get-ClaudexDefaultProfileName {
    <#
      PURA. Qual perfil o `claudex` sem `-Profile` deve lançar.

      POR QUE EXISTE (achado em uso real, 2026-07-20): o default fixo era 'claude' (passthrough),
      então o comando mais curto — o que se digita 100 vezes por dia — era exatamente o único que
      NÃO dava acesso ao catálogo. O usuário só alcançava os modelos digitando `-Profile <nome>`,
      e como cada catálogo vivia num perfil diferente, "usar os meus modelos" virou dois comandos
      mutuamente exclusivos. Marcar `Default = $true` num perfil resolve sem quebrar ninguém:
      quem não marca nada continua caindo em 'claude'.

      Mais de um perfil marcado é ERRO de schema (Get-ClaudexSchemaError reprova) — aqui apenas
      devolvemos o primeiro, porque esta função não valida, só resolve.
    #>
    param([AllowNull()]$Profiles)
    foreach ($p in @($Profiles)) {
        if ($p -is [hashtable] -and $p.ContainsKey('Default') -and [bool]$p['Default']) {
            return [string]$p['Name']
        }
    }
    return 'claude'
}

function Get-ClaudexProfile {
    # Acha o perfil pelo Name (case-insensitive). Ausente -> throw listando os disponíveis.
    param(
        [Parameter(Mandatory)][AllowNull()]$Profiles,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($p in @($Profiles)) {
        if ($p -is [hashtable] -and $p.ContainsKey('Name') -and ([string]$p['Name'] -ieq $Name)) { return $p }
    }
    $disp = (@($Profiles) | ForEach-Object { [string]$_['Name'] }) -join ', '
    throw "perfil '$Name' não encontrado. Disponíveis: $disp"
}

# --- DPAPI (CurrentUser) p/ o backend 'cred:' --------------------------------------------
# Não há binding built-in simples de leitura do Windows Credential Manager em PS 5.1; a
# proteção equivalente (segredo cifrado atrelado ao usuário atual, ilegível por outra conta)
# é o DPAPI CurrentUser. 'cred:<nome>' -> secrets/<nome>.dpapi, decifrado aqui.
function Protect-ClaudexSecret {
    # Cifra um texto -> bytes DPAPI (CurrentUser). Helper p/ o usuário semear cred:<nome>.
    param([Parameter(Mandatory)][string]$PlainText)
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    return [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Unprotect-ClaudexSecret {
    # Decifra bytes DPAPI (CurrentUser) -> texto. Falha (bytes de outro usuário/corrompidos) -> throw.
    param([Parameter(Mandatory)][byte[]]$Bytes)
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

# --- Resolução de segredo (SecretRef -> valor) -------------------------------------------
function Resolve-ClaudexSecret {
    # Resolve o SecretRef p/ o valor do token. NUNCA imprime/loga o valor. Fonte pelo prefixo:
    #   cred:<nome>  -> secrets/<nome>.dpapi (DPAPI CurrentUser)
    #   env:<VAR>    -> variável de ambiente já exportada
    #   file:<nome>  -> secrets/<nome> (texto, ACL restrita)
    # Não resolveu (ausente/vazio/prefixo inválido) -> throw claro, SEM valor. O chamador
    # NUNCA lança o claude com auth vazio.
    param(
        [Parameter(Mandatory)][string]$SecretRef,
        [string]$SecretsDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($SecretsDir)) { $SecretsDir = Join-Path (Get-ClaudexHome) 'secrets' }
    if ($SecretRef -notmatch '^(?<scheme>cred|env|file):(?<name>.+)$') {
        throw "SecretRef inválido: '$SecretRef' (use cred:<nome> | env:<VAR> | file:<nome>)"
    }
    $scheme = $Matches['scheme']
    $name   = $Matches['name'].Trim()

    switch ($scheme) {
        'env' {
            $val = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ([string]::IsNullOrWhiteSpace($val)) { throw "segredo não resolvido: env var '$name' vazia/ausente" }
            return $val
        }
        'file' {
            $file = Join-Path $SecretsDir $name
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "segredo não resolvido: arquivo ausente ($file)" }
            $val = (Get-Content -LiteralPath $file -Raw -ErrorAction Stop).Trim()
            if ([string]::IsNullOrWhiteSpace($val)) { throw "segredo não resolvido: arquivo vazio ($file)" }
            return $val
        }
        'cred' {
            $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
            if (-not $onWindows) { throw "segredo não resolvido: cred:/DPAPI só é suportado no Windows" }
            $file = Join-Path $SecretsDir "$name.dpapi"
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "segredo não resolvido: blob DPAPI ausente ($file)" }
            try {
                $bytes = [System.IO.File]::ReadAllBytes($file)
                $val = Unprotect-ClaudexSecret -Bytes $bytes
            }
            catch { throw "segredo não resolvido: falha ao decifrar o blob DPAPI ($name) — foi criado por outro usuário?" }
            if ([string]::IsNullOrWhiteSpace($val)) { throw "segredo não resolvido: blob DPAPI vazio ($name)" }
            return $val
        }
    }
}

function Test-ClaudexSecretResolves {
    # Doctor: o segredo resolve? Bool, SEM tocar/imprimir o valor. Usa Resolve em try/catch.
    param(
        [Parameter(Mandatory)][string]$SecretRef,
        [string]$SecretsDir = ''
    )
    try { $null = Resolve-ClaudexSecret -SecretRef $SecretRef -SecretsDir $SecretsDir; return $true }
    catch { return $false }
}

# --- Backends suportados -----------------------------------------------------------------
function Test-ClaudexBackendSupported {
    # PURA. 'none' (passthrough), 'direct' (provider que já fala protocolo Anthropic) e
    # 'proxy' (motor tradutor local p/ providers que NÃO falam Anthropic — OpenAI/Gemini/local).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Backend)
    return ($Backend -in @('none', 'direct', 'proxy'))
}

# --- Motores de tradução (backend 'proxy') -----------------------------------------------
function Get-ClaudexEngineSpec {
    # PURA. Metadados de cada motor tradutor suportado. Um motor recebe requisições no
    # protocolo Anthropic (/v1/messages) em 127.0.0.1:<porta> e traduz p/ o provider upstream.
    #
    # VERIFICADO nos docs oficiais (2026-07-19):
    #   litellm  — expõe /v1/messages Anthropic-compatível p/ todos os providers suportados;
    #              sobe com `litellm --config <arquivo>`; porta default 4000; config em
    #              YAML com `model_list[].{model_name,litellm_params}`.
    #              (docs.litellm.ai/docs/anthropic_unified)
    #   cliproxy — porta default 8317 (faixa válida 1024-65535); config YAML com
    #              `port`/`api-keys`/`auth-dir`; sobe com `cli-proxy-api --config <arquivo>`.
    #              (help.router-for.me/configuration/basic)
    #
    # NÃO VERIFICADO (exige validação ao vivo, ver Test-ClaudexProxyReady): o path exato do
    # endpoint Anthropic do cliproxy não aparece na página de configuração — o projeto se
    # descreve como "Claude compatible API service", mas o path não foi confirmado em doc.
    # Por isso o health-check do launch é por PORTA (TCP), não por path HTTP: é o sinal que
    # temos como certo nos dois motores.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Engine)
    switch ($Engine) {
        'litellm' {
            return [ordered]@{
                Engine      = 'litellm'
                Command     = 'litellm'
                ConfigName  = 'litellm.config.yaml'
                DefaultPort = 4000
                ArgsPattern = @('--config', '{config}', '--port', '{port}')
                # A chave upstream vai por ENV (os.environ/...), nunca escrita no arquivo.
                SecretViaEnv = 'CLAUDEX_UPSTREAM_KEY'
                # BUG REAL (achado rodando de verdade, 2026-07-19): no Windows o litellm
                # CRASHA no boot antes de abrir a porta — o banner de startup dele tem
                # caracteres Unicode e o console default é cp1252:
                #   UnicodeEncodeError: 'charmap' codec can't encode characters...
                #   ERROR: Application startup failed. Exiting.
                # Não é config nossa, é o banner do próprio litellm. PYTHONIOENCODING=utf-8
                # resolve e é inócuo nos outros SOs. Sem isto, o backend 'proxy' com litellm
                # NUNCA sobe no Windows — ou seja, na máquina-alvo deste framework.
                EnvExtra    = @{ PYTHONIOENCODING = 'utf-8' }
                InstallHint = 'uv tool install "litellm[proxy]"'
            }
        }
        'cliproxy' {
            return [ordered]@{
                Engine      = 'cliproxy'
                Command     = 'cli-proxy-api'
                ConfigName  = 'cliproxy.config.yaml'
                DefaultPort = 8317
                ArgsPattern = @('--config', '{config}')
                # Não há evidência documentada de interpolação de env var na config do
                # cliproxy: a chave upstream é escrita NO ARQUIVO (dir com ACL restrita,
                # removido no finally do launch). Trade-off registrado de propósito.
                SecretViaEnv = ''
                EnvExtra     = @{}   # binário Go: não tem o problema de encoding do Python
                InstallHint = 'baixe o binário em github.com/router-for-me/CLIProxyAPI/releases'
            }
        }
        default { return $null }
    }
}

function Get-ClaudexEnginePort {
    # PURA. Porta efetiva do perfil: Port explícito, senão o default do motor.
    param([Parameter(Mandatory)][hashtable]$ProfileObj)
    $engine = if ($ProfileObj.ContainsKey('Engine')) { [string]$ProfileObj['Engine'] } else { '' }
    $spec = Get-ClaudexEngineSpec -Engine $engine
    if ($null -eq $spec) { throw "motor '$engine' desconhecido (esperado: litellm | cliproxy)" }
    if ($ProfileObj.ContainsKey('Port')) {
        $p = 0
        if ([int]::TryParse([string]$ProfileObj['Port'], [ref]$p) -and $p -ge 1024 -and $p -le 65535) { return $p }
        throw "perfil '$($ProfileObj['Name'])': Port inválida '$($ProfileObj['Port'])' (esperado 1024-65535)"
    }
    return [int]$spec['DefaultPort']
}

function Get-ClaudexCatalog {
    <#
      PURA. Normaliza o perfil num CATÁLOGO de modelos — a estrutura central do backend 'proxy'.

      POR QUE CATÁLOGO, e não os 3 slots (correção de arquitetura, 2026-07-19):
      o desenho anterior tratava Opus/Sonnet/Haiku como O mecanismo, o que criava dois defeitos
      graves, ambos apontados em revisão:
        1. CANIBALIZAÇÃO — sob um perfil proxy você PERDIA os modelos reais da Anthropic:
           escolher "Sonnet" dava o modelo mapeado, e não havia como voltar ao Sonnet de verdade
           na mesma sessão.
        2. TETO DE 3 — impossível expor 5, 10 modelos, porque os nomes do picker são finitos.

      O que destrava: `/model <nome>` e `claude --model <nome>` aceitam nome ARBITRÁRIO, que
      chega ao proxy verbatim (VERIFICADO ao vivo: `--model qwen2.5-coder:14b` roteou certo).
      Então o catálogo pode ter N modelos, de providers DIFERENTES, inclusive `anthropic` —
      e aí Sonnet real e GPT convivem na mesma sessão. É o mesmo padrão do guia oficial do
      LiteLLM p/ Claude Code (model_list com OpenAI + Anthropic + Bedrock juntos).

      Os 3 slots viram o que sempre deveriam ter sido: ATALHOS opcionais p/ o picker.

      Aceita duas formas de perfil:
        - Catalog = @( @{Name;Provider;Model?;SecretRef?;BaseUrl?;Notes?;Tuning?} ... )  (completa)
        - Models  = @{Opus;Sonnet;Haiku;Extra} + Provider/BaseUrl/SecretRef do perfil    (simples)
      Devolve sempre uma lista normalizada de entradas do catálogo.
    #>
    param([Parameter(Mandatory)][hashtable]$ProfileObj)

    $out = [System.Collections.Generic.List[hashtable]]::new()
    $seen = @{}

    function Add-Entry {
        param($Name, $Provider, $Model, $SecretRef, $BaseUrl, $Notes, $Tuning)
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        if ($seen.ContainsKey($Name)) { return }
        $seen[$Name] = $true
        $out.Add(@{
            Name      = [string]$Name
            Provider  = [string]$Provider
            # Model vazio = o próprio Name é o ID no provider (caso comum).
            Model     = if ([string]::IsNullOrWhiteSpace($Model)) { [string]$Name } else { [string]$Model }
            SecretRef = [string]$SecretRef
            BaseUrl   = [string]$BaseUrl
            Notes     = [string]$Notes
            Tuning    = if ($Tuning -is [hashtable]) { $Tuning } else { @{} }
        })
    }

    # --- Forma completa: Catalog explícito -------------------------------------------------
    if ($ProfileObj.ContainsKey('Catalog')) {
        foreach ($e in @($ProfileObj['Catalog'])) {
            if (-not ($e -is [hashtable])) { continue }
            $g = { param($k) if ($e.ContainsKey($k)) { $e[$k] } else { $null } }
            Add-Entry -Name (& $g 'Name') -Provider (& $g 'Provider') -Model (& $g 'Model') `
                      -SecretRef (& $g 'SecretRef') -BaseUrl (& $g 'BaseUrl') `
                      -Notes (& $g 'Notes') -Tuning (& $g 'Tuning')
        }
        return $out.ToArray()
    }

    # --- Forma simples: Models + Provider/BaseUrl/SecretRef do perfil ----------------------
    $prov = if ($ProfileObj.ContainsKey('Provider')) { [string]$ProfileObj['Provider'] } else { '' }
    $base = if ($ProfileObj.ContainsKey('BaseUrl'))  { [string]$ProfileObj['BaseUrl'] }  else { '' }
    $ref  = if ($ProfileObj.ContainsKey('SecretRef')){ [string]$ProfileObj['SecretRef'] }else { '' }
    $tun  = if ($ProfileObj.ContainsKey('Tuning') -and $ProfileObj['Tuning'] -is [hashtable]) { $ProfileObj['Tuning'] } else { @{} }
    foreach ($m in @(Get-ClaudexProfileModelList -ProfileObj $ProfileObj)) {
        Add-Entry -Name $m -Provider $prov -Model $m -SecretRef $ref -BaseUrl $base -Notes '' -Tuning $tun
    }
    return $out.ToArray()
}

function Get-ClaudexSlotName {
    # PURA. Os slots de alias que o Claude Code resolve por env var, e a env de cada um.
    #
    # SÃO QUATRO, NÃO TRÊS (doc oficial, conferida em 2026-07-20): além de OPUS/SONNET/HAIKU
    # existe ANTHROPIC_DEFAULT_FABLE_MODEL, suportado a partir do Claude Code v2.1.176. O claudex
    # ignorava o quarto, então um catálogo com 10 modelos tinha 3 atalhos onde cabiam 4 — e o
    # slot `fable` ficava apontando p/ um ID Anthropic que, sob 'proxy', o motor não conhece.
    return [ordered]@{
        Opus   = 'ANTHROPIC_DEFAULT_OPUS_MODEL'
        Sonnet = 'ANTHROPIC_DEFAULT_SONNET_MODEL'
        Haiku  = 'ANTHROPIC_DEFAULT_HAIKU_MODEL'
        Fable  = 'ANTHROPIC_DEFAULT_FABLE_MODEL'
    }
}

function Get-ClaudexSlots {
    # PURA. Os atalhos do picker -> nome de modelo do catálogo. Aceita `Slots` (forma completa)
    # ou `Models.Opus/Sonnet/Haiku/Fable` (forma simples). Slot vazio é LEGÍTIMO: significa "não
    # remapeia este slot" — o Claude Code segue mandando o modelo Anthropic original, que o
    # catálogo pode inclusive atender se tiver uma entrada com esse ID exato.
    param([Parameter(Mandatory)][hashtable]$ProfileObj)
    $slots = [ordered]@{}
    $src = $null
    if ($ProfileObj.ContainsKey('Slots') -and $ProfileObj['Slots'] -is [hashtable]) { $src = $ProfileObj['Slots'] }
    elseif ($ProfileObj.ContainsKey('Models') -and $ProfileObj['Models'] -is [hashtable]) { $src = $ProfileObj['Models'] }
    if ($null -eq $src) { return $slots }
    foreach ($k in @(Get-ClaudexSlotName).Keys) {
        if ($src.ContainsKey($k)) {
            $v = [string]$src[$k]
            if (-not [string]::IsNullOrWhiteSpace($v)) { $slots[$k] = $v }
        }
    }
    return $slots
}

# --- Sidecar OAuth: litellm (front) -> cliproxy (credencial de assinatura) ----------------
# O PROBLEMA QUE ISTO RESOLVE (achado em uso real, 2026-07-20): um perfil = um motor, e os dois
# motores têm coberturas DISJUNTAS. O litellm fala com qualquer provider por API key (e com o
# Ollama local), mas não sabe usar login OAuth. O cliproxy sabe usar OAuth — é o único caminho
# para a SUA assinatura Claude/Codex/Gemini — mas não é o motor validado ao vivo aqui. Enquanto
# cada perfil escolhia UM, "modelo local + chave de API + conta logada na mesma sessão" era
# impossível por construção: faltava sempre um terço do catálogo.
#
# O ENCADEAMENTO: o litellm continua sendo o front que o Claude Code enxerga (ANTHROPIC_BASE_URL
# aponta p/ ele). Quando o catálogo tem alguma entrada `Provider = 'oauth'`, o claudex sobe TAMBÉM
# o cliproxy numa porta interna, com o auth-dir onde vivem as credenciais de login, e roteia só
# essas entradas p/ lá — pela superfície OpenAI-compatível dele (`/v1`), que é a que o litellm
# consome sem adivinhação de protocolo. As demais entradas seguem indo direto do litellm ao
# provider, como sempre foram. Nada do que já funcionava muda de caminho.
#
# A credencial NUNCA passa por aqui: ela fica no auth-dir do cliproxy (o usuário fez `claudex
# -Login <provider>` uma vez). O que viaja entre os dois motores é a chave EFÊMERA do gateway
# local, gerada por lançamento.
$script:ClaudexSidecarKeyEnv = 'CLAUDEX_SIDECAR_KEY'

function Get-ClaudexSidecarKeyEnvName {
    # PURA. Nome da env var que leva a chave efêmera do sidecar ao processo do litellm (o YAML a
    # referencia por os.environ/<nome>, então ela nunca é escrita no arquivo de config).
    return $script:ClaudexSidecarKeyEnv
}

function Test-ClaudexNeedsSidecar {
    # PURA. O perfil tem alguma entrada de catálogo que depende de login OAuth?
    param([Parameter(Mandatory)][hashtable]$ProfileObj)
    foreach ($e in @(Get-ClaudexCatalog -ProfileObj $ProfileObj)) {
        if ([string]$e['Provider'] -ieq 'oauth') { return $true }
    }
    return $false
}

function Get-ClaudexSidecarPort {
    # PURA. Porta do cliproxy interno. `SidecarPort` no perfil, senão o default do motor (8317).
    # Validada na mesma faixa da porta do front — porta inválida é erro de schema, não surpresa
    # no meio do lançamento.
    param([Parameter(Mandatory)][hashtable]$ProfileObj)
    if ($ProfileObj.ContainsKey('SidecarPort')) {
        $p = 0
        if ([int]::TryParse([string]$ProfileObj['SidecarPort'], [ref]$p) -and $p -ge 1024 -and $p -le 65535) { return $p }
        throw "perfil '$($ProfileObj['Name'])': SidecarPort inválida '$($ProfileObj['SidecarPort'])' (esperado 1024-65535)"
    }
    return [int](Get-ClaudexEngineSpec -Engine 'cliproxy')['DefaultPort']
}

function Get-ClaudexLoginFlag {
    # PURA. provider -> flag de login OAuth do binário cli-proxy-api. $null se não suportado.
    #
    # VERIFICADO AO VIVO (2026-07-19) rodando `cli-proxy-api.exe --help` da release v7.2.91
    # (Commit fde40c5a) nesta máquina — não é leitura de doc. As flags existentes são exatamente:
    #   -claude-login · -codex-login · -codex-device-login · -antigravity-login · -kimi-login
    #   -xai-login · -no-browser · -oauth-callback-port · -config
    # NÃO existe um `-gemini-login`: o caminho Google é o `-antigravity-login`. Mapear 'gemini'
    # para uma flag inventada daria "flag provided but not defined" e um erro opaco.
    param([Parameter(Mandatory)][string]$Provider)
    $map = @{
        'claude'      = '-claude-login'
        'codex'       = '-codex-login'
        'openai'      = '-codex-login'
        'gemini'      = '-antigravity-login'
        'antigravity' = '-antigravity-login'
        'kimi'        = '-kimi-login'
        'xai'         = '-xai-login'
        'grok'        = '-xai-login'
    }
    $k = $Provider.ToLowerInvariant()
    if ($map.ContainsKey($k)) { return $map[$k] }
    return $null
}

function Get-ClaudexLoginProviderList {
    # PURA. Nomes aceitos pelo -Login, p/ mensagem de erro acionável (nunca "provider inválido"
    # sem dizer quais valem).
    return @('claude', 'codex', 'gemini', 'kimi', 'xai')
}

function Get-ClaudexSecretEnvName {
    # PURA. Nome da env var que carrega a chave de UMA entrada do catálogo. Determinístico e
    # sanitizado (o YAML referencia por os.environ/<nome>).
    param([Parameter(Mandatory)][string]$ModelName)
    $safe = ($ModelName.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
    return "CLAUDEX_KEY_$safe"
}

function Get-ClaudexProfileModelList {
    # PURA. Consolida TODOS os nomes de modelo que o perfil expõe ao Claude Code:
    #   - os 3 slots do picker (Models.Opus/Sonnet/Haiku) — aparecem em `/model` sem digitar;
    #   - Models.Extra (array) — NÃO aparecem no picker, mas são chamáveis por `/model <nome>`,
    #     que os docs confirmam aceitar nome arbitrário de modelo, não só entrada da lista.
    # Devolve array de nomes únicos, na ordem: Opus, Sonnet, Haiku, Extra...
    param([Parameter(Mandatory)][hashtable]$ProfileObj)
    $out = [System.Collections.Generic.List[string]]::new()
    if (-not ($ProfileObj.ContainsKey('Models') -and $ProfileObj['Models'] -is [hashtable])) { return @() }
    $models = $ProfileObj['Models']
    foreach ($slot in @('Opus', 'Sonnet', 'Haiku')) {
        if ($models.ContainsKey($slot)) {
            $v = [string]$models[$slot]
            if (-not [string]::IsNullOrWhiteSpace($v) -and $out -notcontains $v) { $out.Add($v) }
        }
    }
    if ($models.ContainsKey('Extra')) {
        foreach ($v in @($models['Extra'])) {
            $s = [string]$v
            if (-not [string]::IsNullOrWhiteSpace($s) -and $out -notcontains $s) { $out.Add($s) }
        }
    }
    return $out.ToArray()
}

# Contexto default dos modelos locais (Ollama). MEDIDO em uso real (2026-07-20): o Ollama serve
# com `context_length: 4096` por default, e o system prompt + tools do Claude Code sozinhos já
# estouram isso. O resultado observado foi entrada TRUNCADA, não erro: o qwen2.5-coder alucinou
# um arquivo que não existia, o gemma4:26b "respondeu" que não tinha acesso ao filesystem, o
# gpt-oss vazou o raciocínio interno na resposta. Todos falhas de contexto cortado, não de
# capacidade do modelo. 32768 cabe o prompt do Claude Code com folga de histórico; os modelos
# LOCAIS que este framework recomenda (poucos, e os mais fortes) suportam essa janela nativamente.
# Custo: VRAM. O KV cache cresce com a janela — por isso é premissa "poucos modelos fortes", e o
# valor é sobreponível por entrada (Tuning.num_ctx) para quem tiver menos VRAM.
$script:ClaudexDefaultOllamaNumCtx = 32768

function Get-ClaudexOllamaNumCtx {
    <#
      PURA. Qual `num_ctx` uma entrada do catálogo deve pedir ao Ollama. 0 = não aplica (não é
      Ollama, ou o usuário desligou explicitamente com num_ctx = 0).

      Precedência: Tuning.num_ctx explícito (respeitado, inclusive 0 p/ desligar) > default do
      claudex p/ Ollama > 0 p/ qualquer outro provider. Só toca em entradas cujo Provider começa
      com 'ollama' (ollama, ollama_chat) — para os demais, o contexto é do provider, não nosso.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [int]$Default = -1
    )
    if ($Default -lt 0) { $Default = $script:ClaudexDefaultOllamaNumCtx }
    $prov = [string]$Entry['Provider']
    if ($prov -notmatch '^ollama') { return 0 }

    $tuning = if ($Entry['Tuning'] -is [hashtable]) { $Entry['Tuning'] } else { @{} }
    foreach ($k in $tuning.Keys) {
        if ([string]$k -ieq 'num_ctx') {
            $v = 0
            if ([int]::TryParse([string]$tuning[$k], [ref]$v) -and $v -ge 0) { return $v }
        }
    }
    return $Default
}

# --- Geração da config de cada motor (PURAS) ---------------------------------------------
function ConvertTo-ClaudexYamlScalar {
    # PURA. Escapa um escalar p/ YAML entre aspas duplas (suficiente p/ o que geramos:
    # nomes de modelo, URLs e chaves — nunca texto multilinha).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return '"' + ($Value -replace '\\', '\\\\' -replace '"', '\"') + '"'
}

function New-ClaudexLiteLlmConfig {
    # PURA. Gera o config.yaml do LiteLLM a partir do perfil. Formato verificado nos docs
    # (model_list[].{model_name,litellm_params}); a chave upstream NUNCA é escrita no arquivo
    # — vai como `os.environ/CLAUDEX_UPSTREAM_KEY`, que o LiteLLM resolve do ambiente do
    # processo dele. Devolve o texto do YAML.
    param(
        [Parameter(Mandatory)][hashtable]$ProfileObj,
        [Parameter(Mandatory)][string]$LocalKey,
        # Porta do cliproxy interno. Só é usada pelas entradas `Provider = 'oauth'`; um catálogo
        # sem nenhuma delas ignora este parâmetro por completo.
        [int]$SidecarPort = 0
    )
    $catalog = Get-ClaudexCatalog -ProfileObj $ProfileObj

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# GERADO pelo claudex — não edite à mão: é reescrito a cada lançamento.')
    [void]$sb.AppendLine("# Perfil: $([string]$ProfileObj['Name']) · motor: litellm · $($catalog.Count) modelo(s)")
    [void]$sb.AppendLine('model_list:')
    foreach ($e in $catalog) {
        $isOAuth = ([string]$e['Provider'] -ieq 'oauth')
        if ($isOAuth -and $SidecarPort -le 0) {
            throw "perfil '$($ProfileObj['Name'])': modelo '$($e['Name'])' é OAuth mas o sidecar não tem porta resolvida"
        }
        # `model_name` = o que o Claude Code pede — por /model <nome> OU pelos slots do picker.
        # `model` = como o LiteLLM roteia: "<provider>/<modelo>". Cada entrada tem o SEU
        # provider e a SUA chave, então anthropic + openai + local convivem no mesmo perfil.
        [void]$sb.AppendLine("  - model_name: $(ConvertTo-ClaudexYamlScalar $e['Name'])")
        [void]$sb.AppendLine('    litellm_params:')
        if ($isOAuth) {
            # Prefixo `openai/` NÃO significa "modelo da OpenAI": significa "fale o protocolo
            # OpenAI com o api_base que eu mandar". É a superfície que o cliproxy expõe em /v1
            # para TODAS as contas logadas (Claude, Codex, Gemini), então é por ela que o front
            # alcança a assinatura sem precisar adivinhar um path Anthropic não documentado.
            [void]$sb.AppendLine("      model: $(ConvertTo-ClaudexYamlScalar "openai/$($e['Model'])")")
            [void]$sb.AppendLine("      api_base: $(ConvertTo-ClaudexYamlScalar "http://127.0.0.1:$SidecarPort/v1")")
            # Chave EFÊMERA do gateway local (não é a credencial do provider — essa nunca sai do
            # auth-dir do cliproxy). Via env, como todo o resto: nunca escrita no arquivo.
            [void]$sb.AppendLine("      api_key: os.environ/$(Get-ClaudexSidecarKeyEnvName)")
        }
        else {
            [void]$sb.AppendLine("      model: $(ConvertTo-ClaudexYamlScalar "$($e['Provider'])/$($e['Model'])")")
            # Chave por modelo, sempre via env (nunca escrita no arquivo). Sem SecretRef =
            # provider que não pede chave (Ollama e afins): omite a linha inteira.
            if (-not [string]::IsNullOrWhiteSpace($e['SecretRef'])) {
                [void]$sb.AppendLine("      api_key: os.environ/$(Get-ClaudexSecretEnvName -ModelName $e['Name'])")
            }
            if (-not [string]::IsNullOrWhiteSpace($e['BaseUrl'])) {
                [void]$sb.AppendLine("      api_base: $(ConvertTo-ClaudexYamlScalar $e['BaseUrl'])")
            }
        }
        # Tuning por especialidade do modelo. drop_params ligado por default: o Claude Code
        # manda params que nem todo provider aceita — sem isso, 400 na primeira mensagem.
        $tuning = [ordered]@{ drop_params = $true }
        # num_ctx dos modelos LOCAIS: sem isto o Ollama serve com 4096 e a entrada chega truncada
        # (ver a nota em $ClaudexDefaultOllamaNumCtx). Injetado ANTES do Tuning do usuário, então
        # um num_ctx explícito no Tuning ainda vence (Get-ClaudexOllamaNumCtx já resolveu a
        # precedência; aqui só emitimos o valor final e evitamos duplicar a chave).
        $numCtx = Get-ClaudexOllamaNumCtx -Entry $e
        if ($numCtx -gt 0) { $tuning['num_ctx'] = $numCtx }
        foreach ($k in $e['Tuning'].Keys) {
            if ([string]$k -ieq 'num_ctx') { continue }   # já resolvido por Get-ClaudexOllamaNumCtx
            $tuning[[string]$k] = $e['Tuning'][$k]
        }
        foreach ($k in $tuning.Keys) {
            $v = $tuning[$k]
            $rendered = if ($v -is [bool]) { $v.ToString().ToLowerInvariant() }
                        elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { [string]$v }
                        else { ConvertTo-ClaudexYamlScalar ([string]$v) }
            [void]$sb.AppendLine("      ${k}: $rendered")
        }
    }
    [void]$sb.AppendLine('litellm_settings:')
    [void]$sb.AppendLine('  drop_params: true')
    [void]$sb.AppendLine('general_settings:')
    [void]$sb.AppendLine("  master_key: $(ConvertTo-ClaudexYamlScalar $LocalKey)")
    return $sb.ToString()
}

# --- PURA: chaves de cloaking presentes no JSON de UMA credencial ------------------------------
# POR QUE ISTO EXISTE: ler `disable-claude-cloak-mode: true` na config e concluir "cloaking
# desligado" estava ERRADO. A precedência real, lida no fonte pinado v7.2.91
# (internal/runtime/executor/claude_executor.go, applyCloaking), é — do mais fraco ao mais forte:
#     default "auto"  ->  disable-claude-cloak-mode (força "never")  ->  ATRIBUTOS DA CREDENCIAL
# ou seja, um `cloak_mode` dentro do JSON do auth-dir SOBRESCREVE a nossa trava global. A trava
# que tínhamos era, portanto, contornável por um arquivo — em silêncio.
# O login do próprio binário NUNCA grava essas chaves (o fonte só as LÊ), então achá-las é sempre
# edição deliberada: bloquear não quebra o fluxo OAuth normal.
function Get-ClaudexAuthCloakKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$JsonText)
    $achadas = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return @() }
    try { $obj = $JsonText | ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    if ($null -eq $obj) { return @() }
    foreach ($k in @('cloak_mode', 'cloak_strict_mode', 'cloak_sensitive_words', 'cloak_cache_user_id')) {
        # `-Property` em vez de acesso por ponto: StrictMode faria o ponto lançar em chave ausente.
        if ($obj.PSObject.Properties.Name -contains $k) { [void]$achadas.Add($k) }
    }
    return $achadas.ToArray()
}

# --- Varre o auth-dir; devolve @( @{File; Keys} ) — vazio = limpo ------------------------------
function Get-ClaudexAuthCloakOverride {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$AuthDir)
    $out = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($AuthDir) -or -not (Test-Path -LiteralPath $AuthDir)) { return @() }
    foreach ($f in @(Get-ChildItem -LiteralPath $AuthDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $keys = @(Get-ClaudexAuthCloakKey -JsonText (Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue))
        if ($keys.Count -gt 0) { [void]$out.Add(@{ File = $f.Name; Keys = $keys }) }
    }
    return $out.ToArray()
}

function Get-ClaudexOAuthCredentialCount {
    # EFEITO (leitura). Quantas credenciais de login existem no auth-dir do cliproxy. É o sinal
    # de que o `claudex -Login <provider>` já foi feito: sem isto o doctor diria "[ok]" para um
    # perfil OAuth que vai falhar no primeiro prompt, porque nunca ninguém logou. Conta arquivos,
    # nunca lê conteúdo — a credencial não passa por aqui.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$AuthDir)
    if ([string]::IsNullOrWhiteSpace($AuthDir) -or -not (Test-Path -LiteralPath $AuthDir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $AuthDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
}

function New-ClaudexCliProxyConfig {
    # PURA. Gera o config.yaml do CLIProxyAPI a partir do perfil.
    #
    # VERIFICADO (2026-07-19) contra o `config.example.yaml` CANÔNICO do repositório upstream:
    # `port`, `api-keys`, `auth-dir` e o sub-schema de `openai-compatibility` (name / base-url /
    # api-key-entries[].api-key / models[].{name,alias}) batem EXATAMENTE com o exemplo oficial.
    # O que antes estava marcado como "não verificado" no sub-schema deixou de estar.
    #
    # VALIDADO AO VIVO em 2026-07-20 (o que este comentário dizia estar pendente, deixou de estar):
    # a config gerada por esta função subiu o binário real v7.2.91, que aceitou `port`/`api-keys`/
    # `auth-dir`, serviu `/v1/models` com os 14 modelos da conta logada e respondeu a um
    # `/v1/chat/completions` de ponta a ponta pela assinatura — sem chave de API em lugar nenhum.
    # O caminho exercitado foi o de SIDECAR (UpstreamKey vazio, credencial no auth-dir). O ramo
    # `openai-compatibility` (UpstreamKey preenchido) continua só conferido contra doc.
    #
    # FLAGS DE LOGIN OAuth (verificadas no fonte, cmd/server/main.go): -claude-login ·
    # -codex-login · -codex-device-login · -antigravity-login · -kimi-login · -xai-login ·
    # -no-browser · -oauth-callback-port · -config <path>. Não invente flag fora desta lista.
    #
    # Ao contrário do LiteLLM, aqui a chave upstream é escrita NO ARQUIVO (sem evidência de
    # suporte a env var). Por isso o arquivo vive em dir com ACL restrita e é apagado no
    # finally do launch — ver Start-ClaudexProxy/Invoke-ClaudexLaunch.
    param(
        [Parameter(Mandatory)][hashtable]$ProfileObj,
        [Parameter(Mandatory)][string]$LocalKey,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][AllowEmptyString()][string]$UpstreamKey,
        [Parameter(Mandatory)][string]$AuthDir
    )
    $models  = Get-ClaudexProfileModelList -ProfileObj $ProfileObj
    $baseUrl = if ($ProfileObj.ContainsKey('BaseUrl')) { [string]$ProfileObj['BaseUrl'] } else { '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# GERADO pelo claudex — não edite à mão: é reescrito a cada lançamento.')
    [void]$sb.AppendLine("# Perfil: $([string]$ProfileObj['Name']) · motor: cliproxy")
    [void]$sb.AppendLine("port: $Port")
    [void]$sb.AppendLine('api-keys:')
    [void]$sb.AppendLine("  - $(ConvertTo-ClaudexYamlScalar $LocalKey)")
    [void]$sb.AppendLine("auth-dir: $(ConvertTo-ClaudexYamlScalar $AuthDir)")

    # --- TRAVAS DE HONESTIDADE DE TRÁFEGO (não são preferência; são o limite do que geramos) ---
    # O CLIProxyAPI traz recursos cuja função declarada é ESCONDER do provider o que a requisição
    # é. Lidos no config.example.yaml canônico (2026-07-19):
    #   · `cloak.mode: "auto"` — LIGADO POR DEFAULT no upstream. Disfarça cliente não-Claude-Code
    #     como Claude Code, incluindo "system prompt replacement".
    #   · `cloak.sensitive-words` — ofusca palavras (o exemplo cita "API", "proxy") com caracteres
    #     de LARGURA ZERO.
    #   · `codex.identity-confuse` — remapeia prompt_cache_key e identidade de instalação; a doc
    #     do próprio projeto diz que serve a quem teme "TOS enforcement bans".
    # O claudex usa este motor para TRADUZIR PROTOCOLO e para usar a credencial da SUA conta —
    # não para disfarçar tráfego. Então desligamos os três EXPLICITAMENTE, sobrescrevendo o
    # default do upstream, e `Get-ClaudexSchemaError` REPROVA um perfil que tente religá-los
    # (o -Check não deixa passar). Sem isto, o default do upstream cloaka sozinho e o usuário
    # nem fica sabendo — que é exatamente o tipo de coisa que este framework não faz em silêncio.
    # A trava tem uma TERCEIRA porta, fora deste arquivo: os atributos da credencial vencem
    # `disable-claude-cloak-mode` (ver Get-ClaudexAuthCloakOverride, barrada em Start-ClaudexProxy).
    [void]$sb.AppendLine('disable-claude-cloak-mode: true')
    [void]$sb.AppendLine('codex:')
    [void]$sb.AppendLine('  identity-confuse: false')
    # DIAGNOSTICABILIDADE: o motor sobe com janela oculta e sem captura de stdout, então o default
    # do upstream (`logging-to-file: false` = log só em stdout) fazia todo diagnóstico evaporar.
    # Foi exatamente o que cegou a investigação do hang mudo do Gemini: o 429 existia, mas não
    # havia onde lê-lo. Com o log em arquivo rotativo, a próxima falha desse tipo tem onde ser vista.
    [void]$sb.AppendLine('logging-to-file: true')
    # Plugin é código dinâmico carregado in-process; nada no nosso fluxo precisa disso.
    [void]$sb.AppendLine('plugins:')
    [void]$sb.AppendLine('  enabled: false')

    # UpstreamKey vazio = fluxo OAuth: as credenciais já vivem no auth-dir (o usuário fez o
    # login pelo binário antes), então não há bloco de chave a escrever.
    if (-not [string]::IsNullOrWhiteSpace($UpstreamKey)) {
        [void]$sb.AppendLine('openai-compatibility:')
        [void]$sb.AppendLine("  - name: $(ConvertTo-ClaudexYamlScalar ([string]$ProfileObj['Provider']))")
        if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
            [void]$sb.AppendLine("    base-url: $(ConvertTo-ClaudexYamlScalar $baseUrl)")
        }
        [void]$sb.AppendLine('    api-key-entries:')
        [void]$sb.AppendLine("      - api-key: $(ConvertTo-ClaudexYamlScalar $UpstreamKey)")
        [void]$sb.AppendLine('    models:')
        foreach ($m in $models) {
            [void]$sb.AppendLine("      - name: $(ConvertTo-ClaudexYamlScalar $m)")
            [void]$sb.AppendLine("        alias: $(ConvertTo-ClaudexYamlScalar $m)")
        }
    }
    return $sb.ToString()
}

function New-ClaudexEngineConfig {
    # PURA (dispatcher). Devolve o texto de config do motor do perfil.
    param(
        [Parameter(Mandatory)][hashtable]$ProfileObj,
        [Parameter(Mandatory)][string]$LocalKey,
        [Parameter(Mandatory)][int]$Port,
        [AllowEmptyString()][string]$UpstreamKey = '',
        [string]$AuthDir = '',
        [int]$SidecarPort = 0
    )
    $engine = [string]$ProfileObj['Engine']
    switch ($engine) {
        'litellm'  { return New-ClaudexLiteLlmConfig -ProfileObj $ProfileObj -LocalKey $LocalKey -SidecarPort $SidecarPort }
        'cliproxy' { return New-ClaudexCliProxyConfig -ProfileObj $ProfileObj -LocalKey $LocalKey -Port $Port -UpstreamKey $UpstreamKey -AuthDir $AuthDir }
        default    { throw "motor '$engine' desconhecido (esperado: litellm | cliproxy)" }
    }
}

function New-ClaudexLocalKey {
    # EFEITO (aleatório). Chave efêmera do gateway local, gerada A CADA lançamento — nunca
    # persiste segredo fixo em disco. Vale só enquanto o proxy daquela sessão está vivo.
    return 'sk-claudex-' + ([guid]::NewGuid().ToString('N'))
}

# --- Ciclo de vida do proxy (EFEITO) -----------------------------------------------------
function Test-ClaudexPortOpen {
    # EFEITO. A porta local está aceitando conexão? Health-check por TCP de propósito: é o
    # sinal que vale nos DOIS motores (o path HTTP do endpoint Anthropic do cliproxy não está
    # confirmado em doc — ver Get-ClaudexEngineSpec).
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-ClaudexFreePort {
    <#
      EFEITO (sonda TCP). Devolve a porta preferida se estiver livre; senão, a próxima livre
      acima dela.

      POR QUE (achado em uso real, 2026-07-20): a porta era FIXA (4000 / 8317), e isso quebrava
      dois casos comuns, sempre com a mesma mensagem enganosa ("porta já está em uso — outro
      proxy vivo?"):
        1. DUAS SESSÕES claudex ao mesmo tempo — a segunda simplesmente não subia. Abrir dois
           terminais é rotina, não caso exótico.
        2. MOTOR ÓRFÃO de uma sessão que morreu sem rodar o teardown (Ctrl+C duro, processo
           morto, crash). Um órfão travava TODOS os lançamentos seguintes até alguém achar o PID
           na mão — o tipo de falha que faz a ferramenta parecer "inconsistente".
      Escolher outra porta resolve os dois sem matar processo de ninguém: o `ANTHROPIC_BASE_URL`
      é montado com a porta REAL, então nada mais precisa saber disso.
    #>
    param(
        [Parameter(Mandatory)][int]$Preferred,
        [int]$MaxTries = 40
    )
    for ($i = 0; $i -lt $MaxTries; $i++) {
        $p = $Preferred + $i
        if ($p -gt 65535) { break }
        if (-not (Test-ClaudexPortOpen -Port $p -TimeoutMs 200)) { return $p }
    }
    throw "nenhuma porta livre entre $Preferred e $($Preferred + $MaxTries - 1) — há muitos motores vivos? Feche as sessões claudex abertas."
}

function Wait-ClaudexProxyReady {
    # EFEITO. Espera a porta abrir até TimeoutSec. Devolve $true se abriu. Não lança — quem
    # chama decide o que fazer (abortar sem lançar o claude).
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-ClaudexPortOpen -Port $Port) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Resolve-ClaudexEngineCommand {
    <#
      EFEITO (leitura de PATH/disco). Caminho executável do motor, ou $null.

      POR QUE NÃO BASTA `Get-Command` (defeito real, 2026-07-20): o onboarding instala o cliproxy
      num diretório VERSIONADO sob ~/.claude/tools/cliproxy/<versão>/ e NÃO o põe no PATH. O
      caminho de `-Login` já sabia disso e tinha um fallback próprio; o caminho de LANÇAMENTO não
      tinha — então o mesmo binário que o login encontrava, o launch declarava ausente. Os dois
      passaram a usar esta função, para não voltarem a divergir.
    #>
    param([Parameter(Mandatory)][hashtable]$EngineSpec)
    $cmd = [string]$EngineSpec['Command']
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) { return [string]$found.Source }

    # Fallback: instalação versionada do onboarding, fora do PATH. Só o cliproxy é instalado
    # assim hoje, mas a busca é genérica pelo nome do comando — nada aqui é específico dele.
    $toolsDir = Join-Path (Join-Path (Split-Path -Parent (Get-ClaudexHome)) 'tools') ([string]$EngineSpec['Engine'])
    if (-not (Test-Path -LiteralPath $toolsDir)) { return $null }
    $cand = Get-ChildItem -LiteralPath $toolsDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @($cmd, "$cmd.exe") } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($cand) { return [string]$cand.FullName }
    return $null
}

function Start-ClaudexProxy {
    # EFEITO. Sobe o motor tradutor como processo filho e espera a porta responder.
    # Devolve o objeto de processo. Falha (motor ausente, porta ocupada por outro, timeout)
    # -> throw: o chamador NUNCA lança o claude apontando p/ um proxy que não subiu.
    param(
        [Parameter(Mandatory)][hashtable]$EngineSpec,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$Port,
        [AllowEmptyString()][string]$UpstreamKey = '',
        # Chaves POR MODELO do catálogo: @{ CLAUDEX_KEY_GPT_5 = 'sk-...'; ... }. Cada uma vira
        # env var só do processo do motor (o YAML as referencia por os.environ/<nome>), nunca
        # arquivo, nunca linha de comando (que é visível no process list).
        [AllowNull()][System.Collections.IDictionary]$ModelKeys = $null,
        # Auth-dir do CLIProxyAPI. Vazio = motor sem credencial de arquivo (litellm) — nada a checar.
        [AllowEmptyString()][string]$AuthDir = '',
        [int]$TimeoutSec = 30
    )
    $cmd = Resolve-ClaudexEngineCommand -EngineSpec $EngineSpec
    if (-not $cmd) {
        throw "motor '$($EngineSpec['Engine'])' não encontrado ('$($EngineSpec['Command'])' não está no PATH nem em ~/.claude/tools). Instale com: $($EngineSpec['InstallHint'])"
    }
    # TERCEIRA PORTA do cloaking. As duas primeiras (config gerada + schema do perfil) não bastam:
    # no fonte pinado v7.2.91 os atributos da credencial têm precedência SOBRE
    # `disable-claude-cloak-mode`, então um cloak_* plantado no auth-dir religa o disfarce e a
    # nossa config continua parecendo correta. Barramos ANTES de subir o motor — deixar subir
    # seria afirmar "cloaking desligado" enquanto ele está ligado.
    $sujos = @(Get-ClaudexAuthCloakOverride -AuthDir $AuthDir)
    if ($sujos.Count -gt 0) {
        $det = ($sujos | ForEach-Object { "$($_.File) ($($_.Keys -join ', '))" }) -join '; '
        throw "credencial no auth-dir tenta RELIGAR cloaking e tem precedência sobre 'disable-claude-cloak-mode'. Remova as chaves cloak_* de: $det"
    }
    if (Test-ClaudexPortOpen -Port $Port) {
        throw "porta $Port já está em uso — outro proxy vivo? Encerre-o ou mude Port no perfil."
    }

    $argv = @()
    foreach ($a in @($EngineSpec['ArgsPattern'])) {
        $argv += ($a -replace '\{config\}', $ConfigPath -replace '\{port\}', [string]$Port)
    }

    # A chave upstream do LiteLLM viaja por env var só deste processo filho (os.environ/...),
    # nunca pelo arquivo de config nem pela linha de comando (que é visível no process list).
    # Env do processo do motor: a chave upstream (quando o motor a lê de env) + os ajustes
    # fixos do motor (EnvExtra — ex.: PYTHONIOENCODING p/ o litellm não crashar no Windows).
    # Tudo é setado no NOSSO processo só até o spawn (o filho herda) e revertido em seguida.
    $toSet = @{}
    if ($EngineSpec.Contains('EnvExtra') -and $EngineSpec['EnvExtra'] -is [System.Collections.IDictionary]) {
        foreach ($k in $EngineSpec['EnvExtra'].Keys) { $toSet[[string]$k] = [string]$EngineSpec['EnvExtra'][$k] }
    }
    $envName = [string]$EngineSpec['SecretViaEnv']
    if (-not [string]::IsNullOrWhiteSpace($envName) -and -not [string]::IsNullOrWhiteSpace($UpstreamKey)) {
        $toSet[$envName] = $UpstreamKey
    }
    if ($null -ne $ModelKeys) {
        foreach ($k in $ModelKeys.Keys) { $toSet[[string]$k] = [string]$ModelKeys[$k] }
    }

    $saved = @{}
    try {
        foreach ($k in $toSet.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
            [Environment]::SetEnvironmentVariable($k, $toSet[$k], 'Process')
        }
        # -PassThru p/ poder matar no finally; sem -Wait (o proxy fica vivo junto do claude).
        # -WindowStyle Hidden mantém o console livre p/ a TUI do claude.
        $proc = Start-Process -FilePath $cmd -ArgumentList $argv -PassThru -WindowStyle Hidden
    }
    finally {
        # Tira a chave do NOSSO ambiente assim que o filho já a herdou no spawn.
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }

    if (-not (Wait-ClaudexProxyReady -Port $Port -TimeoutSec $TimeoutSec)) {
        # Best-effort: se o motor já morreu sozinho, matar falha — e tudo bem, o throw abaixo
        # é a informação que importa. -Verbose expõe a causa quando se está depurando.
        try { if (-not $proc.HasExited) { $proc.Kill() } }
        catch { Write-Verbose "claudex: falha ao matar o motor após timeout — $($_.Exception.Message)" }
        throw "o motor '$($EngineSpec['Engine'])' não abriu a porta $Port em ${TimeoutSec}s — abortado (o claude NÃO foi lançado)."
    }
    return $proc
}

function New-ClaudexRuntimeDir {
    # EFEITO. Cria o dir efêmero onde a config gerada do motor vive durante o lançamento.
    # No Windows, restringe a ACL ao usuário atual (herança removida) — a config do cliproxy
    # carrega a chave upstream em texto. O dir é apagado no finally do launch.
    param([string]$Root = '')
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Join-Path (Get-ClaudexHome) 'run' }
    $dir = Join-Path $Root ([guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop

    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    if ($onWindows) {
        # /inheritance:r remove as ACEs herdadas; /grant:r concede só ao usuário atual.
        $me = "$env:USERDOMAIN\$env:USERNAME"
        $null = & icacls $dir /inheritance:r /grant:r "${me}:(OI)(CI)F" 2>&1
    }
    return $dir
}

function Remove-ClaudexRuntimeDir {
    # EFEITO. Apaga o dir efêmero. Tolerante: ausente/em uso não vira erro do lançamento.
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # Best-effort de propósito: um dir de runtime que não apagou (arquivo ainda travado pelo
    # motor saindo) NÃO pode virar erro do lançamento — o claude já rodou e o exit code dele
    # é o que interessa. Fica visível com -Verbose se alguém suspeitar de lixo acumulando.
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    catch { Write-Verbose "claudex: não removi o dir de runtime '$Path' — $($_.Exception.Message)" }
}

function Stop-ClaudexProxy {
    # EFEITO. Derruba o proxy. Tolerante: já morto / nunca subiu não é erro.
    param([AllowNull()]$Process)
    if ($null -eq $Process) { return }
    # Tolerante: chamado sempre no finally do lançamento, inclusive quando o motor nunca subiu
    # ou já morreu. Falhar aqui mascararia o exit code real do claude.
    try { if (-not $Process.HasExited) { $Process.Kill(); $null = $Process.WaitForExit(5000) } }
    catch { Write-Verbose "claudex: falha ao derrubar o motor — $($_.Exception.Message)" }
}

# --- Montagem das env vars (PURA) --------------------------------------------------------
function Get-ClaudexEnvForProfile {
    # Traduz um perfil + token resolvido no conjunto de env vars a setar no processo filho.
    #   Backend 'none'   -> @{} (passthrough puro)
    #   Backend 'direct' -> ANTHROPIC_AUTH_TOKEN (sempre), ANTHROPIC_BASE_URL (se BaseUrl),
    #                        ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL (se Models os definir)
    #   Backend 'proxy'  -> ANTHROPIC_BASE_URL = 127.0.0.1:<porta do motor local>,
    #                        ANTHROPIC_AUTH_TOKEN = chave EFÊMERA do gateway local (-LocalKey;
    #                        a chave do provider upstream NÃO passa por aqui — ela vai só p/ o
    #                        motor, via env própria ou config de ACL restrita), + os *_MODEL.
    #
    # É o mapeamento dos *_MODEL que faz os 3 slots do picker (`/model`) apontarem p/ os
    # modelos do perfil: escolher "Sonnet" na lista passa a rotear p/ Models.Sonnet. Modelos
    # em Models.Extra não entram no picker (a lista é built-in e não é extensível), mas são
    # chamáveis digitando `/model <nome>`.
    #
    # PURA: não lê disco/env; recebe token e chave já resolvidos. Devolve [ordered] hashtable.
    param(
        [Parameter(Mandatory)][hashtable]$ProfileObj,
        [string]$Token = '',
        [string]$LocalKey = '',
        [int]$Port = 0
    )
    $envMap = [ordered]@{}
    $backend = if ($ProfileObj.ContainsKey('Backend')) { [string]$ProfileObj['Backend'] } else { '' }
    if ($backend -notin @('direct', 'proxy')) { return $envMap }

    # Marcador informativo (não é auth, não é segredo): diz ao /models QUAL perfil está vivo
    # nesta sessão. Sem isto, um command rodando dentro do claude não teria como saber — as
    # env vars da Anthropic dizem os MODELOS, não o nome do perfil que os escolheu.
    $envMap['CLAUDEX_PROFILE'] = [string]$ProfileObj['Name']

    if ($backend -eq 'proxy') {
        if ([string]::IsNullOrWhiteSpace($LocalKey)) {
            throw "perfil '$($ProfileObj['Name'])': Backend 'proxy' sem LocalKey — não seto auth vazio"
        }
        if ($Port -le 0) {
            throw "perfil '$($ProfileObj['Name'])': Backend 'proxy' sem porta resolvida"
        }
        $envMap['ANTHROPIC_AUTH_TOKEN'] = $LocalKey
        $envMap['ANTHROPIC_BASE_URL']   = "http://127.0.0.1:$Port"

        # Prompt caching DESLIGADO por default no 'proxy' — MEDIDO em 2026-07-19, e o modo de
        # falha justifica o default: o Claude Code manda blocos `cache_control` no system
        # prompt; o motor traduz isso p/ a API de conteúdo cacheado do provider; e o Gemini
        # free tier tem `TotalCachedContentStorageTokensPerModelFreeTier limit=0`. Resultado
        # medido: 429 -> o motor devolve 500 -> o claude RETENTA em silêncio e a sessão fica
        # PENDURADA, sem erro na tela. Provado isolado: mesmo payload, mesmo tamanho, só o
        # `cache_control` mudando -> com ele 429, sem ele 'OK'/end_turn.
        # Perder caching custa latência/dinheiro; um hang mudo custa a sessão inteira — por
        # isso o default é seguro, não ótimo. Quem tem tier pago (onde o caching funciona)
        # liga de volta com `PromptCaching = $true` no perfil.
        $caching = $false
        if ($ProfileObj.ContainsKey('PromptCaching')) { $caching = [bool]$ProfileObj['PromptCaching'] }
        if (-not $caching) { $envMap['DISABLE_PROMPT_CACHING'] = '1' }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Token)) {
            throw "perfil '$($ProfileObj['Name'])': Backend 'direct' sem token resolvido — não seto auth vazio"
        }
        $envMap['ANTHROPIC_AUTH_TOKEN'] = $Token

        $baseUrl = if ($ProfileObj.ContainsKey('BaseUrl')) { [string]$ProfileObj['BaseUrl'] } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($baseUrl)) { $envMap['ANTHROPIC_BASE_URL'] = $baseUrl }
    }

    # Slots = ATALHOS do picker, não o mecanismo. Slot ausente = não remapeia aquele slot
    # (o modelo Anthropic original passa direto, e o catálogo pode ter uma entrada 'anthropic'
    # justamente p/ atendê-lo). O acesso pleno ao catálogo é por `/model <nome>`.
    $map = Get-ClaudexSlotName
    foreach ($kv in (Get-ClaudexSlots -ProfileObj $ProfileObj).GetEnumerator()) {
        $envMap[$map[$kv.Key]] = [string]$kv.Value
    }

    # MODELO INICIAL DA SESSÃO (`DefaultModel` no perfil -> ANTHROPIC_MODEL).
    #
    # POR QUE ISTO IMPORTA MAIS QUE OS SLOTS: o picker do `/model` é built-in e tem um número
    # FIXO de linhas (Default / Opus / Sonnet / Haiku / Fable / opusplan) — não dá para listar
    # 10 modelos nele, e os nomes das linhas passam a mentir sob um catálogo remapeado ("Opus"
    # que na verdade é um qwen local). Em vez de brigar com o picker, esta env diz em qual
    # modelo do catálogo a sessão ABRE. Assim o caminho comum deixa de passar pelo picker:
    # `claudex` já entra no modelo certo, e `/model <nome>` alcança o resto do catálogo.
    # (Doc oficial: `ANTHROPIC_MODEL` aceita alias OU nome de modelo e vale para a sessão que
    # você lança. Sob 'proxy' o nome chega ao motor verbatim, como o resto do catálogo.)
    if ($ProfileObj.ContainsKey('DefaultModel')) {
        $dm = [string]$ProfileObj['DefaultModel']
        if (-not [string]::IsNullOrWhiteSpace($dm)) { $envMap['ANTHROPIC_MODEL'] = $dm }
    }
    return $envMap
}

# --- Lançamento do claude com env escopado ao filho --------------------------------------
function Invoke-ClaudexLaunch {
    # EFEITO: seta as env vars, lança o claude e RESTAURA o env do processo ao final (mesmo em
    # erro — try/finally). O restore devolve cada var ao valor anterior ($null = remove), então
    # o shell pai NÃO fica com as vars setadas depois — é o ponto central do design. O filho
    # (claude) herda as vars no spawn.
    #
    # BUG REAL CORRIGIDO (achado em uso real, 2026-07-19): esta função NÃO deve ter seu retorno
    # capturado pelo chamador (nunca `$x = Invoke-ClaudexLaunch ...`). Capturar o retorno de uma
    # função em PowerShell obriga o engine a redirecionar TODO o stream de saída produzido lá
    # dentro — inclusive o stdout do processo nativo `& $ClaudeCommand` — para um pipe interno em
    # vez do console real. O Claude Code detecta que seu próprio stdout não é um TTY e cai sozinho
    # em modo headless (`--print`), que passa a exigir prompt via stdin — o erro "Input must be
    # provided either through stdin..." que aparecia mesmo numa sessão interativa normal. Por isso
    # esta função NÃO retorna o exit code mais: o chamador (claudex.ps1) invoca-a como statement
    # solto (sem atribuição) e lê $LASTEXITCODE depois — essa variável é global ao engine, não
    # precisa ser "retornada" por ninguém.
    param(
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$EnvVars,
        [string[]]$ClaudeArgs = @(),
        [string]$ClaudeCommand = 'claude'
    )
    $vars = if ($null -eq $EnvVars) { @{} } else { $EnvVars }
    $saved = @{}
    try {
        foreach ($k in $vars.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')  # pode ser $null
            [Environment]::SetEnvironmentVariable($k, [string]$vars[$k], 'Process')
        }
        # Statement solto de propósito — NÃO capturar/retornar (ver nota acima). $LASTEXITCODE
        # fica setado globalmente para o chamador ler depois de sair deste try/finally.
        & $ClaudeCommand @ClaudeArgs
    }
    finally {
        foreach ($k in $vars.Keys) {
            [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')  # $null remove a var
        }
    }
}

# --- Saídas legíveis (PURAS) -------------------------------------------------------------
function Format-ClaudexList {
    # -List: uma linha por perfil (Name — Backend [SecretRef]). Sem segredos (só a referência).
    param([AllowNull()]$Profiles)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Perfis claudex:')
    foreach ($p in @($Profiles)) {
        $name    = [string]$p['Name']
        $backend = if ($p.ContainsKey('Backend')) { [string]$p['Backend'] } else { '?' }
        $extra   = ''
        if ($backend -eq 'direct') {
            $ref = if ($p.ContainsKey('SecretRef')) { [string]$p['SecretRef'] } else { '(sem SecretRef)' }
            $url = if ($p.ContainsKey('BaseUrl') -and -not [string]::IsNullOrWhiteSpace([string]$p['BaseUrl'])) { " · $($p['BaseUrl'])" } else { '' }
            $extra = " · $ref$url"
        }
        elseif ($backend -eq 'proxy') {
            $eng  = if ($p.ContainsKey('Engine')) { [string]$p['Engine'] } else { '?' }
            $port = try { Get-ClaudexEnginePort -ProfileObj $p } catch { '?' }
            $extra = " · $eng · :$port"
            if (Test-ClaudexNeedsSidecar -ProfileObj $p) {
                $sp = try { Get-ClaudexSidecarPort -ProfileObj $p } catch { '?' }
                $extra += " (+cliproxy :$sp p/ OAuth)"
            }
            # Os modelos são a informação útil aqui: é o que dá p/ escolher no /model. O catálogo
            # é a fonte — Get-ClaudexProfileModelList só enxerga a forma simples (Models), então
            # um perfil no formato `Catalog` aparecia sem modelo NENHUM na listagem.
            $mdl = @(Get-ClaudexCatalog -ProfileObj $p | ForEach-Object { [string]$_['Name'] })
            if ($mdl.Count -gt 0) { $extra += " · $($mdl -join ', ')" }
        }
        $marca = if ($p.ContainsKey('Default') -and [bool]$p['Default']) { ' (default)' } else { '' }
        $lines.Add("  - $name [$backend]$marca$extra")
    }
    return ($lines -join [Environment]::NewLine)
}

function Format-ClaudexModelsReport {
    <#
      PURA. Relatório COMPLETO da sessão para o command `/models`, em uma chamada só.

      POR QUE EXISTE (2026-07-20): o `/models` mandava o agente rodar 4 leituras de env, um
      dot-source, um Import-PowerShellDataFile e mais duas funções — 6+ round-trips de shell
      para montar uma tabela, cada um com o custo de aprovação e latência. Pior: cada agente
      remontava a tabela do seu jeito, então a mesma pergunta dava saídas diferentes. Agora a
      normalização vive AQUI (testável), e o command só imprime o que esta função devolveu.

      Recebe o estado da sessão já lido (por isso continua pura): o nome do perfil ativo e o
      valor das envs de slot. Devolve texto pronto para exibir.
    #>
    param(
        [AllowNull()]$Profiles,
        [AllowEmptyString()][string]$ActiveProfile = '',
        # As envs de slot COMO ESTÃO na sessão — a verdade do que o Claude Code vai resolver,
        # que pode divergir do perfil se alguém setou env na mão.
        [AllowNull()][System.Collections.IDictionary]$SlotEnv = $null,
        [AllowEmptyString()][string]$SessionModel = ''
    )
    $sb = [System.Text.StringBuilder]::new()

    if ([string]::IsNullOrWhiteSpace($ActiveProfile)) {
        [void]$sb.AppendLine('Sessão SEM perfil claudex (passthrough Anthropic puro).')
        [void]$sb.AppendLine('Os slots do /model apontam para os modelos reais da Anthropic — o que o picker mostra é a verdade.')
        $def = Get-ClaudexDefaultProfileName -Profiles $Profiles
        if ($def -ne 'claude') {
            [void]$sb.AppendLine("Para abrir com o catálogo completo: saia e rode ``claudex`` (perfil default: '$def').")
        }
        return $sb.ToString().TrimEnd()
    }

    # Perfil ausente não é exceção a propagar: é um estado que o relatório SABE descrever (o
    # usuário renomeou/removeu o perfil depois de lançar a sessão). A mensagem vem logo abaixo.
    $prof = $null
    try { $prof = Get-ClaudexProfile -Profiles $Profiles -Name $ActiveProfile }
    catch { Write-Verbose "claudex: perfil '$ActiveProfile' não está mais no profiles.psd1 — $($_.Exception.Message)" }
    if ($null -eq $prof) {
        return "Perfil ativo '$ActiveProfile' não existe mais no profiles.psd1 (foi renomeado/removido depois do lançamento?)."
    }

    $catalog = @(Get-ClaudexCatalog -ProfileObj $prof)
    $slots   = Get-ClaudexSlots -ProfileObj $prof
    # Slot -> lista de modelos que o apontam (invertido, p/ marcar cada linha do catálogo).
    $porModelo = @{}
    foreach ($kv in $slots.GetEnumerator()) {
        $v = [string]$kv.Value
        if (-not $porModelo.ContainsKey($v)) { $porModelo[$v] = @() }
        $porModelo[$v] += [string]$kv.Key
    }
    $inicial = if (-not [string]::IsNullOrWhiteSpace($SessionModel)) { $SessionModel }
               elseif ($prof.ContainsKey('DefaultModel')) { [string]$prof['DefaultModel'] } else { '' }

    [void]$sb.AppendLine("Perfil ativo: $ActiveProfile · $($catalog.Count) modelo(s) no catálogo")
    if (-not [string]::IsNullOrWhiteSpace($inicial)) {
        [void]$sb.AppendLine("Modelo inicial da sessão: $inicial")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Como chamar | Origem | Atalho no picker | O que é |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($e in $catalog) {
        $nome = [string]$e['Name']
        $prov = [string]$e['Provider']
        # A origem é o que muda a DECISÃO do usuário: cota de assinatura, crédito de API ou
        # nada (local). Provider cru ('oauth', 'ollama_chat') não comunica isso.
        $origem = switch -Regex ($prov) {
            '^oauth$'   { 'assinatura (sem custo de API)' }
            '^ollama'   { 'local (offline, sem custo)' }
            default     { "API: $prov" }
        }
        $atalho = if ($porModelo.ContainsKey($nome)) { ($porModelo[$nome] | Sort-Object) -join ', ' } else { '—' }
        $notas  = [string]$e['Notes']   # vazio fica vazio: NÃO inventar descrição
        $marca  = if ($nome -eq $inicial) { ' **(inicial)**' } else { '' }
        [void]$sb.AppendLine("| ``/model $nome``$marca | $origem | $atalho | $notas |")
    }

    # Slot declarado no perfil mas divergente do que a sessão realmente tem: acontece quando o
    # perfil foi editado DEPOIS do lançamento (as envs são lidas no start). Silenciar isso faria
    # o relatório descrever um perfil que não é o que está rodando.
    if ($null -ne $SlotEnv) {
        $divergencias = [System.Collections.Generic.List[string]]::new()
        foreach ($kv in (Get-ClaudexSlotName).GetEnumerator()) {
            $doPerfil  = if ($slots.Contains($kv.Key)) { [string]$slots[$kv.Key] } else { '' }
            $daSessao  = if ($SlotEnv.Contains($kv.Value)) { [string]$SlotEnv[$kv.Value] } else { '' }
            if ($doPerfil -ne $daSessao) {
                $a = if ($doPerfil) { $doPerfil } else { '(não declarado)' }
                $b = if ($daSessao) { $daSessao } else { '(vazio)' }
                $divergencias.Add("$($kv.Key): perfil diz '$a', sessão tem '$b'")
            }
        }
        if ($divergencias.Count -gt 0) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('ATENÇÃO — o perfil no disco não bate com esta sessão (editado depois do lançamento?):')
            foreach ($d in $divergencias) { [void]$sb.AppendLine("  - $d") }
            [void]$sb.AppendLine('  As env vars são lidas no START do processo: relance o claudex para valer.')
        }
    }

    # Slot vazio sob 'proxy' é DEFEITO, não neutralidade — medido: vira 400 'Invalid model name'.
    $backend = if ($prof.ContainsKey('Backend')) { [string]$prof['Backend'] } else { '' }
    if ($backend -eq 'proxy') {
        $vazios = @(@(Get-ClaudexSlotName).Keys | Where-Object { -not $slots.Contains($_) })
        if ($vazios.Count -gt 0) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("Slots SEM mapeamento: $($vazios -join ', ') — sob 'proxy' escolher um deles no picker manda o ID Anthropic embutido ao motor local, que responde 400 'Invalid model name'. Use ``/model <nome>`` da tabela.")
        }
    }
    return $sb.ToString().TrimEnd()
}

function Format-ClaudexDoctorLine {
    # -Check: uma linha de diagnóstico por perfil, SEM imprimir segredo. Diz se o backend é
    # suportado nesta fase e (p/ 'direct') se o segredo resolve.
    param(
        [Parameter(Mandatory)][hashtable]$ProfileObj,
        [Parameter(Mandatory)][bool]$SecretResolves,
        [bool]$EnginePresent = $false,
        # Nome da entrada do catálogo -> o SecretRef dela resolve? Vazio = ninguém perguntou.
        # Existe porque no formato `Catalog` a credencial é POR MODELO: olhar só o SecretRef do
        # nível do perfil faz o doctor dizer "sem SecretRef" p/ um perfil cheio de chaves.
        [hashtable]$CatalogSecrets = @{},
        # Credenciais de login achadas no auth-dir. -1 = ninguém perguntou (perfil sem OAuth).
        [int]$OAuthCredentials = -1
    )
    $name    = [string]$ProfileObj['Name']
    $backend = if ($ProfileObj.ContainsKey('Backend')) { [string]$ProfileObj['Backend'] } else { '?' }
    if (-not (Test-ClaudexBackendSupported -Backend $backend)) {
        return "  [x] $name [$backend] — backend não suportado (só none/direct/proxy)"
    }
    if ($backend -eq 'none') { return "  [ok] $name [none] — passthrough (sem segredo)" }

    if ($backend -eq 'proxy') {
        $eng  = if ($ProfileObj.ContainsKey('Engine')) { [string]$ProfileObj['Engine'] } else { '?' }
        $spec = Get-ClaudexEngineSpec -Engine $eng
        if ($null -eq $spec) { return "  [x] $name [proxy] — motor '$eng' desconhecido (litellm | cliproxy)" }
        if (-not $EnginePresent) {
            return "  [x] $name [proxy/$eng] — motor ausente no PATH. Instale: $($spec['InstallHint'])"
        }
        # Perfil com entrada OAuth depende de um login que pode simplesmente nunca ter sido feito.
        # Isso precisa aparecer ANTES do veredito sobre chaves: um catálogo com todas as chaves
        # resolvendo e zero credencial no auth-dir não é um perfil saudável.
        if ($OAuthCredentials -eq 0) {
            return "  [x] $name [proxy/$eng] — modelos OAuth no catálogo, mas nenhuma credencial no auth-dir. Rode: claudex -Login claude (ou codex | gemini | kimi | xai)"
        }
        $oauthNota = if ($OAuthCredentials -gt 0) { " · $OAuthCredentials login(s) OAuth + cliproxy interno" } else { '' }
        # A credencial pode estar POR MODELO (formato `Catalog`) — e nesse caso o SecretRef do
        # nível do perfil está vazio sem que isso signifique "provider sem chave". Reportar por
        # entrada é o único jeito de o -Check ser honesto aqui: um perfil com 3 modelos e 1
        # chave quebrada precisa aparecer como quebrado, não como [ok].
        $comChave = @($CatalogSecrets.Keys)
        if ($comChave.Count -gt 0) {
            $ruins = @($comChave | Where-Object { -not [bool]$CatalogSecrets[$_] } | Sort-Object)
            if ($ruins.Count -gt 0) {
                return "  [x] $name [proxy/$eng] — motor presente · segredo NÃO resolve em: $($ruins -join ', ')"
            }
            $warn = if ($eng -eq 'cliproxy') { ' · sidecar OAuth validado ao vivo (v7.2.91)' } else { '' }
            return "  [ok] $name [proxy/$eng] — motor presente · $($comChave.Count) segredo(s) por modelo resolvem$oauthNota$warn"
        }
        # Sem SecretRef é legítimo, mas por motivos DIFERENTES em cada motor — não misture:
        #   cliproxy -> credencial de OAuth vive no auth-dir (o usuário logou pelo binário);
        #   litellm  -> provider que simplesmente não pede chave (Ollama e afins, local).
        $ref = if ($ProfileObj.ContainsKey('SecretRef')) { [string]$ProfileObj['SecretRef'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($ref)) {
            $porque = if ($eng -eq 'cliproxy') { 'login OAuth no auth-dir do motor' }
                      else { 'provider sem chave (ex.: modelo local)' }
            return "  [ok] $name [proxy/$eng] — motor presente · sem SecretRef ($porque)$oauthNota"
        }
        if (-not $SecretResolves) { return "  [x] $name [proxy/$eng] — segredo upstream NÃO resolve ($ref)" }
        $warn = if ($eng -eq 'cliproxy') { ' · sidecar OAuth validado ao vivo (v7.2.91)' } else { '' }
        return "  [ok] $name [proxy/$eng] — motor presente · segredo resolve ($ref)$warn"
    }

    $ref = if ($ProfileObj.ContainsKey('SecretRef')) { [string]$ProfileObj['SecretRef'] } else { '(sem SecretRef)' }
    if ($SecretResolves) { return "  [ok] $name [direct] — segredo resolve ($ref)" }
    return "  [x] $name [direct] — segredo NÃO resolve ($ref)"
}
