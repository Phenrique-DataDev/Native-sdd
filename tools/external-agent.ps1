<#
.SYNOPSIS
    Executor externo do /orchestrate (ORQ_EXECUTOR_OUTRA_CLI): monta e roda, em modo headless, uma
    task delegada a outra CLI de agente (Antigravity/agy, GitHub Copilot, OpenCode) e grava a
    resposta num arquivo. A saída é ALEGAÇÃO: quem decide se a task passou é o gate do líder
    (Test-TaskGate + a verificação que ele mesmo roda), nunca o texto do executor.

.DESCRIPTION
      Get-ExternalAgentCommand -> [pscustomobject] { Kind; Executable; Arguments[]; Permission }   PURA
      Invoke-ExternalAgent     -> [pscustomobject] { ExitCode; TimedOut; OutFile; ErrFile; Seconds; Claim }

    Permissão é escolha explícita de quem chama, com default `read-only`. Não há modo "yolo" por
    default: `all` libera shell e paths sem perguntar, e só deve ser passado quando o usuário pediu.

      | Permission | agy                              | copilot                                | opencode        |
      |------------|----------------------------------|----------------------------------------|-----------------|
      | read-only  | --mode plan                      | (nada: só o que ele reconhece read-only)| --agent plan    |
      | edits      | --mode accept-edits              | --allow-tool=write                     | --auto          |
      | all        | --dangerously-skip-permissions   | --allow-all-tools --allow-all-paths    | --auto          |

    Flags conferidas no `--help` de agy 1.5.14, GitHub Copilot CLI 1.0.114 e opencode v2.4.1
    (2026-11-24). No opencode, `edits` e `all` são o mesmo `--auto`: ele aprova tudo que o
    `opencode.json` do usuário não negar. No copilot, `read-only` não passa flag nenhuma: em `-p`,
    o pedido que exigiria aprovação não tem quem aprove.

    Sem Herdr: é a rota headless, uma task por chamada e sem sessão contínua. A rota por pane
    (sessão visível e contínua) está no suplemento `orchestrating-agents`.

    O prompt vai como argumento separado (ProcessStartInfo.ArgumentList), sem montar linha de
    comando à mão. No Windows, um shim `.cmd` do npm passa pelo cmd.exe, que reinterpreta `%`,
    `^`, `&` e `|`: o shim vira o `.ps1` ao lado, e shim SEM `.ps1` é recusado (ExitCode 126), nunca
    rodado. Nome sem caminho só se resolve pelo PATH, nunca por arquivo do diretório atual.
#>

Set-StrictMode -Version Latest

$script:ExternalAgentKinds = @('agy', 'copilot', 'opencode')

function Get-ExternalAgentCommand {
    <#
    .SYNOPSIS
        PURA. Monta executável + argumentos para delegar um prompt a outra CLI em modo headless.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('agy', 'copilot', 'opencode')][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt,
        [ValidateSet('read-only', 'edits', 'all')][string]$Permission = 'read-only',
        [string]$Model
    )

    $argv = [System.Collections.Generic.List[string]]::new()
    switch ($Kind) {
        'agy' {
            $argv.Add('-p'); $argv.Add($Prompt)
            switch ($Permission) {
                'read-only' { $argv.Add('--mode'); $argv.Add('plan') }
                'edits'     { $argv.Add('--mode'); $argv.Add('accept-edits') }
                'all'       { $argv.Add('--dangerously-skip-permissions') }
            }
            if ($Model) { $argv.Add('--model'); $argv.Add($Model) }
        }
        'copilot' {
            $argv.Add('-p'); $argv.Add($Prompt); $argv.Add('-s')
            switch ($Permission) {
                'read-only' { }
                'edits'     { $argv.Add('--allow-tool=write') }
                'all'       { $argv.Add('--allow-all-tools'); $argv.Add('--allow-all-paths') }
            }
            if ($Model) { $argv.Add('--model'); $argv.Add($Model) }
        }
        'opencode' {
            $argv.Add('run')
            switch ($Permission) {
                'read-only' { $argv.Add('--agent'); $argv.Add('plan') }
                default     { $argv.Add('--auto') }
            }
            if ($Model) { $argv.Add('--model'); $argv.Add($Model) }
            # O prompt vai por último: `opencode run [flags] [<message...>]`.
            $argv.Add($Prompt)
        }
    }

    return [pscustomobject]@{
        Kind       = $Kind
        Executable = $Kind
        Arguments  = $argv.ToArray()
        Permission = $Permission
    }
}

