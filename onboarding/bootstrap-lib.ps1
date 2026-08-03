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
