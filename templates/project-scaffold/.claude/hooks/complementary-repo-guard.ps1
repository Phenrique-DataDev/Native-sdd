<#
.SYNOPSIS
    Hook PreToolUse (matcher "Write|Edit") — backstop do boundary read-only de repositorios
    complementares (REPOS_COMPLEMENTARES, DESIGN D3).

.DESCRIPTION
    Irmao dos guards globais (secret-guard/destructive-guard), mas de PROJETO: em cada
    Write/Edit decide:
      - file_path cai dentro de um Path registrado em .claude/complementary-repos.psd1 (que
        ainda existe no disco) OU dentro do cache .claude/.cache/complementary-repos/
                                                                        -> permissionDecision "ask"
      - qualquer outro caso                                           -> PASSTHROUGH (exit 0)

    NUNCA usa "deny" (mesma filosofia dos demais guards): so pede confirmacao. A regra
    complementary-repos.md e' quem ensina a nunca escrever ali; este hook e' o backstop
    deterministico caso a regra falhe/seja ignorada.

    Fail-safe ASSIMETRICO (molde secret-guard.ps1): registro AUSENTE -> passthrough (nada a
    proteger). Registro PRESENTE mas erro ao ler/parsear -> "ask" (nao da pra confirmar que e'
    seguro escrever, entao pergunta).

    Self-contido de proposito: NAO dot-source tools/complementary-repos.ps1 (cascata
    rules/tooling.md) para nao depender de $env:SDD_WORKFLOW_HOME em tempo de guard de
    seguranca — Import-PowerShellDataFile e' nativo do PowerShell 5.1+/7+, sem dependencia
    externa. tools/complementary-repos.ps1 continua sendo a fonte para o comando
    /complementary-repos (add/list/remove) e uso programatico/testes.

    Limitacao honesta: cobre Write/Edit (o caminho normal do agente escrever arquivo). Escrita
    via Bash bruto (cp/>/mv apontando pro repo complementar) nao e' interceptada aqui — mesma
    classe de gap que o destructive-guard ja aceita fora do proprio escopo declarado.

    Schema do hook (PreToolUse) no mesmo molde de secret-guard.ps1/destructive-guard.ps1.
    Funcoes puras sao dot-sourceaveis para teste; o fluxo so roda quando NAO e' dot-sourced.
#>

Set-StrictMode -Version Latest

$script:ComplementaryRepoRegistryRelPath = '.claude/complementary-repos.psd1'
$script:ComplementaryRepoCacheRelPath = '.claude/.cache/complementary-repos'

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: extrai os campos canonicos do payload ja parseado (contrato H5/HARNESS-CONTRACT.md) -
function Read-NormalizedEvent {
    param([Parameter(Mandatory)][AllowNull()]$Payload)
    $toolInput = Get-PropOrNull $Payload 'tool_input'
    return [pscustomobject]@{
        ToolName = [string](Get-PropOrNull $Payload 'tool_name')
        FilePath = [string](Get-PropOrNull $toolInput 'file_path')
        Cwd      = [string](Get-PropOrNull $Payload 'cwd')
    }
}

# --- PURA: monta o JSON da decisao (schema PreToolUse) ----------------------------------------
function New-HookDecisionJson {
    param(
        [Parameter(Mandatory)][ValidateSet('allow', 'ask', 'deny')][string]$Decision,
        [string]$Reason
    )
    $obj = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $Decision
            permissionDecisionReason = $Reason
        }
        systemMessage = $Reason
    }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# --- PURA: file_path cai dentro de algum path protegido? (mesma logica de tools/complementary-repos.ps1)
function Test-PathUnderProtected {
    param([string]$FilePath, [string[]]$ProtectedPaths)
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not $ProtectedPaths -or $ProtectedPaths.Count -eq 0) {
        return $false
    }
    $norm = $FilePath.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    foreach ($p in $ProtectedPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $pn = $p.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
        if ($norm -eq $pn -or $norm.StartsWith("$pn/")) { return $true }
    }
    return $false
}

# --- I/O (read-only): le o registro + deriva os paths protegidos (self-contido, sem tools/) ----
function Get-ComplementaryRepoProtectedPathsInline {
    param([Parameter(Mandatory)][string]$Cwd)

    $registryPath = Join-Path $Cwd $script:ComplementaryRepoRegistryRelPath
    $cacheRoot = Join-Path $Cwd $script:ComplementaryRepoCacheRelPath

    $protectedPaths = @()
    if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
        $protectedPaths += (Resolve-Path -LiteralPath $cacheRoot).Path
    }
    else {
        $protectedPaths += $cacheRoot
    }

    $data = Import-PowerShellDataFile -LiteralPath $registryPath
    foreach ($entry in @($data.Repos)) {
        $p = [string]$entry['Path']
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Container)) {
            $protectedPaths += (Resolve-Path -LiteralPath $p).Path
        }
    }
    return @($protectedPaths | Select-Object -Unique)
}

# --- Fluxo principal ----------------------------------------------------------------------------
function Invoke-ComplementaryRepoGuard {
    # 1) Ler payload (falha -> passthrough)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Pre-condicoes (qualquer nao-match -> passthrough)
    $evt = Read-NormalizedEvent $payload
    if ($evt.ToolName -notin @('Write', 'Edit')) { return }
    if ([string]::IsNullOrWhiteSpace($evt.FilePath)) { return }

    $cwd = $evt.Cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = (Get-Location).Path }

    $registryPath = Join-Path $cwd $script:ComplementaryRepoRegistryRelPath
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { return }   # nada registrado -> passthrough

    # 3) Registro presente: erro ao ler/resolver = "ask" (fail-safe assimetrico, Decisao 4)
    try {
        $protectedPaths = Get-ComplementaryRepoProtectedPathsInline -Cwd $cwd
    }
    catch {
        Write-Output (New-HookDecisionJson -Decision 'ask' `
                -Reason 'Nao foi possivel verificar o registro de repositorios complementares (.claude/complementary-repos.psd1). Confirmacao exigida.')
        return
    }

    if (Test-PathUnderProtected -FilePath $evt.FilePath -ProtectedPaths $protectedPaths) {
        Write-Output (New-HookDecisionJson -Decision 'ask' `
                -Reason "O caminho '$($evt.FilePath)' pertence a um repositorio complementar registrado (leitura-only). Confirme que quer mesmo escrever fora do projeto atual.")
    }
}

# --- Guard: roda o fluxo so quando NAO dot-sourced (Pester faz `. complementary-repo-guard.ps1`)
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ComplementaryRepoGuard
}
