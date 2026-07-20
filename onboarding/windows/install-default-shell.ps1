# install-default-shell.ps1 — define o PowerShell 7 (pwsh) como perfil PADRÃO do Windows Terminal.
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
