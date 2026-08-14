# Configuração do PSScriptAnalyzer para o instalador.
# Exclusões conscientes (by-design), com justificativa — não escondem bugs.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # CLI de console: saída colorida/UX é intencional via Write-Host.
        'PSAvoidUsingWriteHost',
        # Instalação oficial do Claude Code: `irm <url-oficial> | iex` (URL fixa).
        'PSAvoidUsingInvokeExpression',
        # New-InstallSummary é factory (retorna hashtable); não altera estado.
        'PSUseShouldProcessForStateChangingFunctions',
        # Nomes de domínio (ex.: Invoke-InstallClis, Test-CommandExists).
        'PSUseSingularNouns',
        # Alvo é PowerShell 7+ (UTF-8 nativo); BOM desnecessário.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