function Resolve-ExternalAgentExecutable {
    <#
    .SYNOPSIS
        Devolve { FileName; Prefix[]; Error }. Error preenchido = não rode.
    .DESCRIPTION
        - Nome SEM separador de caminho (o caso real: 'agy', 'copilot', 'opencode') só se resolve pelo
          PATH. Um arquivo com esse nome no diretório atual NÃO vence a CLI instalada: o líder roda
          dentro do repositório de trabalho, e o repositório pode não ser confiável.
        - Caminho explícito (com `/` ou `\`) é usado como está: é quem chama que o escolheu.
        - Shim .cmd/.bat vira o .ps1 ao lado (rodado por pwsh). SEM .ps1 ao lado, recusa: o
          CreateProcess passaria o .cmd pelo cmd.exe, que não entende o escape do ArgumentList, e um
          `" & cmd & "` dentro do prompt rodaria como comando (classe BatBadBut).
    #>
    param([Parameter(Mandatory)][string]$Name)

    $fail = { param($m) [pscustomobject]@{ FileName = $null; Prefix = @(); Error = $m } }

    if ($Name -match '[\\/]') {
        if (-not (Test-Path -LiteralPath $Name -PathType Leaf)) { return (& $fail "executável não encontrado: $Name") }
        $path = (Resolve-Path -LiteralPath $Name).Path
    }
    else {
        $cmd = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { return (& $fail "executável não encontrado: $Name (instale a CLI ou confira o PATH)") }
        $path = $cmd.Source
    }

    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -in @('.cmd', '.bat')) {
        $ps1 = [System.IO.Path]::ChangeExtension($path, '.ps1')
        if (-not (Test-Path -LiteralPath $ps1 -PathType Leaf)) {
            return (& $fail "recusado: $path é um shim $ext sem .ps1 ao lado; o cmd.exe reinterpretaria o prompt como comando. Passe o executável real (.exe ou .ps1) em Executable.")
        }
        $ext = '.ps1'; $path = $ps1
    }
    if ($ext -eq '.ps1') {
        $pwsh = (Get-Process -Id $PID).Path
        return [pscustomobject]@{ FileName = $pwsh; Prefix = @('-NoProfile', '-File', $path); Error = $null }
    }
    return [pscustomobject]@{ FileName = $path; Prefix = @(); Error = $null }
}

function Invoke-ExternalAgent {
    <#
    .SYNOPSIS
        Roda o comando de Get-ExternalAgentCommand, grava stdout em -OutFile e stderr ao lado.
        Nunca lança por falha do executor: devolve ExitCode/TimedOut para o líder decidir.
    .PARAMETER Command
        O objeto de Get-ExternalAgentCommand (ou um equivalente com Executable e Arguments[]).
    .PARAMETER TimeoutSec
        Prazo da chamada inteira: o processo sair E o stdout/stderr fecharem. Estourou: a árvore é
        morta, TimedOut = $true, ExitCode = -1. Cobre a CLI que sai deixando um filho com o pipe
        herdado aberto (servidor, daemon): sem isso, a leitura esperaria o filho sem prazo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Command,
        [Parameter(Mandatory)][string]$OutFile,
        [ValidateRange(1, 86400)][int]$TimeoutSec = 600,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    # Caminho relativo resolve pelo diretório do PowerShell ($PWD). As APIs .NET (File.WriteAllText,
    # ProcessStartInfo) resolvem por [Environment]::CurrentDirectory, que o Set-Location não muda: sem
    # isto, a pasta nasce num lugar e a gravação procura em outro, e a função lança.
    $OutFile          = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $WorkingDirectory = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)

    $errFile = "$OutFile.stderr"
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $resolved = Resolve-ExternalAgentExecutable -Name ([string]$Command.Executable)
    if ($resolved.Error) {
        $rc = if ($resolved.Error -like 'recusado:*') { 126 } else { 127 }
        [System.IO.File]::WriteAllText($OutFile, '', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($errFile, "$($resolved.Error)`n", [System.Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ ExitCode = $rc; TimedOut = $false; OutFile = $OutFile; ErrFile = $errFile; Seconds = 0; Claim = $true }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $resolved.FileName
    foreach ($a in @($resolved.Prefix)) { $psi.ArgumentList.Add([string]$a) }
    foreach ($a in @($Command.Arguments)) { $psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory       = $WorkingDirectory
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch {
        # Resolveu para um arquivo que o SO não executa (ex.: .txt): falha do executor, não do líder.
        [System.IO.File]::WriteAllText($OutFile, '', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($errFile, "não deu para iniciar $($resolved.FileName): $($_.Exception.InnerException.Message ?? $_.Exception.Message)`n", [System.Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ ExitCode = 126; TimedOut = $false; OutFile = $OutFile; ErrFile = $errFile; Seconds = 0; Claim = $true }
    }
    # Sem stdin: a CLI não pode ficar esperando entrada de quem não existe.
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $prazoMs  = [int64]$TimeoutSec * 1000
    $timedOut = -not $p.WaitForExit([int]$prazoMs)
    if ($timedOut) {
        try { $p.Kill($true) } catch { Write-Verbose "kill após timeout falhou (o processo pode já ter saído): $_" }
        [void]$p.WaitForExit(5000)
    }
    # O processo saiu, mas o pipe só fecha quando todo herdeiro dele fechar. Espera o que sobra do
    # prazo (mínimo de 2 s, para a saída normal terminar de chegar) e desiste.
    $restaMs = [Math]::Max(2000, $prazoMs - $sw.ElapsedMilliseconds)
    $leu = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), [int][Math]::Min($restaMs, [int]::MaxValue))
    $sw.Stop()

    if ($leu) {
        $out = $outTask.Result
        $err = $errTask.Result
    } else {
        $timedOut = $true
        $out = ''
        $err = "prazo de $TimeoutSec s estourado na leitura: a CLI saiu, mas um processo filho segura o stdout/stderr aberto (servidor, daemon). Esse filho ficou vivo; a saída foi descartada.`n"
    }
    [System.IO.File]::WriteAllText($OutFile, $out, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($errFile, $err, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        ExitCode = if ($timedOut) { -1 } else { $p.ExitCode }
        TimedOut = $timedOut
        OutFile  = $OutFile
        ErrFile  = $errFile
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Claim    = $true
    }
}
