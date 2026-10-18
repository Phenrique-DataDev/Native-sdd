<#
.SYNOPSIS
  Função PURA do bootstrap remoto: monta a URL de download do conteúdo (codeload.github.com).

.DESCRIPTION
  Existe SÓ para os testes Pester importarem (onboarding/tests/bootstrap.Tests.ps1). O script de
  execução (onboarding/bootstrap.ps1) NÃO faz dot-source daqui: ele roda ANTES de qualquer arquivo
  existir em disco (irm <raw>/bootstrap.ps1 | iex) e por isso embute a mesma lógica inline —
  duplicação intencional, documentada no DESIGN_BOOTSTRAP_REMOTO (Decisão 6 + nota de
  auto-suficiência); não é bug a "corrigir" removendo a duplicação.

  Dot-source: só DEFINE a função (sem efeitos colaterais ao carregar).
#>

Set-StrictMode -Version Latest

function Get-BootstrapDownloadUrl {
    <#
    .SYNOPSIS
      URL do codeload.github.com p/ baixar <Ref> de <Owner>/<Repo> como zip|tar.gz. Pura: string
      building, nunca lança, determinística (mesma entrada -> mesma URL), sempre https:// (AT-004).
    .DESCRIPTION
      Defaults hardcoded apontam ao espelho público Phenrique-DataDev/Native-sdd — trocar
      Owner/Repo exige parâmetro explícito (Decisão 6: o default nunca aponta ao canônico privado).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Owner = 'Phenrique-DataDev',
        [string]$Repo = 'Native-sdd',
        [string]$Ref = 'main',
        [string]$Format = 'zip'          # 'zip' | 'tar.gz'
    )
    return "https://codeload.github.com/$Owner/$Repo/$Format/refs/heads/$Ref"
}

# Cópia EXATA da função inline em onboarding/bootstrap.ps1 (por isso só ASCII, como lá) — o teste
# de paridade em onboarding/tests/bootstrap.Tests.ps1 compara as duas pelo texto do AST.
function Test-BootstrapNonInteractive {
    # $true quando o processo foi aberto para rodar um comando e sair (-Command, -File,
    # -EncodedCommand, -NonInteractive): ai o exit fixa o exit code do processo, que a automacao
    # le. Sem essas flags, ou com -NoExit, a sessao e interativa e o exit fecharia a janela de quem
    # colou o "irm | iex". Aceita os prefixos que o host aceita (-c, -f, -e, -ec, -noni, -noe) e
    # os separadores -, -- e /. O que vem depois de -Command/-File e o comando, nao flag do host.
    param([string[]]$CommandLineArgs)
    $runsAndExits = $false
    foreach ($arg in @($CommandLineArgs | Select-Object -Skip 1)) {
        if ($arg -notmatch '^(--|-|/)([A-Za-z]+)$') { continue }
        $word = $Matches[2].ToLowerInvariant()
        if ($word.Length -ge 3 -and 'noexit'.StartsWith($word, [System.StringComparison]::Ordinal)) { return $false }
        if ($word.Length -ge 4 -and 'noninteractive'.StartsWith($word, [System.StringComparison]::Ordinal)) { $runsAndExits = $true; continue }
        if ($word -eq 'ec' -or
            'command'.StartsWith($word, [System.StringComparison]::Ordinal) -or
            'file'.StartsWith($word, [System.StringComparison]::Ordinal) -or
            'encodedcommand'.StartsWith($word, [System.StringComparison]::Ordinal)) { $runsAndExits = $true; break }
    }
    return $runsAndExits
}
