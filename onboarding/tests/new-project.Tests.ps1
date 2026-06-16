# Pester 5 — E2E do new-project.ps1: WARN acionável quando o projeto é criado SEM repo git.
# Fecha o achado do eixo 4 da validação E2E (idea #7): sem -Git, o pre-commit anti-segredo
# (core.hooksPath) era pulado EM SILÊNCIO. Agora avisa com a próxima ação concreta.
# Rodar:  Invoke-Pester onboarding/tests/new-project.Tests.ps1

BeforeAll {
    $script:newProject = (Resolve-Path (Join-Path $PSScriptRoot '..\new-project.ps1')).Path
}

Describe 'new-project — pre-commit anti-segredo sem -Git (idea #7)' {
    It 'sem -Git e sem repo git → WARN com a ação (git config core.hooksPath .githooks)' {
        $proj = Join-Path $TestDrive ([guid]::NewGuid())
        $out = & pwsh -NoProfile -File $script:newProject -Path $proj 2>&1 | Out-String

        $out | Should -Match 'core\.hooksPath \.githooks'   # a próxima ação concreta
        $out | Should -Match '(?i)pre-commit'               # explica o que ficou inativo
        # não virou repo git por conta própria (não pedimos -Git):
        (Test-Path -LiteralPath (Join-Path $proj '.git')) | Should -BeFalse
    }

    It 'o scaffold foi espelhado mesmo sem git (CLAUDE.md na raiz)' {
        $proj = Join-Path $TestDrive ([guid]::NewGuid())
        & pwsh -NoProfile -File $script:newProject -Path $proj 2>&1 | Out-Null
        Test-Path -LiteralPath (Join-Path $proj 'CLAUDE.md') | Should -BeTrue
    }

    It '-DryRun sem -Git → mostra a dica como DRY (não escreve, não vira WARN de execução)' {
        $proj = Join-Path $TestDrive ([guid]::NewGuid())
        $out = & pwsh -NoProfile -File $script:newProject -Path $proj -DryRun 2>&1 | Out-String
        $out | Should -Match 'core\.hooksPath \.githooks'
        # DryRun nunca cria o diretório-alvo
        (Test-Path -LiteralPath $proj) | Should -BeFalse
    }
}
