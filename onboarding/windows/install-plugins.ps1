# install-plugins.ps1 — instala plugins de produtividade user-scoped via 'claude plugin'.
# Passo OPT-IN e NÃO bloqueante (espelha A8/install-mcp): qualquer falha vira WARN, nunca Failed —
# A1 (CLIs) e A2 (baseline ~/.claude) permanecem intactos.
# Opt-in de propósito (flag -ExtraPlugins em apply.ps1): os plugins do catálogo são de DOMÍNIO
# (design) ou de superfície opcional (reporting), então não nascem no scaffold context-free (V2) —
# só quando o usuário pede. Instalação é user-scoped ("global dormente"): fica disponível em todo
# projeto, auto-ativa só quando há trabalho da categoria.
# Requer que lib.ps1 já esteja carregado (Test-CommandExists, Write-Step).
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

function Get-PluginCatalog {
    <#
    .SYNOPSIS
        Catálogo (puro) dos plugins instaláveis user-scoped.
    .OUTPUTS
        [pscustomobject[]] cada um com:
        - Plugin       nome do plugin (id após instalado / 'claude plugin details <Plugin>')
        - Marketplace  origem do marketplace no formato owner/repo (claude plugin marketplace add)
        - Name         id do marketplace usado após o '@' (campo 'name' do marketplace.json)
        - Category     'design' | 'reporting' — natureza (p/ log e futura seleção por categoria)
        - Reason       descrição curta p/ log
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{
            Plugin      = 'ui-ux-pro-max'
            Marketplace = 'nextlevelbuilder/ui-ux-pro-max-skill'
            Name        = 'ui-ux-pro-max-skill'
            Category    = 'design'
            Reason      = 'design system / UI (auto-ativa só em pedidos de design)'
        }
        [pscustomobject]@{
            Plugin      = 'visual-explainer'
            Marketplace = 'nicobailon/visual-explainer'
            Name        = 'visual-explainer-marketplace'
            Category    = 'reporting'
            Reason      = 'visualização de saída em HTML (diffs, planos, slides, relatórios)'
        }
    )
}

function Get-PluginPlan {
    <#
    .SYNOPSIS
        Decide (puro) o que fazer com um plugin, a partir do ambiente.
    .OUTPUTS
        [pscustomobject] @{ Action = 'add'|'skip'|'warn'; Steps = [string[][]]; Reason = [string] }
        - Steps só é preenchido em 'add': lista ordenada de invocações (cada uma p/ 'claude @Step').
          [0] = plugin marketplace add <owner/repo>; [1] = plugin install <plugin>@<marketplace>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ClaudePresent,
        [Parameter(Mandatory)][bool]$AlreadyInstalled,
        [Parameter(Mandatory)][pscustomobject]$Spec
    )

    if (-not $ClaudePresent) {
        return [pscustomobject]@{
            Action = 'warn'; Steps = @()
            Reason = "Claude Code (claude) ausente — pulei $($Spec.Plugin); instale depois com: claude plugin marketplace add $($Spec.Marketplace) ; claude plugin install $($Spec.Plugin)@$($Spec.Name)"
        }
    }
    if ($AlreadyInstalled) {
        return [pscustomobject]@{
            Action = 'skip'; Steps = @()
            Reason = "$($Spec.Plugin) já instalado (user scope)"
        }
    }

    $steps = @(
        , @('plugin', 'marketplace', 'add', $Spec.Marketplace)
        , @('plugin', 'install', "$($Spec.Plugin)@$($Spec.Name)")
    )
    return [pscustomobject]@{
        Action = 'add'; Steps = $steps
        Reason = "instalar $($Spec.Plugin) — $($Spec.Reason)"
    }
}

function Invoke-PluginsSetup {
    <#
    .SYNOPSIS
        Executa o plano de cada plugin do catálogo (wrapper com efeito colateral).
        Nunca lança; qualquer falha = WARN (não bloqueante, A1/A2 intactos).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [switch]$Check,
        [switch]$DryRun
    )

    $claudePresent = Test-CommandExists 'claude'

    foreach ($spec in Get-PluginCatalog) {
        # "Já instalado?" só faz sentido se o claude existe; read-only via exit code.
        $already = $false
        if ($claudePresent) {
            try {
                claude plugin details $spec.Plugin 2>&1 | Out-Null
                $already = ($LASTEXITCODE -eq 0)
            }
            catch { $already = $false }
        }

        $plan = Get-PluginPlan -ClaudePresent $claudePresent -AlreadyInstalled $already -Spec $spec

        switch ($plan.Action) {
            'skip' {
                Write-Step SKIP "plugin: $($plan.Reason)"
                $Summary.Skipped++
            }
            'warn' {
                Write-Step WARN "plugin: $($plan.Reason)"
                $Summary.Warn++
            }
            'add' {
                if ($Check) {
                    Write-Step INFO "plugin: $($plan.Reason)"
                }
                elseif ($DryRun) {
                    foreach ($step in $plan.Steps) { Write-Step DRY "claude $($step -join ' ')" }
                }
                else {
                    $ok = $true
                    foreach ($step in $plan.Steps) {
                        try {
                            claude @step 2>&1 | Out-Null
                            if ($LASTEXITCODE -ne 0) {
                                # NÃO bloqueante: registra WARN e segue (A1/A2 intactos).
                                Write-Step WARN "plugin: 'claude $($step -join ' ')' retornou $LASTEXITCODE — instale manualmente depois"
                                $ok = $false
                                break
                            }
                        }
                        catch {
                            Write-Step WARN "plugin: falha ao instalar $($spec.Plugin) — $($_.Exception.Message)"
                            $ok = $false
                            break
                        }
                    }
                    if ($ok) {
                        Write-Step OK "plugin instalado: $($spec.Plugin) (user scope)"
                        $Summary.Installed++
                    }
                    else {
                        $Summary.Warn++
                    }
                }
            }
        }
    }
}
