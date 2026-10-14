<#
.SYNOPSIS
    Acusa script PowerShell que tem caractere não-ASCII mas NÃO tem BOM UTF-8 — a combinação que
    quebra o parser do Windows PowerShell 5.1.

    ACHADO EM USO REAL (2026-07-20): um usuário rodou o bootstrap remoto e a instalação morreu na
    etapa final. Causa: `onboarding/windows/lib.ps1` (e mais 96 arquivos) tinham acento SEM BOM. O
    5.1 lê arquivo sem BOM como ANSI (code page do sistema), então "órfãos" vira "Ã³rfÃ£os", a aspa
    curva U+201D vira delimitador de string, e o parse do arquivo INTEIRO explode antes de qualquer
    linha executar. O bootstrap delega ao install.ps1 usando o MESMO host que o invocou — e a porta
    de entrada documentada no README é `irm | iex`, que a maioria cola num powershell.exe 5.1.

    Por que ninguém viu antes: todo o desenvolvimento e o CI rodam em pwsh 7, que assume UTF-8 sem
    BOM por padrão e nunca reproduz a falha. O bug só existe no runtime do usuário.

.DESCRIPTION
    Regra única, binária e barata (lê 3 bytes + faz um match por arquivo):

      no-bom-utf8 : arquivo .ps1/.psd1/.psm1 contém byte >= 0x80 e não começa com EF BB BF.

      bom-antes-do-frontmatter : arquivo .md que COMEÇA com BOM e cuja primeira linha (depois dele)
                                 é `---`. É a regra INVERSA da de cima, e cada uma vale no seu
                                 formato: no script o BOM é obrigatório (o 5.1 lê ANSI sem ele); no
                                 .md com frontmatter ele é FATAL — o parser do harness exige `---` no
                                 byte 0, e o BOM ocupa os três primeiros.

                                 MEDIDO EM RUNTIME (2026-08-19), com dois arquivos idênticos exceto
                                 pelo BOM: em `.claude/commands/` o command com BOM é listado com
                                 `description` = "---" (o parser caiu para a 1ª linha do corpo) e
                                 TODO o frontmatter é ignorado; empacotado como plugin, ele nem
                                 aparece na lista de skills. Seis commands do scaffold estavam assim,
                                 e um deles (`supplements.md`) carregava `disable-model-invocation`
                                 desde a v0.10.6 — decisão de produto medida, e inerte no disco.

    Escopo: `.ps1` / `.psd1` / `.psm1` / `.md` que o git reconhece como NOSSOS — rastreados **e** untracked
    não-ignorados (ver `Get-EncodingLintTarget`; o untracked entrou na v0.9.7, depois de um arquivo
    novo sem BOM atravessar um gate verde). Arquivos 100% ASCII são ignorados de
    propósito — sem caractere não-ASCII não há ambiguidade de encoding, e exigir BOM neles só criaria
    ruído (é o caso de `onboarding/bootstrap.ps1`, que é ASCII-only por decisão de design justamente
    porque é servido como texto cru via HTTP e avaliado com Invoke-Expression).

    Severidade só `error`: o alvo é determinístico e a consequência é um script que não parseia.
    Shape canônico dos demais lints (New-*Finding / Get-*Findings / Format-* / Test-*Gate / Invoke-*).

    Correção: `pwsh tools/encoding-lint.ps1 -Fix` (opt-in, porque escreve em arquivo). Repara
    exatamente os arquivos que a regra acusa, prefixando os 3 bytes do BOM — sem decodificar,
    reencodar ou normalizar EOL. RECUSA arquivo cujos bytes não sejam UTF-8 válido: ali o BOM
    mentiria sobre o encoding. Ver a seção `-Fix` no fim deste arquivo.

    O -Fix existe porque a causa NÃO é esquecimento: a ferramenta de escrita do agente não emite
    BOM (medido, 2026-08-04 — `BOM_NAO_NASCE_COM_ARQUIVO`). Lembrete não muda o que ela grava.

    Sem pwsh à mão, o equivalente manual (só para arquivo comprovadamente UTF-8):
      $b = [System.IO.File]::ReadAllBytes(<arquivo>)
      [System.IO.File]::WriteAllBytes(<arquivo>, ([byte[]](0xEF,0xBB,0xBF) + $b))
#>

