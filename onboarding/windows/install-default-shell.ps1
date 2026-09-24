# install-default-shell.ps1 — define o PowerShell 7 (pwsh) como perfil PADRÃO do Windows Terminal
# e como shell dos panes do herdr (bloco no fim do arquivo).
# Passo OPT-IN (-SetDefaultShell) e NÃO bloqueante: qualquer falha vira WARN, nunca Failed.
# Requer que lib.ps1 já esteja carregado (Write-Step, Backup-File).
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.
#
# POR QUE ISTO EXISTE: o instalador já instala o PowerShell 7 (A1), mas instalar != usar. O Windows
# Terminal continua abrindo o "Windows PowerShell" (5.1) por padrão, então o usuário digita `nsp` e
# cai justamente no runtime que NÃO é suportado (ver a guarda de relaunch em new-project.ps1, e o bug
# do manifest na v0.8.28: o projeto nascia sem baseline). Trocar o defaultProfile fecha essa porta.
#
# O QUE ESTE PASSO NÃO FAZ, DE PROPÓSITO — associação de .ps1 (decisão 2026-07-17):
# Foi pedido "associar .ps1 ao pwsh" junto com isto. NÃO implementado, e a razão é de segurança, não
# de esforço: o Windows associa .ps1 ao Notepad DELIBERADAMENTE, para que dar duplo-clique num script
# baixado ABRA o arquivo em vez de EXECUTÁ-LO. Trocar o verbo 'Open' de .ps1 para o pwsh transformaria
# todo .ps1 do disco (inclusive um anexo de e-mail recém-baixado) em um duplo-clique de execução — é
# um vetor clássico de malware, vale para a máquina inteira e não só para este projeto.
# Isso colide com a política do repo ("segurança fica intacta": os guards são o que NÃO afrouxa).
# Para REABRIR com segurança seria preciso: (a) escopo por usuário (HKCU\Software\Classes), (b) manter
# 'Open' = editor e mexer só num verbo novo/explícito, (c) desfazer documentado. Ver features/BACKLOG.md.

Set-StrictMode -Version Latest

