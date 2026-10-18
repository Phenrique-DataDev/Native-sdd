<#
.SYNOPSIS
  Funções PURAS do bootstrap remoto: separar o opt-in -Ref dos args, ler o tag_name da última
  release e montar a URL de download do conteúdo (codeload.github.com).

.DESCRIPTION
  Existe SÓ para os testes Pester importarem (onboarding/tests/bootstrap.Tests.ps1). O script de
  execução (onboarding/bootstrap.ps1) NÃO faz dot-source daqui: ele roda ANTES de qualquer arquivo
  existir em disco (irm <raw>/bootstrap.ps1 | iex) e por isso embute as mesmas funções inline —
  duplicação intencional, documentada no DESIGN_BOOTSTRAP_REMOTO (Decisão 6 + nota de
  auto-suficiência); não é bug a "corrigir" removendo a duplicação. Cada função abaixo é cópia
  EXATA da inline (por isso o corpo é só ASCII, como lá) — o teste de paridade compara o texto do AST.

  Desde 2026-10-18 (BOOTSTRAP_BAIXA_A_MAIN) o padrão é a última release com tag, não a main: a
  Decisão 1 do DESIGN_BOOTSTRAP_REMOTO foi revertida (ver o .NOTES do bootstrap.ps1).

  Dot-source: só DEFINE as funções (sem efeitos colaterais ao carregar).
#>

Set-StrictMode -Version Latest

function Split-BootstrapArgs {
    # Separa o opt-in "-Ref <branch>" (consumido aqui) dos args que seguem para o install.ps1.
    # Sem -Ref, Ref volta vazio = ultima release. "-Ref:main" chega como "-Ref:" + "main" (medido
    # em 2026-10-18 no pwsh 7 e no 5.1), por isso os dois tokens levam o valor seguinte.
    param([object[]]$InputArgs)
    $ref = ''
    $rest = @()
    $list = @($InputArgs)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $token = $list[$i]
        if ($token -is [string] -and ($token -eq '-Ref' -or $token -eq '-Ref:')) {
            if ($i + 1 -ge $list.Count) { throw '-Ref exige um valor (ex.: -Ref main)' }
            $i++
            $ref = [string]$list[$i]
            if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { throw "-Ref com valor invalido: '$ref' (ex.: -Ref main)" }
            continue
        }
        $rest += , $token
    }
    return @{ Ref = $ref; Rest = $rest }
}

function Get-BootstrapTagName {
    # tag_name do JSON de /releases/latest da API do GitHub, ou $null se faltar ou for invalido.
    # Regex (nao ConvertFrom-Json) de proposito: e a mesma leitura do bootstrap.sh (sed, sem jq).
    param([string]$Json)
    if ($Json -match '"tag_name"\s*:\s*"([A-Za-z0-9._-]+)"') { return $Matches[1] }
    return $null
}

function Get-BootstrapDownloadUrl {
    # URL do codeload.github.com: refs/tags/<Tag> (o padrao, a ultima release) ou refs/heads/<Branch>
    # (opt-in explicito, -Ref main). Pura: so monta string, nunca lanca, sempre https:// (AT-004).
    # Sem Tag nem Branch devolve $null - nunca cai na main por omissao. Owner/Repo default = espelho
    # publico (Decisao 6: o default nunca aponta ao canonico privado).
    param(
        [string]$Owner = 'Phenrique-DataDev',
        [string]$Repo = 'Native-sdd',
        [string]$Tag = '',
        [string]$Branch = '',
        [string]$Format = 'zip'
    )
    if ($Branch) { return "https://codeload.github.com/$Owner/$Repo/$Format/refs/heads/$Branch" }
    if ($Tag) { return "https://codeload.github.com/$Owner/$Repo/$Format/refs/tags/$Tag" }
    return $null
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