# PARÂMETROS DE SCRIPT — e um cuidado que NÃO é cosmético no nome.
# Este arquivo é DOT-SOURCED pelo `check.ps1`, e dot-source cria as variáveis do `param()` no escopo
# do CHAMADOR. Um `-RepoRoot` aqui nasceria como `''` dentro do `check.ps1`, que mantém o seu próprio
# `$script:RepoRoot` — e os scriptblocks de todos os 11 lints o leem. Por isso `-RepoPath`: nome que
# não colide com nada do chamador. Antes de renomear, confira o escopo de quem dot-sourceia.
param(
    [switch]$Fix,
    [string]$RepoPath
)

Set-StrictMode -Version Latest

function New-EncodingFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Test-FileNeedsBom {
    <#
    .SYNOPSIS  PURA (dado o conteúdo em bytes): $true se o arquivo tem não-ASCII e não tem BOM UTF-8.
    .DESCRIPTION
        Opera sobre BYTES, nunca sobre string decodificada — decodificar já aplicaria uma suposição de
        encoding e apagaria justamente o sinal que queremos medir.
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    if ($Bytes.Count -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return $false   # já tem BOM
    }
    foreach ($b in $Bytes) { if ($b -ge 0x80) { return $true } }
    return $false       # ASCII puro — sem ambiguidade, nada a exigir
}

function Test-BomBeforeFrontmatter {
    <#
    .SYNOPSIS  PURA (dado o conteúdo em bytes): $true se o arquivo começa com BOM UTF-8 e a primeira
               linha DEPOIS dele é o delimitador `---` de frontmatter.
    .DESCRIPTION
        A regra inversa do `Test-FileNeedsBom`, e o motivo de as duas conviverem está no formato: o
        parser de frontmatter do harness exige `---` no **byte 0**, e o BOM ocupa os três primeiros.

        Só acusa quando HÁ frontmatter — `.md` de prosa (README, rules, posturas) começa com BOM sem
        prejuízo nenhum, e reprová-los seria ruído sobre dezenas de arquivos corretos.

        Opera sobre BYTES pelo mesmo motivo da função vizinha: a pergunta é sobre os três primeiros
        bytes, e decodificar antes apagaria o sinal.
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    if ($Bytes.Count -lt 6) { return $false }
    if (-not ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)) { return $false }

    # Primeira linha depois do BOM: precisa ser exatamente `---` (com \r opcional).
    if (-not ($Bytes[3] -eq 0x2D -and $Bytes[4] -eq 0x2D -and $Bytes[5] -eq 0x2D)) { return $false }
    if ($Bytes.Count -eq 6) { return $true }
    $next = $Bytes[6]
    return ($next -eq 0x0A -or $next -eq 0x0D)
}