function Get-WindowsTerminalSettingsPath {
    # EFEITO (leve): resolve o settings.json do Windows Terminal. Cobre o pacote da Store (estável) e
    # o Preview; devolve o 1º que existir, ou $null. Parametrizável p/ testes via -LocalAppData.
    param([string]$LocalAppData = $env:LOCALAPPDATA)
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { return $null }
    $candidatos = @(
        'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json',
        'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
    )
    foreach ($rel in $candidatos) {
        $p = Join-Path $LocalAppData $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Find-PwshTerminalProfileGuid {
    # PURA. Acha o GUID do perfil do PowerShell 7 no objeto de settings já desserializado.
    # Dois sinais, nesta ordem:
    #   1. source = 'Windows.Terminal.PowershellCore' — o perfil que o próprio WT gera ao detectar o
    #      pwsh. É o caso normal e o mais confiável (não depende de nome, que é localizado).
    #   2. commandline apontando para pwsh.exe — cobre o perfil escrito à mão.
    # NÃO casa por Name: 'PowerShell' vs 'Windows PowerShell' difere por uma palavra, e o nome muda com
    # o idioma do sistema — casar por nome erraria o alvo e trocaria o default para o runtime ERRADO.
    param([Parameter(Mandatory)][AllowNull()]$Settings)

    if (-not $Settings) { return $null }
    $profilesProp = $Settings.PSObject.Properties['profiles']
    if (-not $profilesProp -or -not $profilesProp.Value) { return $null }
    $listProp = $profilesProp.Value.PSObject.Properties['list']
    if (-not $listProp -or -not $listProp.Value) { return $null }

    $lista = @($listProp.Value)

    foreach ($p in $lista) {
        $src = $p.PSObject.Properties['source']
        if ($src -and $src.Value -eq 'Windows.Terminal.PowershellCore') {
            $g = $p.PSObject.Properties['guid']
            if ($g -and $g.Value) { return [string]$g.Value }
        }
    }
    foreach ($p in $lista) {
        $cmd = $p.PSObject.Properties['commandline']
        if ($cmd -and $cmd.Value -match 'pwsh(\.exe)?\b') {
            $g = $p.PSObject.Properties['guid']
            if ($g -and $g.Value) { return [string]$g.Value }
        }
    }
    return $null
}

function Set-TerminalDefaultProfileText {
    # PURA. Troca o valor de "defaultProfile" no TEXTO do settings.json e devolve o texto novo.
    #
    # POR QUE TEXTO E NÃO ConvertTo-Json: o settings.json é do USUÁRIO — tem comentários (JSONC),
    # ordem e formatação próprias. Reserializar devolveria um arquivo "equivalente" e ILEGÍVEL, com os
    # comentários APAGADOS. Substituição cirúrgica preserva tudo e só toca no que precisa mudar.
    # Sem a chave presente, devolve o texto INTACTO (o chamador trata) — em vez de inventar posição
    # para inserir e arriscar um JSON quebrado no arquivo do usuário.
    # $Guid É usado — dentro do scriptblock passado a [regex]::Replace (última linha). O
    # PSReviewUnusedParameter não rastreia uso em scriptblock-argumento; falso positivo, suprimido.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = '$Guid usado no scriptblock de [regex]::Replace — PSSA não o rastreia')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Guid
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # "defaultProfile"<espaços>:<espaços>"<qualquer coisa que não seja aspa>"
    $padrao = '("defaultProfile"\s*:\s*)"[^"]*"'
    if (-not [regex]::IsMatch($Text, $padrao)) { return $Text }
    return [regex]::Replace($Text, $padrao, { param($m) $m.Groups[1].Value + '"' + $Guid + '"' }, 1)
}

function Get-DefaultShellPlan {
    # PURA. Decide o que fazer, a partir de fatos já coletados.
    #   Action: 'set'      -> trocar o defaultProfile
    #           'skip'     -> já é o pwsh
    #           'no-wt'    -> Windows Terminal não instalado (nada a fazer, não é erro)
    #           'no-pwsh'  -> WT instalado, mas sem perfil do pwsh (o WT ainda não o detectou)
    #           'no-key'   -> settings sem a chave defaultProfile (não mexer às cegas)
    param(
        [Parameter(Mandatory)][bool]$SettingsFound,
        [AllowNull()][string]$PwshGuid,
        [AllowNull()][string]$CurrentGuid,
        [Parameter(Mandatory)][bool]$HasDefaultKey
    )
    if (-not $SettingsFound)              { return 'no-wt' }
    if ([string]::IsNullOrWhiteSpace($PwshGuid)) { return 'no-pwsh' }
    if (-not $HasDefaultKey)              { return 'no-key' }
    if ($CurrentGuid -eq $PwshGuid)       { return 'skip' }
    return 'set'
}

function Invoke-DefaultShellSetup {
    # Executa o plano (wrapper com efeito). Nunca lança; falha = WARN. Faz backup antes de escrever.
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [string]$SettingsPath = (Get-WindowsTerminalSettingsPath),
        [switch]$Check,
        [switch]$DryRun
    )

    $found = -not [string]::IsNullOrWhiteSpace($SettingsPath)
    $texto = ''
    $obj = $null
    if ($found) {
        try {
            $texto = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop
            $obj = $texto | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Step WARN "shell padrão: não consegui ler o settings.json do Windows Terminal — $($_.Exception.Message)"
            $Summary.Warn++
            return
        }
    }

    $pwshGuid = Find-PwshTerminalProfileGuid -Settings $obj
    $atualProp = if ($obj) { $obj.PSObject.Properties['defaultProfile'] } else { $null }
    $atual = if ($atualProp) { [string]$atualProp.Value } else { $null }

    $plano = Get-DefaultShellPlan -SettingsFound $found -PwshGuid $pwshGuid -CurrentGuid $atual `
        -HasDefaultKey ([bool]$atualProp)

    switch ($plano) {
        'no-wt' {
            Write-Step SKIP 'shell padrão: Windows Terminal não encontrado — nada a fazer'
            $Summary.Skipped++
        }
        'no-pwsh' {
            Write-Step WARN 'shell padrão: o Windows Terminal ainda não tem perfil do PowerShell 7 — abra-o uma vez após instalar o pwsh e rode de novo'
            $Summary.Warn++
        }
        'no-key' {
            Write-Step WARN 'shell padrão: settings.json sem "defaultProfile" — não vou inseri-lo às cegas; defina o perfil padrão pela UI do Windows Terminal'
            $Summary.Warn++
        }
        'skip' {
            Write-Step SKIP 'shell padrão: o PowerShell 7 já é o perfil padrão do Windows Terminal'
            $Summary.Skipped++
        }
        'set' {
            if ($Check)  { Write-Step INFO "shell padrão: trocaria o perfil padrão do Windows Terminal para o PowerShell 7 ($pwshGuid)"; return }
            if ($DryRun) { Write-Step DRY  "defaultProfile -> $pwshGuid em $SettingsPath"; return }
            try {
                $novo = Set-TerminalDefaultProfileText -Text $texto -Guid $pwshGuid
                if ($novo -eq $texto) {
                    Write-Step WARN 'shell padrão: não consegui localizar a chave "defaultProfile" para trocar — nada foi escrito'
                    $Summary.Warn++
                    return
                }
                $bak = Backup-File -Path $SettingsPath
                if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
                # UTF-8 sem BOM: o Windows Terminal grava assim; manter o formato dele.
                [System.IO.File]::WriteAllText($SettingsPath, $novo, [System.Text.UTF8Encoding]::new($false))
                Write-Step OK 'shell padrão: PowerShell 7 agora é o perfil padrão do Windows Terminal (abra uma aba nova)'
                $Summary.Installed++
            }
            catch {
                Write-Step WARN "shell padrão: falha ao escrever — $($_.Exception.Message)"
                $Summary.Warn++
            }
        }
    }
}

# ============================================================================================
# Herdr: o shell dos PANES
# ============================================================================================
# POR QUE (uso real, 2026-09-15): o usuário abriu o pwsh 7, chamou o `herdr` e digitou `nsp` num
# pane — "nsp não é reconhecido". O pane NÃO herda o shell de quem chamou o herdr: com
# `default_shell` vazio o herdr usa $SHELL (que não existe no Windows) e cai no Windows PowerShell
# 5.1 (doc oficial do herdr 0.9.0, configuration.mdx; medido nos processos: todo pane era um
# powershell.exe filho do herdr). Trocar o perfil do Windows Terminal (acima) não alcança isso.
# O shim do nsp mora só no profile do pwsh 7 (Install-ProfileShim), e o 5.1 nasce com Execution
# Policy Restricted — um shim no profile do 5.1 nem carregaria. A correção é na ORIGEM: o herdr
# abrir o pwsh. `pwsh.exe` pelo NOME, não pelo caminho: o pwsh da Store mora numa pasta com a
# versão no nome (…\Microsoft.PowerShell_7.6.6.0_x64…), que muda a cada update. O próprio herdr.exe
# reconhece `pwsh.exe` na integração de prompt/cwd (strings de src\pane.rs, medido na 0.9.0).
$script:HerdrPwshShell = 'pwsh.exe'

function Get-HerdrConfigPath {
    # PURA (env injetável). Mesma ordem do herdr (src/config/io.rs + tabela de env vars da doc 0.9.0):
    # HERDR_CONFIG_PATH > XDG_CONFIG_HOME\herdr > APPDATA\herdr > USERPROFILE\AppData\Roaming\herdr.
    param(
        [string]$ConfigPathEnv = $env:HERDR_CONFIG_PATH,
        [string]$XdgConfigHome = $env:XDG_CONFIG_HOME,
        [string]$AppData       = $env:APPDATA,
        [string]$UserProfile   = $env:USERPROFILE
    )
    if (-not [string]::IsNullOrWhiteSpace($ConfigPathEnv)) { return $ConfigPathEnv }
    $base = if (-not [string]::IsNullOrWhiteSpace($XdgConfigHome)) { $XdgConfigHome }
            elseif (-not [string]::IsNullOrWhiteSpace($AppData)) { $AppData }
            elseif (-not [string]::IsNullOrWhiteSpace($UserProfile)) { Join-Path (Join-Path $UserProfile 'AppData') 'Roaming' }
            else { $null }
    if (-not $base) { return $null }
    return (Join-Path (Join-Path $base 'herdr') 'config.toml')
}

function Get-HerdrShellLeaf {
    # PURA. 'C:\…\pwsh.exe' -> 'pwsh'. Separa por \ E /: GetFileNameWithoutExtension só separa pelo
    # separador do SO, e no Linux (CI) um caminho Windows voltaria inteiro.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    return (([string]$Value -split '[\\/]')[-1] -replace '(?i)\.exe$', '')
}

function Set-HerdrDefaultShellText {
    # PURA. Decide e aplica, no TEXTO do config.toml, `[terminal] default_shell = "pwsh.exe"`.
    # Devolve { Action; Text; Current }:
    #   'set'      -> Text é o conteúdo novo (arquivo vazio, seção ausente, chave ausente ou vazia)
    #   'skip'     -> já é o pwsh (por nome ou caminho)
    #   'custom'   -> o usuário escolheu OUTRO shell: respeitado, Text intacto
    #   'no-touch' -> `terminal` definido numa forma que este editor não altera com segurança
    #                 (tabela inline ou chave pontuada na raiz) — Text intacto
    # POR QUE TEXTO: mesmo motivo do Set-TerminalDefaultProfileText — o arquivo é do usuário, com
    # comentários e ordem próprios; não há parser TOML no PowerShell, e reescrever tudo os perderia.
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$Shell = $script:HerdrPwshShell
    )
    $linhaNova = "default_shell = `"$Shell`""
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ Action = 'set'; Text = "[terminal]`r`n$linhaNova`r`n"; Current = $null }
    }
    $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
    $linhas = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ($Text -split "`r?`n")) { $linhas.Add($l) }

    $secao  = ''   # tabela corrente ('' = raiz)
    $header = -1   # índice da linha [terminal]
    for ($i = 0; $i -lt $linhas.Count; $i++) {
        $l = $linhas[$i]
        if ($l -match '^\s*\[\[') { $secao = '[[array]]'; continue }   # array de tabelas: não é [terminal]
        if ($l -match '^\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$') {
            $secao = $Matches[1]
            if ($secao -eq 'terminal') { $header = $i }
            continue
        }
        if ($secao -eq '' -and $l -match '^\s*terminal\s*[.=]') {
            return [pscustomobject]@{ Action = 'no-touch'; Text = $Text; Current = $null }
        }
        if ($secao -eq 'terminal' -and $l -match '^\s*default_shell\s*=\s*(.*)$') {
            $bruto = $Matches[1]
            $valor = if ($bruto -match '^"([^"]*)"') { $Matches[1] }
                     elseif ($bruto -match "^'([^']*)'") { $Matches[1] }
                     else { ($bruto -replace '#.*$', '').Trim() }
            if ([string]::IsNullOrWhiteSpace($valor)) {
                $linhas[$i] = $linhaNova
                return [pscustomobject]@{ Action = 'set'; Text = ($linhas -join $nl); Current = '' }
            }
            $acao = if ((Get-HerdrShellLeaf $valor) -ieq 'pwsh') { 'skip' } else { 'custom' }
            return [pscustomobject]@{ Action = $acao; Text = $Text; Current = $valor }
        }
    }

    if ($header -ge 0) {
        # Logo abaixo do cabeçalho: um `# default_shell = ""` comentado (o template do repo) fica onde está.
        $linhas.Insert($header + 1, $linhaNova)
        return [pscustomobject]@{ Action = 'set'; Text = ($linhas -join $nl); Current = $null }
    }
    $novo = $Text.TrimEnd("`r", "`n") + $nl + $nl + '[terminal]' + $nl + $linhaNova + $nl
    return [pscustomobject]@{ Action = 'set'; Text = $novo; Current = $null }
}

