# Pester 5 — lib unica de deteccao de segredos (fonte de verdade #4).
# Rodar:  Invoke-Pester onboarding/tests/secret-patterns.Tests.ps1

BeforeAll {
    $lib = Join-Path $PSScriptRoot '..\..\templates\global-claude\hooks\lib\secret-patterns.ps1'
    . $lib
}

Describe 'Get-MaskedSample' {
    It 'mascara mantendo no maximo 4 chars + estrelas (nao vaza o segredo)' {
        $m = Get-MaskedSample 'AKIAIOSFODNN7EXAMPLE'
        $m | Should -Match '^AKIA\*+$'
        $m | Should -Not -Match 'IOSFODNN7EXAMPLE'
    }
    It 'trata curto/vazio' {
        Get-MaskedSample ''    | Should -Be ''
        Get-MaskedSample 'ab'  | Should -Be '**'
    }
}

Describe 'Test-IsSecretFilePath' {
    It 'reconhece arquivos de segredo' {
        Test-IsSecretFilePath '.env'              | Should -BeTrue
        Test-IsSecretFilePath 'config/.env.local' | Should -BeTrue
        Test-IsSecretFilePath 'deploy/id_rsa'     | Should -BeTrue
        Test-IsSecretFilePath 'certs/server.pem'  | Should -BeTrue
        Test-IsSecretFilePath 'secrets/token.txt' | Should -BeTrue
        Test-IsSecretFilePath 'app\secret.key'    | Should -BeTrue   # separador Windows
    }
    It 'nao confunde arquivos comuns' {
        Test-IsSecretFilePath 'README.md'        | Should -BeFalse
        Test-IsSecretFilePath 'src/env.ts'       | Should -BeFalse   # nao é .env
        Test-IsSecretFilePath 'docs/.envrc.md'   | Should -BeFalse
        Test-IsSecretFilePath ''                 | Should -BeFalse
    }
}

Describe 'Find-SecretMatch' {
    It 'detecta credenciais de ALTA confianca' {
        (Find-SecretMatch -Text 'AKIAIOSFODNN7EXAMPLE').Count | Should -BeGreaterThan 0
        (Find-SecretMatch -Text 'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa').Count | Should -BeGreaterThan 0
        (Find-SecretMatch -Text '-----BEGIN RSA PRIVATE KEY-----').Count | Should -BeGreaterThan 0
    }
    It 'amostra vem MASCARADA (nunca o valor cru)' {
        $hit = Find-SecretMatch -Text 'AKIAIOSFODNN7EXAMPLE' | Select-Object -First 1
        $hit.Sample | Should -Not -Be 'AKIAIOSFODNN7EXAMPLE'
        $hit.Sample | Should -Match '\*'
    }
    It 'atribuicao generica é MEDIUM (pega no default, ignora em High)' {
        $text = 'api_key = "abcdefghijklmnop1234"'
        (Find-SecretMatch -Text $text -MinConfidence 'Medium').Count | Should -BeGreaterThan 0
        (Find-SecretMatch -Text $text -MinConfidence 'High').Count   | Should -Be 0
    }
    It 'texto limpo / vazio -> nenhum achado' {
        (Find-SecretMatch -Text 'apenas um texto inocente aqui').Count | Should -Be 0
        (Find-SecretMatch -Text '').Count   | Should -Be 0
        (Find-SecretMatch -Text $null).Count | Should -Be 0
    }
}

Describe 'Test-TextHasSecret' {
    It 'bool conveniente sobre Find-SecretMatch' {
        Test-TextHasSecret -Text 'AKIAIOSFODNN7EXAMPLE' | Should -BeTrue
        Test-TextHasSecret -Text 'nada aqui'            | Should -BeFalse
    }
}

Describe 'Anti-drift da fonte unica (#4)' {
    It 'a copia vendorizada no scaffold é IDENTICA a lib canonica' {
        # Garante que .githooks/secret-patterns.ps1 (usada pelo pre-commit) nao divergiu da
        # canonica (usada pelos hooks do Claude). Fonte unica logica, copia guardada por teste.
        $canonical = Join-Path $PSScriptRoot '..\..\templates\global-claude\hooks\lib\secret-patterns.ps1'
        $vendored  = Join-Path $PSScriptRoot '..\..\templates\project-scaffold\.githooks\secret-patterns.ps1'
        Test-Path -LiteralPath $vendored | Should -BeTrue
        (Get-FileHash -LiteralPath $canonical).Hash | Should -Be (Get-FileHash -LiteralPath $vendored).Hash
    }
}