function Get-EncodingLintTarget {
    <#
    .SYNOPSIS  I/O: caminhos absolutos dos scripts PowerShell NOSSOS (versionados ou por versionar).
    .DESCRIPTION
        `git ls-files` em vez de Get-ChildItem: pega só o que é NOSSO. Sem isso, um
        `.venv/Scripts/activate.ps1` de dependência de terceiro entraria no gate e o reprovaria por
        um arquivo que não podemos consertar (achado ao montar este lint).

        DUAS listas, não uma (v0.9.7): `ls-files` sozinho enumera só o RASTREADO, e um arquivo novo
        ainda fora do índice ficava INVISÍVEL para o gate — justo na janela em que consertar é
        barato. Foi o que aconteceu com `tools/tests/sdd-templates.Tests.ps1` na v0.9.5: gravado sem
        BOM, `check.ps1` marcou "TUDO VERDE - 12 checks" e o defeito foi commitado; só apareceu no
        gate seguinte, depois de entrar no índice. `--others` acrescenta o untracked e
        `--exclude-standard` mantém de fora o que o .gitignore já exclui — ou seja, o `.venv` segue
        excluído e o motivo original do `ls-files` continua honrado.

        Por que NÃO reusar `Select-NotGitIgnored` (pii-lint), que é fonte única para "o que o git
        ignora": ela filtra uma lista JÁ enumerada do disco, o que exigiria varrer a working tree
        inteira (incluindo os ~3k arquivos do `.venv`) só para descartá-los depois. Aqui o próprio
        git faz a exclusão na origem, sem enumerar. Caminhos diferentes para necessidades diferentes.
    .OUTPUTS   [string[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    # `.md` entra pela regra `bom-antes-do-frontmatter` — o BOM lá é o oposto do que se quer. As duas
    # regras convivem no mesmo lint porque a pergunta é a mesma (os 3 primeiros bytes); a resposta
    # certa é que muda com o formato.
    $globs = @('*.ps1', '*.psd1', '*.psm1', '*.md')

    $tracked = & git -C $RepoRoot ls-files @globs 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    # untracked NÃO-ignorado: o arquivo novo que ainda não foi `git add`-ado entra no gate igual.
    $untracked = & git -C $RepoRoot ls-files --others --exclude-standard @globs 2>$null
    if ($LASTEXITCODE -ne 0) { $untracked = @() }

    $all = @($tracked) + @($untracked)
    if (-not $all) { return @() }

    $paths = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($rel in $all) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if ($seen.ContainsKey($rel)) { continue }   # um path não pode ser rastreado E untracked, mas não dependa disso
        $seen[$rel] = $true
        $full = Join-Path $RepoRoot $rel
        if (Test-Path -LiteralPath $full -PathType Leaf) { $paths.Add($full) }
    }
    return $paths.ToArray()
}

function Get-EncodingFindings {
    <#
    .SYNOPSIS  I/O fino: lê os bytes de cada alvo e devolve um finding por arquivo sem BOM.
    .OUTPUTS   [pscustomobject[]] (vazio = tudo certo).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        [string]$RepoRoot
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $Path) {
        try { $bytes = [System.IO.File]::ReadAllBytes($file) }
        catch { continue }   # ilegível == fora do escopo; não é papel deste lint reportar I/O

        $rel = if ($RepoRoot) { $file.Substring($RepoRoot.TrimEnd('\', '/').Length).TrimStart('\', '/') } else { $file }

        # `.md`: a regra é a INVERSA da de baixo. O BOM antes de `---` cega o parser de frontmatter
        # do harness — medido em runtime, não deduzido (ver o cabeçalho).
        if ([System.IO.Path]::GetExtension($file) -eq '.md') {
            if (Test-BomBeforeFrontmatter -Bytes $bytes) {
                $findings.Add((New-EncodingFinding -Severity error -Rule bom-antes-do-frontmatter -Path "$rel#/" `
                            -Message 'começa com BOM UTF-8 antes do frontmatter — o parser do harness exige `---` no byte 0; com o BOM ele ignora o frontmatter INTEIRO (a description vira "---", e campos como disable-model-invocation ficam inertes). Regrave como UTF-8 SEM BOM'))
            }
            continue
        }

        if (-not (Test-FileNeedsBom -Bytes $bytes)) { continue }
        $findings.Add((New-EncodingFinding -Severity error -Rule no-bom-utf8 -Path "$rel#/" `
                    -Message 'tem caractere não-ASCII sem BOM UTF-8 — o Windows PowerShell 5.1 lê como ANSI e o parse do arquivo inteiro falha; regrave como "UTF-8 with BOM"'))
    }
    return $findings.ToArray()
}

function Format-EncodingLintReport {
    <# .SYNOPSIS  Painel legível dos achados. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'encoding-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $file = ($f.Path -split '#', 2)[0]
        $lines.Add("    [$($f.Severity)] $($f.Rule) $file — $($f.Message)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-EncodingLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (reprova o check). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-EncodingLint {
    <#
    .SYNOPSIS  Entrada de alto nível: descobre os alvos e devolve os achados.
    .OUTPUTS   [pscustomobject[]] de achados (vazio = tudo com BOM).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $targets = @(Get-EncodingLintTarget -RepoRoot $RepoRoot)
    return @(Get-EncodingFindings -Path $targets -RepoRoot $RepoRoot)
}

# =================================================================================================
#  -Fix — a contramedida NA ORIGEM (BOM_NAO_NASCE_COM_ARQUIVO, direção (a), 2026-08-04)
# =================================================================================================
#  POR QUE EXISTE, e por que NÃO é "lembrar de gravar com BOM": a ferramenta de escrita do agente
#  NÃO EMITE BOM. Medido por sonda em 2026-08-04 — um `.ps1` com acento gravado por ela começa em
#  `23 20 73…`, sem `EF BB BF`, e `Test-FileNeedsBom` devolve `$true`. É propriedade do ESCRITOR,
#  não da memória de quem escreve; por isso a forma é uma correção determinística, não um aviso.
#
#  4 ocorrências registradas: `sdd-templates.Tests.ps1` (v0.9.5, COMMITADO sem BOM),
#  `destructive-patterns.ps1`, `harness-export.Tests.ps1` e `baseline-junk.Tests.ps1` (2026-08-04).
#  O lint acusou as 4 — o que faltava era o passo seguinte.
#
#  O QUE ISTO NÃO É: não torna o `check.ps1` bloqueante (a postura low-friction fica), não roda
#  sozinho (é opt-in por flag, porque escreve em arquivo) e não toca arquivo ASCII-puro — senão
#  reprovaria a decisão de design do `onboarding/bootstrap.ps1`, que é ASCII por ser servido cru.

function Test-IsValidUtf8 {
    <#
    .SYNOPSIS  PURA (sobre bytes): $true se a sequência decodifica como UTF-8 estrito.
    .DESCRIPTION
        GUARDA DE SEGURANÇA DO -Fix, e a razão dela é o modo de falha silencioso: carimbar um BOM
        UTF-8 em bytes que NÃO são UTF-8 (um arquivo salvo em ANSI/Latin-1, onde `é` é o byte 0xE9
        solto) transforma uma falha barulhenta — o 5.1 explodindo no parse — numa MENTIRA sobre o
        encoding, que o 7 passaria a ler com caractere de substituição. O lint acusa os dois casos
        igual; só o primeiro é seguro de reparar automaticamente.

        `UTF8Encoding($false, $true)` = sem BOM na saída, LANÇA em byte inválido (o default engole
        e devolve U+FFFD, que é exatamente o silêncio que não queremos).
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    try {
        $strict = New-Object System.Text.UTF8Encoding $false, $true
        $null = $strict.GetString($Bytes)
        return $true
    }
    catch { return $false }
}

function Repair-FileBom {
    <#
    .SYNOPSIS  EFEITO (1 arquivo): prefixa o BOM UTF-8, se e só se faltar e os bytes forem UTF-8 válido.
    .DESCRIPTION
        ADITIVA POR CONSTRUÇÃO — lê os BYTES, prefixa `EF BB BF`, grava os bytes. Não decodifica
        para string, não reencoda, não normaliza EOL. A receita antiga do cabeçalho deste arquivo
        (`Get-Content -Raw` + `WriteAllText`) faz um roundtrip decode/encode que PRESSUPÕE que o
        arquivo já é UTF-8 — para um arquivo ANSI ela corrompe em silêncio, e é justamente o caso
        que `Test-IsValidUtf8` recusa aqui. Prefixar bytes declara o encoding que o arquivo já tem,
        sem inventar nenhum.
    .OUTPUTS   [pscustomobject] Path · Repaired [bool] · Reason [string]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    $result = { param($r, $why) [pscustomobject]@{ Path = $Path; Repaired = $r; Reason = $why } }

    try { $bytes = [System.IO.File]::ReadAllBytes($Path) }
    catch { return (& $result $false 'ilegível') }

    if (-not (Test-FileNeedsBom -Bytes $bytes)) { return (& $result $false 'nada a fazer (já tem BOM, ou é ASCII puro)') }
    if (-not (Test-IsValidUtf8 -Bytes $bytes)) { return (& $result $false 'NÃO reparável: os bytes não são UTF-8 válido — carimbar o BOM aqui mentiria sobre o encoding; converta o arquivo à mão') }

    if (-not $PSCmdlet.ShouldProcess($Path, 'prefixar BOM UTF-8')) { return (& $result $false 'ShouldProcess negado') }

    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $out = New-Object byte[] ($bom.Length + $bytes.Length)
    [System.Array]::Copy($bom, 0, $out, 0, $bom.Length)
    [System.Array]::Copy($bytes, 0, $out, $bom.Length, $bytes.Length)
    try { [System.IO.File]::WriteAllBytes($Path, $out) }
    catch { return (& $result $false "falha ao gravar: $($_.Exception.Message)") }

    return (& $result $true 'BOM UTF-8 acrescentado')
}

function Repair-MdFrontmatterBom {
    <#
    .SYNOPSIS  EFEITO (1 arquivo .md): REMOVE o BOM UTF-8 que precede o frontmatter.
    .DESCRIPTION
        A operação inversa do `Repair-FileBom`, e igualmente byte-a-byte: corta os três primeiros
        bytes e regrava. Não decodifica, não reencoda, não normaliza EOL — o conteúdo depois do BOM
        é UTF-8 por construção (o BOM o declarava), então retirá-lo não muda nenhum caractere.

        Só age quando `Test-BomBeforeFrontmatter` acusa: `.md` de prosa com BOM fica intocado.
    .OUTPUTS   [pscustomobject] Path · Repaired [bool] · Reason [string]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    $result = { param($r, $why) [pscustomobject]@{ Path = $Path; Repaired = $r; Reason = $why } }

    try { $bytes = [System.IO.File]::ReadAllBytes($Path) }
    catch { return (& $result $false 'ilegível') }

    if (-not (Test-BomBeforeFrontmatter -Bytes $bytes)) { return (& $result $false 'nada a fazer (sem BOM antes do frontmatter)') }
    if (-not $PSCmdlet.ShouldProcess($Path, 'remover BOM UTF-8 antes do frontmatter')) { return (& $result $false 'ShouldProcess negado') }

    $out = New-Object byte[] ($bytes.Length - 3)
    [System.Array]::Copy($bytes, 3, $out, 0, $out.Length)
    try { [System.IO.File]::WriteAllBytes($Path, $out) }
    catch { return (& $result $false "falha ao gravar: $($_.Exception.Message)") }

    return (& $result $true 'BOM UTF-8 removido (o frontmatter volta a ser lido pelo harness)')
}

function Invoke-EncodingLintFix {
    <#
    .SYNOPSIS  Entrada de alto nível do -Fix: repara todo alvo que o lint acusaria.
    .DESCRIPTION
        Mesma descoberta de alvos do `Invoke-EncodingLint` (`Get-EncodingLintTarget`) — fonte única.
        Reparar o que o lint acusa e nada mais é a invariante: se as duas listas divergirem, o -Fix
        vira uma segunda opinião sobre o que é NOSSO, e aí o `.venv` de terceiro volta ao escopo.
    .OUTPUTS   [pscustomobject[]] — SÓ os arquivos em que houve tentativa (acusados pelo lint).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-EncodingLintTarget -RepoRoot $RepoRoot)) {
        try { $bytes = [System.IO.File]::ReadAllBytes($file) } catch { continue }

        # `.md` acusado pela regra inversa: aqui reparar é TIRAR o BOM, não pôr.
        if ([System.IO.Path]::GetExtension($file) -eq '.md') {
            if (Test-BomBeforeFrontmatter -Bytes $bytes) { $results.Add((Repair-MdFrontmatterBom -Path $file)) }
            continue
        }

        if (-not (Test-FileNeedsBom -Bytes $bytes)) { continue }   # não acusado: fora do escopo do fix
        $results.Add((Repair-FileBom -Path $file))
    }
    return $results.ToArray()
}

function Format-EncodingFixReport {
    <# .SYNOPSIS  Painel legível do -Fix. Distingue reparado de RECUSADO — recusa não é sucesso. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)

    $r = @($Results)
    if ($r.Count -eq 0) { return 'encoding-lint -Fix: nada a reparar (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $r) {
        $tag = if ($x.Repaired) { '[ OK ]' } else { '[FALHA]' }
        $lines.Add("    $tag $($x.Path) — $($x.Reason)")
    }
    $ok = @($r | Where-Object { $_.Repaired }).Count
    $lines.Add("encoding-lint -Fix: $ok reparado(s), $($r.Count - $ok) recusado(s) de $($r.Count) achado(s)")
    return ($lines -join [Environment]::NewLine)
}

# --- Execução como script (`pwsh tools/encoding-lint.ps1 -Fix`) ----------------------------------
# O guard existe porque este arquivo é DOT-SOURCED pelo `check.ps1` — sem ele, o gate passaria a
# escrever em arquivo. MEDIDO em 2026-08-04, porque eu tinha escrito aqui o contrário e era falso:
# sob dot-source o `InvocationName` é `'.'` mesmo quando o caminho vem de `Join-Path` (a forma que
# o `check.ps1` usa); executado como script, é o caminho completo. Ou seja, este teste basta — é o
# mesmo dos outros 7 tools do repo, e não há motivo para divergir. Removê-lo reprova FIX-14.
if ($MyInvocation.InvocationName -ne '.') {
    $root = if ($RepoPath) { (Resolve-Path -LiteralPath $RepoPath).Path } else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
    # O `@()` em volta das duas chamadas NÃO é cosmético: `return $x.ToArray()` com array VAZIO não
    # emite nada no pipeline, e a variável fica `$null` — não uma lista de 0 itens. Os `Format-*`
    # aceitam coleção vazia (`AllowEmptyCollection`) mas NÃO `$null`, então o caminho FELIZ (nada a
    # reparar) explodia com "Cannot bind argument to parameter 'Results' because it is null".
    # Achado ao rodar o `-Fix` neste próprio repositório, que está limpo — o caso que nenhum teste
    # cobria porque todos os cenários tinham achado. Trava: FIX-15/FIX-16.
    if ($Fix) {
        $res = @(Invoke-EncodingLintFix -RepoRoot $root)
        Format-EncodingFixReport -Results $res | Write-Host
        exit $(if (@($res | Where-Object { -not $_.Repaired }).Count -gt 0) { 1 } else { 0 })
    }
    $findings = @(Invoke-EncodingLint -RepoRoot $root)
    Format-EncodingLintReport -Findings $findings | Write-Host
    exit $(if (Test-EncodingLintGate -Findings $findings) { 0 } else { 1 })
}