function Test-HerdrOnPath {
    # EFEITO leve (mockável): o herdr está no PATH? Sem ele e sem config, não há o que configurar.
    return [bool](Get-Command herdr -CommandType Application -ErrorAction SilentlyContinue)
}

function Invoke-HerdrReloadConfig {
    # EFEITO (mockável): recarrega o config no servidor em execução. $false sem herdr/servidor.
    $cmd = Get-Command herdr -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $false }
    try { & $cmd.Source server reload-config *> $null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

function Invoke-HerdrDefaultShellSetup {
    # Wrapper com efeito. Nunca lança; falha = WARN. Faz backup antes de escrever.
    # -HerdrInstalled: o chamador acabou de provisionar o herdr (-WithHerdr), que fica FORA do PATH —
    # sem isto o passo concluiria "herdr ausente" logo depois de instalá-lo.
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [AllowNull()][AllowEmptyString()][string]$ConfigPath = (Get-HerdrConfigPath),
        [switch]$HerdrInstalled,
        [switch]$Check,
        [switch]$DryRun
    )
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        Write-Step WARN 'shell do herdr: não consegui resolver o caminho do config.toml'
        $Summary.Warn++
        return
    }
    $existe = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    if (-not $existe -and -not $HerdrInstalled -and -not (Test-HerdrOnPath)) {
        Write-Step SKIP 'shell do herdr: herdr não encontrado — nada a fazer'
        $Summary.Skipped++
        return
    }
    $texto = ''
    if ($existe) {
        try { $texto = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop }
        catch {
            Write-Step WARN "shell do herdr: não consegui ler $ConfigPath — $($_.Exception.Message)"
            $Summary.Warn++
            return
        }
    }

    $r = Set-HerdrDefaultShellText -Text $texto
    switch ($r.Action) {
        'skip' {
            Write-Step SKIP 'shell do herdr: os panes já abrem no PowerShell 7'
            $Summary.Skipped++
        }
        'custom' {
            if ((Get-HerdrShellLeaf $r.Current) -ieq 'powershell') {
                Write-Step WARN "shell do herdr: default_shell = '$($r.Current)' (Windows PowerShell 5.1) — mantido por ser escolha sua, mas o nsp não existe nesses panes; troque para `"$script:HerdrPwshShell`""
                $Summary.Warn++
            }
            else {
                Write-Step SKIP "shell do herdr: default_shell = '$($r.Current)' — escolha sua, mantida"
                $Summary.Skipped++
            }
        }
        'no-touch' {
            Write-Step WARN "shell do herdr: [terminal] está numa forma que não edito com segurança — defina default_shell = `"$script:HerdrPwshShell`" à mão em $ConfigPath"
            $Summary.Warn++
        }
        'set' {
            if ($Check)  { Write-Step INFO "shell do herdr: definiria default_shell = `"$script:HerdrPwshShell`" (hoje os panes abrem no Windows PowerShell 5.1)"; return }
            if ($DryRun) { Write-Step DRY  "default_shell = `"$script:HerdrPwshShell`" em $ConfigPath"; return }
            try {
                if ($existe) {
                    $bak = Backup-File -Path $ConfigPath
                    if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
                }
                else {
                    $dir = Split-Path -Parent $ConfigPath
                    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                }
                # UTF-8 sem BOM: TOML é UTF-8 e um BOM no começo não é garantido em todo parser.
                [System.IO.File]::WriteAllText($ConfigPath, $r.Text, [System.Text.UTF8Encoding]::new($false))
                Write-Step OK "shell do herdr: panes novos abrem no PowerShell 7 (default_shell = `"$script:HerdrPwshShell`")"
                $Summary.Installed++
                if (Invoke-HerdrReloadConfig) {
                    Write-Step INFO 'shell do herdr: config recarregado no servidor em execução — panes JÁ abertos seguem no shell antigo; abra um novo'
                }
                else {
                    Write-Step INFO 'shell do herdr: vale ao iniciar o herdr (com o servidor rodando: herdr server reload-config); panes já abertos seguem no shell antigo'
                }
            }
            catch {
                Write-Step WARN "shell do herdr: falha ao escrever — $($_.Exception.Message)"
                $Summary.Warn++
            }
        }
    }
}
