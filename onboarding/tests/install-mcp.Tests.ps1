# Pester 5 — validação automática do A8 (context7 MCP no onboarding / fecha J1).
# Cobre a DECISÃO pura (Get-Context7Plan): gate, idempotência, fallback, args, com/sem key.
# A execução real (Invoke-Context7Setup -> claude mcp add) tem efeito colateral e fica fora
# do CI (coberta por E2E/manual).
# Rodar:  Invoke-Pester onboarding/tests

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $repoRoot 'onboarding\windows\install-mcp.ps1')
}

Describe 'Get-Context7Plan — caminho feliz (AT-001/002)' {
    It 'sem key: Action add e args base, sem --api-key (AT-001)' {
        $p = Get-Context7Plan -ClaudePresent $true -NpxPresent $true -AlreadyRegistered $false
        $p.Action | Should -Be 'add'
        $p.Args   | Should -Contain 'mcp'
        $p.Args   | Should -Contain 'add'
        $p.Args   | Should -Contain '--scope'
        $p.Args   | Should -Contain 'user'
        $p.Args   | Should -Contain 'context7'
        $p.Args   | Should -Contain 'npx'
        $p.Args   | Should -Contain '@upstash/context7-mcp'
        $p.Args   | Should -Not -Contain '--api-key'
    }

    It 'preserva a ordem: -- antes de npx' {
        $p = Get-Context7Plan -ClaudePresent $true -NpxPresent $true -AlreadyRegistered $false
        ([array]::IndexOf($p.Args, '--')) | Should -BeLessThan ([array]::IndexOf($p.Args, 'npx'))
    }

    It 'com key no ambiente: args incluem --api-key e o valor (AT-002)' {
        $p = Get-Context7Plan -ClaudePresent $true -NpxPresent $true -AlreadyRegistered $false -ApiKey 'k123'
        $p.Action | Should -Be 'add'
        $p.Args   | Should -Contain '--api-key'
        $p.Args   | Should -Contain 'k123'
    }
}

Describe 'Get-Context7Plan — idempotência e gates (AT-003/004/005)' {
    It 'já registrado -> skip (AT-003)' {
        $p = Get-Context7Plan -ClaudePresent $true -NpxPresent $true -AlreadyRegistered $true
        $p.Action | Should -Be 'skip'
        $p.Reason | Should -Match 'já registrado'
        $p.Args   | Should -BeNullOrEmpty
    }

    It 'sem claude -> warn (AT-004)' {
        $p = Get-Context7Plan -ClaudePresent $false -NpxPresent $true -AlreadyRegistered $false
        $p.Action | Should -Be 'warn'
        $p.Reason | Should -Match 'claude'
    }

    It 'sem npx -> warn (AT-005)' {
        $p = Get-Context7Plan -ClaudePresent $true -NpxPresent $false -AlreadyRegistered $false
        $p.Action | Should -Be 'warn'
        $p.Reason | Should -Match 'npx'
    }

    It 'gate do claude tem precedência sobre o do npx' {
        $p = Get-Context7Plan -ClaudePresent $false -NpxPresent $false -AlreadyRegistered $false
        $p.Reason | Should -Match 'claude'
    }
}

Describe 'Get-Context7Plan — determinismo e segredo (AT-006/007)' {
    It 'duas chamadas iguais -> objeto idêntico (AT-006)' {
        $a = Get-Context7Plan -ClaudePresent $true -NpxPresent $true -AlreadyRegistered $false -ApiKey 'k'
        $b = Get-Context7Plan -ClaudePresent $true -NpxPresent $true -AlreadyRegistered $false -ApiKey 'k'
        ($a | ConvertTo-Json -Compress) | Should -Be ($b | ConvertTo-Json -Compress)
    }

    It 'Reason NUNCA contém o valor da key (AT-007)' {
        $p = Get-Context7Plan -ClaudePresent $true -NpxPresent $true -AlreadyRegistered $false -ApiKey 'secreta'
        $p.Reason | Should -Not -Match 'secreta'
    }
}

Describe 'Get-MaskedArgs — não vaza a key em log/DryRun' {
    It 'mascara o valor após --api-key' {
        $masked = Get-MaskedArgs -ArgList @('mcp','add','context7','--api-key','secreta')
        $masked | Should -Match '--api-key \*\*\*'
        $masked | Should -Not -Match 'secreta'
    }

    It 'sem --api-key: passa os args intactos' {
        $masked = Get-MaskedArgs -ArgList @('mcp','add','context7')
        $masked | Should -Be 'mcp add context7'
    }
}

Describe 'Spec-conformance do passo A2c (apply.ps1)' {
    It 'apply.ps1 invoca Invoke-Context7Setup após o baseline' {
        $apply = Get-Content -LiteralPath (Join-Path $repoRoot 'onboarding\windows\apply.ps1') -Raw
        $apply | Should -Match 'Invoke-Context7Setup'
        $apply | Should -Match 'install-mcp.ps1'
    }
}
