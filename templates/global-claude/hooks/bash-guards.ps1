<#
.SYNOPSIS
    Hook PreToolUse (matcher "Bash") — dispatcher UNICO dos dois guards de seguranca.

.DESCRIPTION
    Roda secret-guard e destructive-guard no MESMO processo pwsh, em vez de um processo cada.

    Por que existe: cada hook custa ~510ms, dos quais ~367ms (72%) sao startup do
    `pwsh -NoProfile` -- pago antes de qualquer logica. Como os dois casam o mesmo matcher
    ("Bash"), todo comando pagava DOIS startups para responder a mesma pergunta ("posso rodar
    isto?"). Numa sessao real de 326 comandos Bash: 652 processos, ~5,5 min de wall-clock.
    Consolidado: 326 processos, um unico startup por comando.

    NAO funde os guards. secret-guard.ps1 e destructive-guard.ps1 seguem existindo intactos e
    continuam sendo a fonte da logica -- este arquivo so os dot-sourceia e os chama passando o
    payload ja lido. Isso e' deliberado: os adapters de harness (codex/cursor/opencode), o
    /doctor e a suite Pester invocam cada guard PELO NOME DO ARQUIVO, em subprocesso.

    Fail-safe: cada guard mantem o SEU, que sao OPOSTOS de proposito --
      - secret-guard      : erro ao verificar diff -> "ask" (assimetrico; consulta git)
      - destructive-guard : erro -> silencio (nao consulta git/rede; o lado seguro e' nao atrapalhar)
    Por isso cada chamada tem try/catch PROPRIO: uma falha num guard nunca decide pelo outro.
    Se este dispatcher falhar inteiro, o exit 0 sem saida = passthrough, e a managed policy (C3)
    segue cobrindo o catastrofico -- mesma degradacao que ja existia quando um hook falhava.

    Decisao combinada: os dois podem pedir "ask" no mesmo comando (ex.: `rm -rf ~/x && cat .env`).
    Como o harness le UM JSON por hook, as razoes sao concatenadas num unico "ask" -- nenhuma
    e' descartada. Nenhum guard usa "deny" (postura do projeto: guard pede confirmacao, a
    managed policy e' quem bloqueia).

    Funcoes puras sao dot-sourceaveis; o fluxo so roda quando NAO e' dot-sourced (guard no fim).
#>

Set-StrictMode -Version Latest

# Os dois guards, na mesma pasta. Cada um tem guard de dot-source, entao nenhum auto-executa aqui.
# Get-PropOrNull e New-HookDecisionJson existem nos dois e sao IDENTICAS (verificado) -- a segunda
# definicao sobrescreve a primeira com o mesmo corpo, sem efeito observavel.
$script:GuardScripts = @('secret-guard.ps1', 'destructive-guard.ps1')
foreach ($g in $script:GuardScripts) {
    $p = Join-Path $PSScriptRoot $g
    if (Test-Path -LiteralPath $p) { . $p }
}

# --- PURA: funde as decisoes num unico envelope PreToolUse ------------------------------------
function Merge-GuardDecision {
    param([AllowNull()][string[]]$Outputs)

    $razoes = @()
    foreach ($o in @($Outputs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        try { $obj = $o | ConvertFrom-Json } catch { continue }
        $hso = $obj.PSObject.Properties['hookSpecificOutput']
        if (-not $hso) { continue }
        $r = $hso.Value.PSObject.Properties['permissionDecisionReason']
        if ($r -and -not [string]::IsNullOrWhiteSpace($r.Value)) { $razoes += [string]$r.Value }
    }
    if ($razoes.Count -eq 0) { return $null }

    $texto = ($razoes | Select-Object -Unique) -join ' | '
    $obj = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'ask'
            permissionDecisionReason = $texto
        }
        systemMessage = $texto
    }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-BashGuards {
    # 0) stdout em UTF-8 sem BOM (o texto tem acentuacao pt-BR; sem isto sai em codepage OEM).
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

    # 1) stdin UMA vez -- a economia inteira desta consolidacao mora aqui.
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Cada guard com o SEU try/catch: o fail-safe de um nao pode decidir pelo outro.
    #    (o de dentro de cada Invoke-* continua valendo; este aqui so isola a chamada)
    $saidas = @()
    foreach ($fn in @('Invoke-SecretGuard', 'Invoke-DestructiveGuard')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { continue }
        try { $saidas += @(& $fn -Payload $payload) } catch { continue }
    }

    # 3) Uma decisao combinada (nenhuma razao descartada); nada a dizer -> silencio = passthrough.
    $out = Merge-GuardDecision -Outputs $saidas
    if ($out) { Write-Output $out }
}

# --- Guard: roda o fluxo so quando NAO dot-sourced ---------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-BashGuards
}
