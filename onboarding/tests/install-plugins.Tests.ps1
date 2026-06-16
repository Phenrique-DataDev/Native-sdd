# Pester 5 — validação do passo de plugins de design (opt-in, user scope).
# Cobre a DECISÃO pura (Get-PluginPlan + Get-DesignPluginCatalog): gate, idempotência, steps.
# A execução real (Invoke-DesignPluginsSetup -> claude plugin ...) tem efeito colateral e fica
# fora do CI (coberta por E2E/manual).
# Rodar:  Invoke-Pester onboarding/tests

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $repoRoot 'onboarding\windows\install-plugins.ps1')
    $script:spec = (Get-PluginCatalog)[0]
}

Describe 'Get-PluginCatalog — forma do catálogo' {
    It 'cada entrada tem Plugin/Marketplace/Name/Category/Reason não vazios' {
        foreach ($s in Get-PluginCatalog) {
            $s.Plugin      | Should -Not -BeNullOrEmpty
            $s.Marketplace | Should -Not -BeNullOrEmpty
            $s.Name        | Should -Not -BeNullOrEmpty
            $s.Category    | Should -Not -BeNullOrEmpty
            $s.Reason      | Should -Not -BeNullOrEmpty
        }
    }

    It 'Marketplace está no formato owner/repo' {
        foreach ($s in Get-PluginCatalog) {
            $s.Marketplace | Should -Match '^[^/]+/[^/]+$'
        }
    }

    It 'inclui ui-ux-pro-max (design) e visual-explainer (reporting)' {
        $cat = Get-PluginCatalog
        $cat.Plugin | Should -Contain 'ui-ux-pro-max'
        $cat.Plugin | Should -Contain 'visual-explainer'
        ($cat | Where-Object Plugin -eq 'ui-ux-pro-max').Category    | Should -Be 'design'
        ($cat | Where-Object Plugin -eq 'visual-explainer').Category | Should -Be 'reporting'
    }
}

Describe 'Get-PluginPlan — caminho feliz (add)' {
    It 'claude presente e não instalado -> Action add com 2 steps' {
        $p = Get-PluginPlan -ClaudePresent $true -AlreadyInstalled $false -Spec $spec
        $p.Action       | Should -Be 'add'
        $p.Steps.Count  | Should -Be 2
    }

    It 'step[0] = marketplace add (owner/repo)' {
        $p = Get-PluginPlan -ClaudePresent $true -AlreadyInstalled $false -Spec $spec
        $p.Steps[0]     | Should -Be @('plugin', 'marketplace', 'add', $spec.Marketplace)
    }

    It 'step[1] = install (plugin arroba marketplace)' {
        $p = Get-PluginPlan -ClaudePresent $true -AlreadyInstalled $false -Spec $spec
        $p.Steps[1][0]  | Should -Be 'plugin'
        $p.Steps[1][1]  | Should -Be 'install'
        $p.Steps[1][2]  | Should -Be "$($spec.Plugin)@$($spec.Name)"
    }

    It 'marketplace add precede o install' {
        $p = Get-PluginPlan -ClaudePresent $true -AlreadyInstalled $false -Spec $spec
        $p.Steps[0]     | Should -Contain 'add'
        $p.Steps[1]     | Should -Contain 'install'
    }
}

Describe 'Get-PluginPlan — idempotência e gates' {
    It 'já instalado -> skip (sem steps)' {
        $p = Get-PluginPlan -ClaudePresent $true -AlreadyInstalled $true -Spec $spec
        $p.Action | Should -Be 'skip'
        $p.Reason | Should -Match 'já instalado'
        $p.Steps  | Should -BeNullOrEmpty
    }

    It 'sem claude -> warn (sem steps)' {
        $p = Get-PluginPlan -ClaudePresent $false -AlreadyInstalled $false -Spec $spec
        $p.Action | Should -Be 'warn'
        $p.Reason | Should -Match 'claude'
        $p.Steps  | Should -BeNullOrEmpty
    }

    It 'gate do claude tem precedência sobre o já-instalado' {
        $p = Get-PluginPlan -ClaudePresent $false -AlreadyInstalled $true -Spec $spec
        $p.Action | Should -Be 'warn'
    }
}

Describe 'Get-PluginPlan — determinismo' {
    It 'duas chamadas iguais -> objeto idêntico' {
        $a = Get-PluginPlan -ClaudePresent $true -AlreadyInstalled $false -Spec $spec
        $b = Get-PluginPlan -ClaudePresent $true -AlreadyInstalled $false -Spec $spec
        ($a | ConvertTo-Json -Depth 6 -Compress) | Should -Be ($b | ConvertTo-Json -Depth 6 -Compress)
    }
}

Describe 'Spec-conformance do passo A2e (apply.ps1 / install.ps1)' {
    It 'apply.ps1 invoca Invoke-PluginsSetup sob -ExtraPlugins' {
        $apply = Get-Content -LiteralPath (Join-Path $repoRoot 'onboarding\windows\apply.ps1') -Raw
        $apply | Should -Match 'Invoke-PluginsSetup'
        $apply | Should -Match 'install-plugins.ps1'
        $apply | Should -Match '\$ExtraPlugins'
    }

    It 'install.ps1 expõe e repassa a flag -ExtraPlugins' {
        $install = Get-Content -LiteralPath (Join-Path $repoRoot 'onboarding\install.ps1') -Raw
        $install | Should -Match '\[switch\]\$ExtraPlugins'
        $install | Should -Match '-ExtraPlugins:\$ExtraPlugins'
    }
}
