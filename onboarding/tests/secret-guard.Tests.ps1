# Pester 5 — funcoes puras do hook secret-guard (#2).
# Rodar:  Invoke-Pester onboarding/tests/secret-guard.Tests.ps1

BeforeAll {
    $hook = Join-Path $PSScriptRoot '..\..\templates\global-claude\hooks\secret-guard.ps1'
    . $hook   # dot-source: define funcoes + carrega a lib; nao dispara o fluxo (guard InvocationName)
}

Describe 'Test-IsGitSubcommand' {
    It 'reconhece commit/push (inclui cadeia e flags)' {
        Test-IsGitSubcommand 'git commit -m x' 'commit'              | Should -BeTrue
        Test-IsGitSubcommand 'git -C /r push --tags' 'push'          | Should -BeTrue
        Test-IsGitSubcommand 'git add -A && git commit -m y' 'commit' | Should -BeTrue
    }
    It 'nao casa subcomando errado / colado' {
        Test-IsGitSubcommand 'git push' 'commit'        | Should -BeFalse
        Test-IsGitSubcommand 'git push-mirror o' 'push' | Should -BeFalse
        Test-IsGitSubcommand 'git status' 'commit'      | Should -BeFalse
        Test-IsGitSubcommand '' 'commit'                | Should -BeFalse
    }
}

Describe 'Test-IsSecretRead' {
    It 'pega leitura de arquivo de segredo' {
        Test-IsSecretRead 'cat .env'                 | Should -BeTrue
        Test-IsSecretRead 'Get-Content config/.env.prod' | Should -BeTrue
        Test-IsSecretRead 'type secrets\token.txt'   | Should -BeTrue
    }
    It 'ignora leitura de arquivo comum e nao-leitores' {
        Test-IsSecretRead 'cat README.md'   | Should -BeFalse
        Test-IsSecretRead 'rm .env'         | Should -BeFalse   # nao é leitor
        Test-IsSecretRead 'echo oi'         | Should -BeFalse
        Test-IsSecretRead ''                | Should -BeFalse
    }
}

Describe 'Get-AddedLine' {
    It 'extrai so as linhas adicionadas, ignorando o cabecalho +++' {
        $diff = "+++ b/app.txt`n+segredo=AKIA`n-removida`n contexto"
        $added = Get-AddedLine $diff
        $added | Should -Match 'segredo=AKIA'
        $added | Should -Not -Match 'removida'
        $added | Should -Not -Match '\+\+\+'
    }
    It 'vazio -> vazio' {
        Get-AddedLine '' | Should -Be ''
    }
}

Describe 'New-HookDecisionJson' {
    It 'emite JSON valido com o schema PreToolUse' {
        $obj = (New-HookDecisionJson -Decision 'ask' -Reason 'r') | ConvertFrom-Json
        $obj.hookSpecificOutput.hookEventName      | Should -Be 'PreToolUse'
        $obj.hookSpecificOutput.permissionDecision | Should -Be 'ask'
        $obj.hookSpecificOutput.permissionDecisionReason | Should -Be 'r'
        $obj.systemMessage | Should -Be 'r'
    }
    It 'rejeita decisao fora do conjunto' {
        { New-HookDecisionJson -Decision 'talvez' -Reason 'x' } | Should -Throw
    }
}

Describe 'Format-SecretReason' {
    It 'lista os padroes unicos no motivo' {
        $findings = @(
            [pscustomobject]@{ Pattern = 'AWS Access Key ID'; Confidence = 'High'; Sample = 'AKIA***' },
            [pscustomobject]@{ Pattern = 'AWS Access Key ID'; Confidence = 'High'; Sample = 'AKIA***' }
        )
        $r = Format-SecretReason 'O commit (staged)' $findings
        $r | Should -Match 'O commit \(staged\)'
        $r | Should -Match 'AWS Access Key ID'
    }
}
