# install-clis.ps1 — instala as dependências (lista FIXA) via winget + Claude Code.
# Requer que lib.ps1 já esteja carregado (dot-sourced) pelo orquestrador.

Set-StrictMode -Version Latest

function Get-DependencyList {
    # Lista fixa para um PC dev/dados recém-formatado (decisão do DEFINE).
    return @(
        @{ Id = 'Microsoft.PowerShell';       Name = 'PowerShell 7';   Cmd = 'pwsh' }
        @{ Id = 'Git.Git';                    Name = 'Git';            Cmd = 'git' }
        @{ Id = 'GitHub.cli';                 Name = 'GitHub CLI';     Cmd = 'gh' }
        @{ Id = 'Python.Python.3.12';         Name = 'Python 3.12';    Cmd = 'python' }
        @{ Id = 'astral-sh.uv';               Name = 'uv';             Cmd = 'uv' }
        @{ Id = 'OpenJS.NodeJS.LTS';          Name = 'Node.js 22 LTS'; Cmd = 'node' }
        @{ Id = 'BurntSushi.ripgrep.MSVC';    Name = 'ripgrep';        Cmd = 'rg' }
        @{ Id = 'jqlang.jq';                  Name = 'jq';             Cmd = 'jq' }
        @{ Id = 'MikeFarah.yq';               Name = 'yq';             Cmd = 'yq' }
        @{ Id = 'Microsoft.VisualStudioCode'; Name = 'VS Code';        Cmd = 'code' }
    )
}

function Install-ClaudeCode {
    param([Parameter(Mandatory)][hashtable]$Summary, [switch]$Check, [switch]$DryRun)
    if (Test-CommandExists 'claude') {
        Write-Step SKIP 'Claude Code já instalado'
        $Summary.Skipped++
        return
    }
    if ($Check)  { Write-Step INFO 'Claude Code faltando'; return }
    if ($DryRun) { Write-Step DRY 'irm https://claude.ai/install.ps1 | iex'; return }

    Write-Step RUN 'Instalando Claude Code ...'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # URL oficial fixa. Só executa se 'claude' não existe.
        Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' | Invoke-Expression
        $sw.Stop()
        Update-SessionPath
        if (Test-CommandExists 'claude') {
            Write-Step OK "Claude Code ($(Format-Duration $sw.Elapsed))"
        }
        else {
            Write-Step WARN "Claude Code instalado, mas 'claude' não resolveu — reabra o terminal ($(Format-Duration $sw.Elapsed))"
            $Summary.Warn++
        }
        $Summary.Installed++
    }
    catch {
        $sw.Stop()
        Write-Step FAIL "Claude Code — $($_.Exception.Message)"
        $Summary.Failed++
        $Summary.Failures += 'claude-code'
    }
}

function Invoke-InstallClis {
    param([Parameter(Mandatory)][hashtable]$Summary, [switch]$Check, [switch]$DryRun)

    if (-not (Test-CommandExists 'winget')) {
        Write-Step FAIL 'winget não encontrado.'
        Write-Step INFO 'Instale o "App Installer" pela Microsoft Store (ou https://aka.ms/getwinget) e rode de novo.'
        $Summary.Failed++
        $Summary.Failures += 'winget-missing'
        return
    }

    Write-Step INFO 'Dependências (winget):'
    foreach ($dep in (Get-DependencyList)) {
        Install-WingetPackage -Id $dep.Id -Name $dep.Name -Cmd $dep.Cmd -Summary $Summary -Check:$Check -DryRun:$DryRun
    }

    Write-Step INFO 'Claude Code:'
    Install-ClaudeCode -Summary $Summary -Check:$Check -DryRun:$DryRun
}
