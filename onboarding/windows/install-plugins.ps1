# install-plugins.ps1 — passo A2e (OPT-IN, NÃO bloqueante) de suplementos user-scoped.
# FINO por design: a lógica vive no núcleo único tools/supplements.ps1 (manifesto + plano + setup),
# reusado também pelo command /supplements do scaffold. Aqui ficam só SHIMS de retrocompat com os
# nomes públicos históricos (Get-PluginCatalog / Get-PluginPlan / Invoke-PluginsSetup) p/ não quebrar
# apply.ps1 nem os testes existentes. Catálogo NÃO é redefinido aqui (fonte única no manifesto).
# Opt-in de propósito (flag -ExtraPlugins em apply.ps1; -Themes filtra): suplementos são de domínio
# (design) ou superfície opcional (reporting) — não nascem no scaffold context-free (V2).
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

# Núcleo único (já dot-source onboarding/windows/lib.ps1 via seu próprio $PSScriptRoot).
. (Join-Path $PSScriptRoot '..\..\tools\supplements.ps1')

function Get-PluginCatalog {
    <#
    .SYNOPSIS
        SHIM retrocompat: catálogo de PLUGINS no formato histórico (Plugin/Marketplace/Name/Category/Reason).
        Deriva do manifesto único (Get-SupplementCatalog, só Type=plugin).
    #>
    [CmdletBinding()]
    param([string[]]$Theme = @())
    return @(Get-SupplementCatalog -Theme $Theme |
            Where-Object { $_.Type -eq 'plugin' } |
            ForEach-Object {
                [pscustomobject]@{
                    Plugin      = $_.Name
                    Marketplace = $_.Source
                    Name        = $_.Id
                    Category    = $_.Theme
                    Reason      = $_.Reason
                }
            })
}

function Get-PluginPlan {
    <#
    .SYNOPSIS
        SHIM retrocompat: plano de um plugin a partir de um Spec no formato histórico.
        Converte p/ o schema do núcleo e delega a Get-SupplementPlan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ClaudePresent,
        [Parameter(Mandatory)][bool]$AlreadyInstalled,
        [Parameter(Mandatory)][pscustomobject]$Spec
    )
    $new = [pscustomobject]@{
        Type   = 'plugin'
        Name   = $Spec.Plugin
        Source = $Spec.Marketplace
        Id     = $Spec.Name
        Theme  = $Spec.Category
        Reason = $Spec.Reason
    }
    $plan = Get-SupplementPlan -Spec $new -ClaudePresent $ClaudePresent -AlreadyInstalled $AlreadyInstalled
    # Forma histórica: { Action; Steps; Reason } (Route é detalhe do núcleo).
    return [pscustomobject]@{
        Action = $plan.Action
        Steps  = $plan.Steps
        Reason = $plan.Reason
    }
}

function Invoke-PluginsSetup {
    <#
    .SYNOPSIS
        SHIM retrocompat: delega ao setup único do núcleo. -Themes filtra (vazio = todos).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [string[]]$Themes = @(),
        [switch]$Check,
        [switch]$DryRun
    )
    Invoke-SupplementsSetup -Summary $Summary -Themes $Themes -Check:$Check -DryRun:$DryRun
}
