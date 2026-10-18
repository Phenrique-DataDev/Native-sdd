# install-harness-guards.ps1 — leva os guards de Bash do ~/.claude ao GitHub Copilot CLI e ao
# Antigravity CLI, que não leem o ~/.claude (GUARD_NAO_CHEGA_AO_COPILOT_NEM_AO_ANTIGRAVITY).
# Só grava para a ferramenta que está no PATH. Falha vira WARN, nunca Failed.
# Efeito na máquina: ~/.copilot/hooks/native-sdd-guards.json (arquivo nosso, inteiro) e a chave
# `native-sdd-guard` do ~/.gemini/config/hooks.json (as outras chaves do usuário ficam).
# Requer que lib.ps1 já esteja carregado (Test-CommandExists, Write-Step, Backup-File).
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

$script:AntigravityGuardKey = 'native-sdd-guard'

function Get-CopilotGuardHooksContent {
    <#
    .SYNOPSIS
        (Puro) O JSON de ~/.copilot/hooks/native-sdd-guards.json.
    .DESCRIPTION
        Medido no Copilot CLI 1.0.98 (2026-10-18): com o evento em PascalCase (`PreToolUse`) ele
        manda o payload do Claude Code (`tool_name: "Bash"` também para a tool powershell do
        Windows, `tool_input.command`, `cwd`) e respeita o `hookSpecificOutput.permissionDecision`
        "ask" do bash-guards, inclusive com `--allow-all-tools`: abre o "Hook permission request"
        com a razão. Por isso não há adapter, e o hook roda o MESMO dispatcher do Claude Code.
        No Windows o Copilot roda o `powershell`; no Linux/macOS, o `bash` (não medido).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HomePath)
    $h = ($HomePath -replace '\\', '/').TrimEnd('/')
    $ps1 = "$h/.claude/hooks/bash-guards.ps1"
    $sh = "$h/.claude/hooks/bash-guards.sh"
    $entry = [ordered]@{
        type       = 'command'
        matcher    = 'Bash'
        powershell = "pwsh -NoProfile -File `"$ps1`""
        bash       = "if command -v pwsh >/dev/null 2>&1; then exec pwsh -NoProfile -File `"$ps1`"; else exec bash `"$sh`"; fi"
        timeoutSec = 30
    }
    $obj = [ordered]@{ version = 1; hooks = [ordered]@{ PreToolUse = @($entry) } }
    return ($obj | ConvertTo-Json -Depth 6)
}

function Get-AntigravityGuardHookEntry {
    <#
    .SYNOPSIS
        (Puro) O valor da chave `native-sdd-guard` do ~/.gemini/config/hooks.json.
    .DESCRIPTION
        Sem aspas no caminho, de propósito: no agy 1.4.2 do Windows elas chegam LITERAIS ao pwsh
        (`The argument '"C:/..."' is not recognized`, exit 64, medido 2026-10-18), e hook que falha
        faz o agy recusar o comando. Pelo mesmo motivo, caminho com espaço lança em vez de gravar:
        a linha quebraria no espaço e TODO comando de shell passaria a falhar.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HomePath)
    $h = ($HomePath -replace '\\', '/').TrimEnd('/')
    $adapter = "$h/.claude/hooks/adapters/antigravity/adapter-guard.ps1"
    if ($adapter -match '\s') { throw "caminho com espaço ($adapter): o agy não aceita aspas na linha do hook" }
    $hook = [ordered]@{ type = 'command'; command = "pwsh -NoProfile -File $adapter"; timeout = 30 }
    return [ordered]@{ PreToolUse = @([ordered]@{ matcher = 'run_command'; hooks = @($hook) }) }
}

function Get-AntigravityGuardHooksContent {
    <#
    .SYNOPSIS
        (Puro) O ~/.gemini/config/hooks.json com a nossa chave posta ou trocada.
    .DESCRIPTION
        O arquivo é do usuário e de qualquer outra ferramenta: cada chave de topo é um hook com nome
        (antigravity.google/docs/hooks). Só a chave `native-sdd-guard` é nossa; as outras voltam
        como estavam. JSON existente que não parseia ou que não é objeto lança: sobrescrever
        apagaria os hooks do usuário.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HomePath,
        [AllowEmptyString()][string]$Existing = ''
    )
    $out = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($Existing)) {
        $atual = $Existing | ConvertFrom-Json -ErrorAction Stop
        if ($atual -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'hooks.json existente não é um objeto JSON'
        }
        foreach ($p in $atual.PSObject.Properties) { $out[$p.Name] = $p.Value }
    }
    $out[$script:AntigravityGuardKey] = Get-AntigravityGuardHookEntry -HomePath $HomePath
    return ($out | ConvertTo-Json -Depth 20)
}

function Install-HarnessGuardFile {
    # Grava $Content em $Path com backup, ou só relata em -Check/-DryRun. Idêntico = SKIP.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][hashtable]$Summary,
        [switch]$Check,
        [switch]$DryRun
    )
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($exists -and ((Get-Content -LiteralPath $Path -Raw).Trim() -eq $Content.Trim())) {
        Write-Step SKIP "guards $Label`: em dia"
        $Summary.Skipped++
        return
    }
    $verb = if ($exists) { 'atualiza' } else { 'cria' }
    if ($Check)  { Write-Step INFO "guards $Label`: $verb $Path"; return }
    if ($DryRun) { Write-Step DRY  "guards $Label`: $verb $Path"; return }
    $bak = Backup-File -Path $Path
    if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF-8 sem BOM: parser JSON estrito (o mesmo cuidado do Install-JsonBaselineItem).
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    Write-Step OK "guards $Label`: $verb $Path"
    $Summary.Installed++
}

function Invoke-HarnessGuardsSetup {
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$UserHome,
        # Só para teste: decide quais CLIs "estão no PATH" sem depender da máquina.
        [scriptblock]$CommandExists = { param($n) Test-CommandExists $n },
        [switch]$Check,
        [switch]$DryRun
    )
    if (& $CommandExists 'copilot') {
        try {
            $path = Join-Path (Join-Path (Join-Path $UserHome '.copilot') 'hooks') 'native-sdd-guards.json'
            Install-HarnessGuardFile -Label 'Copilot' -Path $path -Content (Get-CopilotGuardHooksContent -HomePath $UserHome) -Summary $Summary -Check:$Check -DryRun:$DryRun
        }
        catch { Write-Step WARN "guards Copilot: $($_.Exception.Message)"; $Summary.Warn++ }
    }
    else { Write-Step SKIP 'guards Copilot: copilot fora do PATH'; $Summary.Skipped++ }

    if (& $CommandExists 'agy') {
        try {
            $path = Join-Path (Join-Path (Join-Path $UserHome '.gemini') 'config') 'hooks.json'
            $existing = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Raw } else { '' }
            $content = Get-AntigravityGuardHooksContent -HomePath $UserHome -Existing $existing
            Install-HarnessGuardFile -Label 'Antigravity' -Path $path -Content $content -Summary $Summary -Check:$Check -DryRun:$DryRun
        }
        catch { Write-Step WARN "guards Antigravity: $($_.Exception.Message) (nada gravado)"; $Summary.Warn++ }
    }
    else { Write-Step SKIP 'guards Antigravity: agy fora do PATH'; $Summary.Skipped++ }
}
