# Pester 5 — funções puras do hook docs-push guard (C6).
# Rodar:  Invoke-Pester onboarding/tests/main-push-guard.Tests.ps1

BeforeAll {
    $hook = Join-Path $PSScriptRoot '..\..\templates\global-claude\hooks\main-push-guard.ps1'
    . $hook   # dot-source: define as funções sem disparar o fluxo (guard InvocationName)
}

# Disponibilidade de git para os testes de integração (avaliado na descoberta p/ -Skip).
$HasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

Describe 'Test-IsGitPush' {
    It 'reconhece `git push` simples' {
        Test-IsGitPush 'git push' | Should -BeTrue
    }
    It 'reconhece push com remote/branch e flags' {
        Test-IsGitPush 'git push origin main'        | Should -BeTrue
        Test-IsGitPush 'git -C /repo push --tags'    | Should -BeTrue
        Test-IsGitPush 'git push -u origin feature'  | Should -BeTrue
    }
    It 'reconhece push em cadeia (&&)' {
        Test-IsGitPush 'git add -A && git commit -m x && git push' | Should -BeTrue
    }
    It 'AT-005: ignora comandos que não são push' {
        Test-IsGitPush 'git status'              | Should -BeFalse
        Test-IsGitPush 'git commit -m "push it"' | Should -BeFalse
        Test-IsGitPush 'git config push.default simple' | Should -BeFalse
        Test-IsGitPush 'ls -la'                  | Should -BeFalse
        Test-IsGitPush ''                        | Should -BeFalse
    }
    It 'não casa subcomando colado (push-mirror)' {
        Test-IsGitPush 'git push-mirror origin' | Should -BeFalse
    }
}

Describe 'Test-IsDocPath' {
    It 'AT-009: .md em qualquer lugar é doc' {
        Test-IsDocPath 'CHANGELOG.md'        | Should -BeTrue
        Test-IsDocPath 'README.md'           | Should -BeTrue
        Test-IsDocPath 'src/notes/x.MD'      | Should -BeTrue   # case-insensitive
    }
    It 'pastas de docs contam (incl. AT-010 assets)' {
        Test-IsDocPath 'docs/img/diagrama.png'       | Should -BeTrue
        Test-IsDocPath 'methodology/01-onboarding/x' | Should -BeTrue
        Test-IsDocPath 'features/BACKLOG.md'         | Should -BeTrue
    }
    It 'normaliza separador do Windows' {
        Test-IsDocPath 'docs\sub\a.png' | Should -BeTrue
    }
    It 'código e outros paths não são doc' {
        Test-IsDocPath 'onboarding/lib.ps1'   | Should -BeFalse
        Test-IsDocPath 'tools/x.ps1'          | Should -BeFalse
        Test-IsDocPath 'src/app.py'           | Should -BeFalse
        Test-IsDocPath 'mdocs/x.ps1'          | Should -BeFalse  # não confundir prefixo
        Test-IsDocPath ''                     | Should -BeFalse
    }
}

Describe 'Get-PushDecision' {
    It 'AT-001: tudo doc -> allow' {
        $d = Get-PushDecision @('README.md', 'docs/x.md')
        $d.Decision | Should -Be 'allow'
        $d.NonDocs.Count | Should -Be 0
    }
    It 'AT-002: código -> ask com a lista' {
        $d = Get-PushDecision @('onboarding/lib.ps1')
        $d.Decision | Should -Be 'ask'
        $d.NonDocs | Should -Contain 'onboarding/lib.ps1'
    }
    It 'AT-003: misto -> ask (basta 1 não-doc)' {
        $d = Get-PushDecision @('docs/a.md', 'tools/x.ps1')
        $d.Decision | Should -Be 'ask'
        $d.NonDocs | Should -Contain 'tools/x.ps1'
        $d.NonDocs | Should -Not -Contain 'docs/a.md'
    }
    It 'AT-008: vazio/null -> ask (fail-safe)' {
        (Get-PushDecision @()).Decision   | Should -Be 'ask'
        (Get-PushDecision $null).Decision | Should -Be 'ask'
    }
}

Describe 'New-HookDecisionJson' {
    It 'emite JSON válido com o schema do PreToolUse' {
        $json = New-HookDecisionJson -Decision 'allow' -Reason 'ok'
        $obj = $json | ConvertFrom-Json
        $obj.hookSpecificOutput.hookEventName      | Should -Be 'PreToolUse'
        $obj.hookSpecificOutput.permissionDecision | Should -Be 'allow'
        $obj.hookSpecificOutput.permissionDecisionReason | Should -Be 'ok'
        $obj.systemMessage | Should -Be 'ok'
    }
    It 'rejeita decisão fora do conjunto' {
        { New-HookDecisionJson -Decision 'maybe' -Reason 'x' } | Should -Throw
    }
}

Describe 'integração git (read-only)' {
    BeforeAll {
        $script:repo = Join-Path $TestDrive 'repo'
        $hasGitRun = [bool](Get-Command git -ErrorAction SilentlyContinue)
        if ($hasGitRun) {
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Push-Location $repo
            try {
                git init -q 2>$null
                git config user.email 'test@example.com' 2>$null
                git config user.name  'Test' 2>$null
                git config commit.gpgsign false 2>$null
                Set-Content -Path (Join-Path $repo 'base.txt') -Value 'base'
                git add -A 2>$null; git commit -q -m 'base' 2>$null
            }
            finally { Pop-Location }
        }
    }

    It 'Get-CurrentBranch retorna a branch atual' -Skip:(-not $HasGit) {
        Push-Location $repo
        try { Get-CurrentBranch | Should -Not -BeNullOrEmpty }
        finally { Pop-Location }
    }

    It 'AT-001/002 via git real: classifica o diff name-only' -Skip:(-not $HasGit) {
        Push-Location $repo
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo 'docs') -Force | Out-Null
            Set-Content -Path (Join-Path $repo 'docs\guia.md') -Value '# guia'
            git add -A 2>$null; git commit -q -m 'docs' 2>$null
            $paths = @(git diff --name-only HEAD~1..HEAD)
            (Get-PushDecision $paths).Decision | Should -Be 'allow'

            Set-Content -Path (Join-Path $repo 'app.ps1') -Value 'Write-Output 1'
            git add -A 2>$null; git commit -q -m 'code' 2>$null
            $paths2 = @(git diff --name-only HEAD~1..HEAD)
            (Get-PushDecision $paths2).Decision | Should -Be 'ask'
        }
        finally { Pop-Location }
    }
}
