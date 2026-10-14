<#
.SYNOPSIS
    Lint estático dos arquivos de config do Claude Code versionados (settings.json /
    managed-settings.json): pega config arriscada antes de versionar/instalar.

.DESCRIPTION
    Funções PURAS (recebem texto/objeto JSON, sem tocar disco) que rodam 3 checks
    determinísticos + um parse. Espelha tools/kb-lint.ps1 e tools/agent-lint.ps1
    (sem módulo externo; ConvertFrom-Json nativo). Feature F5 — ver
    .claude/sdd/archive/config-lint/DESIGN_CONFIG_LINT.md.

    Checks (cada achado = { Rule; Severity; Path; Message }):
      - malformed   (error)  JSON sintaticamente inválido.
      - shape       (error)  forma inválida: permissions.allow|deny|ask não-array;
                             regra que não casa Tool / Tool(pattern) / "*"; regra com
                             parênteses vazios '()' (Claude rejeita "Empty parentheses");
                             hooks.<Event> não-array; hook sem type='command'/command.
                             Tools MCP (mcp__server__tool, mcp__server__*) são regras VÁLIDAS.
      - allow-broad (warn)   permissions.allow com pattern amplo ("*", Tool(*), Tool(:*),
                             mcp__server__*).
      - hook-risky  (warn)   comando de hook com padrão rede->shell (|iex, |bash/sh,
                             iwr/irm/curl/wget tubado). 'pwsh -NoProfile -File' é seguro.
      - path-rule-ignored (warn; error em deny)  regra de CAMINHO numa tool que o harness não
                             casa (Write/NotebookEdit/MultiEdit -> Edit, Glob -> Read): inerte.

    Severidade: error bloqueia o CI (gate); warn é advisory (reporta, não quebra).
    Proveniência do schema de permissions: context7 /anthropics/claude-code (2026-06-07) —
    regra Tool(pattern) com '*' em qualquer posição; wildcard total "*"; deny vence allow.
#>

Set-StrictMode -Version Latest

# Padrão seguro de regra de permissão: Tool nu (Read), Tool(pattern) (Bash(git:*)) — ou o wildcard
# total "*". O NOME da tool aceita '_' e '-' e pode terminar em '*': é o formato das tools MCP
# (mcp__context7__query-docs), incluindo os specs de servidor (mcp__server, mcp__server__*, mcp__*).
# Antes o nome era só [A-Za-z]+, o que reprovava TODA regra MCP como 'shape' (error) — falso positivo
# achado em uso real (2026-07-12) no próprio settings.local.json deste repo.
# Fonte: doc/CHANGELOG oficial do Claude Code via context7 (/anthropics/claude-code, 2026-07-12) —
# "Added wildcard syntax `mcp__server__*` for MCP tool permissions to allow or deny all tools".
$script:RuleFormat = '^[A-Za-z][A-Za-z0-9_-]*\*?(\(.*\))?$'
# Patterns de allow amplos (auto-aprovação): "*", Tool(*), Tool(:*) e o server-level de MCP
# (mcp__server__*, mcp__*) — auto-aprovar TODAS as tools de um servidor é amplo por definição.
$script:BroadAllow = @('^\*$', '^[A-Za-z0-9_-]+\(\*\)$', '^[A-Za-z0-9_-]+\(:\*\)$', '^mcp__.*\*$')
# Coringa no MEIO de uma regra Bash(...) -- classe que o $BroadAllow acima NAO modela: os quatro
# padroes dele sao ancorados nas PONTAS, entao amplitude no meio passava calada. O predicado abaixo
# nao e' heuristica: foi MEDIDO contra o harness (37 casos, 0 divergencias, 2026-09-01) rodando
# `claude -p` num projeto de laboratorio com cada regra no settings.local.json e lendo o aviso que
# ele emite no boot ("has a wildcard before the rest of the command").
#
# O que a medicao fixou, e que a heuristica obvia ("* que nao e' o ultimo caractere") errava:
#   - tokeniza por espaco; seja k o PRIMEIRO token que contem '*'.
#   - avisa se existe algum token DEPOIS de k que NAO contem '*'.
#   - vale so para Bash(...): Foo/Read/WebFetch com shape identico NAO sao avisados (medido).
# Por isso `Bash(pwsh -NoProfile -File ./tools/*.ps1 *)` -- a nossa convencao desde 2026-07-19 --
# fica LIMPA: o unico token depois do glob e' `*`, que tambem e' coringa. Era exatamente esse falso
# positivo que travava o item no backlog, e e' o mesmo custo que o `mcp__server__*` ja cobrou uma vez.
function Test-BashWildcardMid {
    <#
    .SYNOPSIS  PURA. A regra tem coringa no meio, no sentido que o harness reprova?
    .OUTPUTS   [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Rule)

    if ($Rule -notmatch '^Bash\((.*)\)$') { return $false }
    $tokens = @(($Matches[1] -split '\s+') | Where-Object { $_ -ne '' })

    $k = -1
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i].Contains('*')) { $k = $i; break }
    }
    if ($k -lt 0) { return $false }   # sem coringa: nao e' desta regra

    for ($i = $k + 1; $i -lt $tokens.Count; $i++) {
        if (-not $tokens[$i].Contains('*')) { return $true }
    }
    return $false
}

# Regra de CAMINHO que o harness nao casa -- medida em 2026-09-10 (CLI 2.1.267) no mesmo laboratorio
# do allow-wildcard-mid: `claude -p` num projeto temporario, cada rodada com um CONTROLE positivo no
# mesmo arquivo (uma regra invalida anula o bloco inteiro em silencio -- sem controle, silencio nao
# prova nada). 60 casos validos. O harness avisa no boot "<Tool>(x) is not matched by file permission
# checks -- only Edit(path) rules are" e a regra fica INERTE: com `deny: ["Write(secret.txt)"]` o
# Write criou o arquivo; com `deny: ["Edit(secret.txt)"]`, foi bloqueado.
#
# O que a medicao fixou:
#   - tools, com caixa: Write/NotebookEdit/MultiEdit -> Edit; Glob -> Read. Grep NAO e' avisado.
#   - vale em allow, deny e ask.
#   - conteudo exatamente '*' e' a tool inteira, nao caminho: nao avisa ('**', ' *', '*.txt' avisam).
#   - ':' antes da 1a '/' tira a regra do caso de caminho (a:b, x:*, ab:/x, C:), salvo letra de
#     unidade (C:/tmp, Z:/q); ':' depois da 1a '/' nao importa (//c/a:b, src/a:b.txt avisam). Esta
#     clausula foi ajustada DEPOIS de ver os dados, e so entrou apos 9/9 previsoes escritas baterem.
$script:PathRuleTarget = @{ Write = 'Edit'; NotebookEdit = 'Edit'; MultiEdit = 'Edit'; Glob = 'Read' }

function Get-IgnoredPathRuleTarget {
    <#
    .SYNOPSIS  PURA. A regra e' de caminho numa tool que o harness nao casa? Devolve a tool que
               casaria ('Edit' ou 'Read'), ou $null.
    .OUTPUTS   [string] ou $null
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Rule)

    # -c: o harness distingue caixa (write(...) e glob(...) nao sao avisados -- medido).
    if ($Rule -cnotmatch '^(Write|NotebookEdit|MultiEdit|Glob)\((.+)\)$') { return $null }
    $tool = $Matches[1]; $conteudo = $Matches[2]

    if ($conteudo -eq '*') { return $null }
    $primeiroSegmento = ($conteudo -split '/', 2)[0]
    if ($primeiroSegmento.Contains(':') -and $conteudo -notmatch '^[A-Za-z]:/') { return $null }
    return $script:PathRuleTarget[$tool]
}

# Comando de hook arriscado (rede->shell). Case-insensitive no uso.
$script:RiskyHook = @(
    '\|\s*(iex|invoke-expression)\b',          # tubo p/ Invoke-Expression
    '\|\s*(bash|sh)\b',                         # tubo p/ shell
    '\b(iwr|irm|curl|wget|invoke-webrequest)\b[^\r\n|]*\|'  # download tubado p/ outra coisa
)

function New-ConfigFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Test-IsJsonObject {
    <# .SYNOPSIS true se o valor é um objeto JSON (PSCustomObject), não array/escalar. #>
    param($Value)
    return $Value -is [System.Management.Automation.PSCustomObject]
}

function Get-JsonProperty {
    <#
    .SYNOPSIS valor de uma propriedade do objeto, ou $null se ausente (sem StrictMode throw).
    .NOTES   usa o operador vírgula p/ preservar arrays de 1 elemento (PowerShell desempacota
             coleções unitárias no return) — crítico p/ allow/deny/hooks com um único item.
    #>
    param($Object, [string]$Name)
    if (-not (Test-IsJsonObject $Object)) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    , $prop.Value
}

function Test-ConfigShape {
    <#
    .SYNOPSIS  Achados de forma inválida (severity 'error', rule 'shape').
    .OUTPUTS   [pscustomobject[]] (vazio se a forma é válida)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Json)

    $findings = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-IsJsonObject $Json)) {
        $findings.Add((New-ConfigFinding -Severity error -Rule shape -Path '/' `
                    -Message 'raiz do settings não é um objeto JSON'))
        return $findings.ToArray()
    }

    # permissions.allow|deny|ask
    $perms = Get-JsonProperty $Json 'permissions'
    if ($null -ne $perms) {
        if (-not (Test-IsJsonObject $perms)) {
            $findings.Add((New-ConfigFinding -Severity error -Rule shape -Path '/permissions' `
                        -Message "'permissions' não é um objeto"))
        }
        else {
            foreach ($key in @('allow', 'deny', 'ask')) {
                $rules = Get-JsonProperty $perms $key
                if ($null -eq $rules) { continue }
                if ($rules -isnot [array]) {
                    $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                -Path "/permissions/$key" -Message "'permissions.$key' não é um array"))
                    continue
                }
                for ($i = 0; $i -lt $rules.Count; $i++) {
                    $rule = $rules[$i]
                    if ($rule -isnot [string]) {
                        $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                    -Path "/permissions/$key/$i" -Message 'regra de permissão não é string'))
                    }
                    elseif ($rule -ne '*' -and $rule -notmatch $script:RuleFormat) {
                        $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                    -Path "/permissions/$key/$i" `
                                    -Message "regra fora do formato Tool / Tool(pattern): '$rule'"))
                    }
                    elseif ($rule -match '\(\)') {
                        # parênteses vazios () o parser do Claude rejeita ("Empty parentheses"):
                        # tanto Tool() quanto par vazio aninhado (ex.: Bash(:(){*) do fork bomb).
                        $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                    -Path "/permissions/$key/$i" `
                                    -Message "regra com parênteses vazios '()' (rejeitada pelo Claude): '$rule'"))
                    }
                }
            }
        }
    }

    # hooks.<Event>[] = { matcher, hooks:[{ type, command, timeout }] }
    $hooks = Get-JsonProperty $Json 'hooks'
    if ($null -ne $hooks) {
        if (-not (Test-IsJsonObject $hooks)) {
            $findings.Add((New-ConfigFinding -Severity error -Rule shape -Path '/hooks' `
                        -Message "'hooks' não é um objeto"))
        }
        else {
            # Itera a COLEÇÃO .Properties (não .Properties.Name): num objeto SEM propriedades
            # (ex.: "hooks": {}) acessar .Name lança sob StrictMode Latest; iterar a coleção
            # vazia simplesmente não itera.
            foreach ($prop in $hooks.PSObject.Properties) {
                $evt = $prop.Name
                $entries = $prop.Value
                if ($entries -isnot [array]) {
                    $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                -Path "/hooks/$evt" -Message "'hooks.$evt' não é um array"))
                    continue
                }
                for ($e = 0; $e -lt $entries.Count; $e++) {
                    $entry = $entries[$e]
                    $inner = Get-JsonProperty $entry 'hooks'
                    if ($inner -isnot [array]) {
                        $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                    -Path "/hooks/$evt/$e/hooks" -Message 'entrada de hook sem array hooks[]'))
                        continue
                    }
                    for ($h = 0; $h -lt $inner.Count; $h++) {
                        $hook = $inner[$h]
                        $type = Get-JsonProperty $hook 'type'
                        $cmd = Get-JsonProperty $hook 'command'
                        $base = "/hooks/$evt/$e/hooks/$h"
                        if ($type -ne 'command') {
                            $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                        -Path "$base/type" -Message "hook type esperado 'command', veio '$type'"))
                        }
                        if ([string]::IsNullOrWhiteSpace([string]$cmd)) {
                            $findings.Add((New-ConfigFinding -Severity error -Rule shape `
                                        -Path "$base/command" -Message 'hook sem command'))
                        }
                    }
                }
            }
        }
    }

    return $findings.ToArray()
}

function Test-PermissionsBroad {
    <#
    .SYNOPSIS  Achados de allow amplo (severity 'warn', rule 'allow-broad').
    .OUTPUTS   [pscustomobject[]]
    .NOTES     deny vence allow (context7); o risco é amplitude de auto-aprovação, não bypass de deny.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Json)

    $findings = [System.Collections.Generic.List[object]]::new()
    $perms = Get-JsonProperty $Json 'permissions'
    $allow = Get-JsonProperty $perms 'allow'
    if ($allow -isnot [array]) { return @() }   # forma inválida fica p/ o shape

    for ($i = 0; $i -lt $allow.Count; $i++) {
        $rule = $allow[$i]
        if ($rule -isnot [string]) { continue }
        foreach ($pat in $script:BroadAllow) {
            if ($rule -match $pat) {
                $findings.Add((New-ConfigFinding -Severity warn -Rule allow-broad `
                            -Path "/permissions/allow/$i" -Message "regra de allow muito ampla: '$rule'"))
                break
            }
        }

        # Classe separada da acima de proposito: o $BroadAllow mede amplitude nas PONTAS, esta mede
        # no MEIO, e a acao de correcao e' outra -- por isso rule propria, e nao mais um padrao la.
        if (Test-BashWildcardMid -Rule $rule) {
            $findings.Add((New-ConfigFinding -Severity warn -Rule allow-wildcard-mid `
                        -Path "/permissions/allow/$i" `
                        -Message "coringa antes do resto do comando: '$rule' — o que estiver nessa posicao e' auto-aprovado. Troque o '*' pelo valor exato, ou use '*' so no fim."))
        }
    }
    return $findings.ToArray()
}

function Test-PermissionsPathRule {
    <#
    .SYNOPSIS  Achados de regra de caminho que o harness ignora (rule 'path-rule-ignored').
    .OUTPUTS   [pscustomobject[]]
    .NOTES     'error' no deny e 'warn' no allow/ask: o allow inerte custa um prompt a mais; o deny
               inerte e' protecao que nao existe -- medido, o Write passou por cima dele.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Json)

    $findings = [System.Collections.Generic.List[object]]::new()
    $perms = Get-JsonProperty $Json 'permissions'
    foreach ($lista in @('allow', 'deny', 'ask')) {
        $regras = Get-JsonProperty $perms $lista
        if ($regras -isnot [array]) { continue }   # forma inválida fica p/ o shape

        for ($i = 0; $i -lt $regras.Count; $i++) {
            $rule = $regras[$i]
            if ($rule -isnot [string]) { continue }
            $alvo = Get-IgnoredPathRuleTarget -Rule $rule
            if (-not $alvo) { continue }

            $troca = $rule -creplace '^[A-Za-z]+\(', "$alvo("
            if ($lista -eq 'deny') {
                $sev = 'error'; $efeito = 'o deny nao protege nada (a escrita passa)'
            }
            else {
                $sev = 'warn'; $efeito = 'a regra nao concede nada'
            }
            $findings.Add((New-ConfigFinding -Severity $sev -Rule path-rule-ignored `
                        -Path "/permissions/$lista/$i" `
                        -Message "o harness nao casa '$rule' na checagem de arquivo -- $efeito. Troque por '$troca' (a regra $alvo cobre todas as tools do lado dela)."))
        }
    }
    return $findings.ToArray()
}

function Test-HookCommands {
    <#
    .SYNOPSIS  Achados de comando de hook arriscado (severity 'warn', rule 'hook-risky').
    .OUTPUTS   [pscustomobject[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Json)

    $findings = [System.Collections.Generic.List[object]]::new()
    $hooks = Get-JsonProperty $Json 'hooks'
    if (-not (Test-IsJsonObject $hooks)) { return @() }

    # Itera a coleção .Properties (não .Properties.Name): "hooks": {} vazio lança ao acessar .Name
    # sob StrictMode Latest; coleção vazia não itera.
    foreach ($prop in $hooks.PSObject.Properties) {
        $evt = $prop.Name
        $entries = $prop.Value
        if ($entries -isnot [array]) { continue }
        for ($e = 0; $e -lt $entries.Count; $e++) {
            $inner = Get-JsonProperty $entries[$e] 'hooks'
            if ($inner -isnot [array]) { continue }
            for ($h = 0; $h -lt $inner.Count; $h++) {
                $cmd = [string](Get-JsonProperty $inner[$h] 'command')
                if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
                foreach ($pat in $script:RiskyHook) {
                    if ($cmd -imatch $pat) {
                        $findings.Add((New-ConfigFinding -Severity warn -Rule hook-risky `
                                    -Path "/hooks/$evt/$e/hooks/$h/command" `
                                    -Message "comando de hook com padrão rede->shell: '$cmd'"))
                        break
                    }
                }
            }
        }
    }
    return $findings.ToArray()
}

function Get-ConfigLintFindings {
    <#
    .SYNOPSIS  Parse + os 3 checks sobre o TEXTO de um settings.json. Tag Path com "$Source#".
    .OUTPUTS   [pscustomobject[]] (vazio = config limpa)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    try {
        $obj = $Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return @((New-ConfigFinding -Severity error -Rule malformed -Path "$Source#/" `
                    -Message "JSON inválido: $($_.Exception.Message)"))
    }
    if ($null -eq $obj) { return @() }

    $findings = @()
    $findings += Test-ConfigShape -Json $obj
    $findings += Test-PermissionsBroad -Json $obj
    $findings += Test-PermissionsPathRule -Json $obj
    $findings += Test-HookCommands -Json $obj

    foreach ($f in $findings) { $f.Path = "$Source#$($f.Path)" }
    return @($findings)
}

function Format-ConfigLintReport {
    <# .SYNOPSIS  Painel legível dos achados, agrupado por arquivo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'config-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $byFile = $Findings | Group-Object { ($_.Path -split '#', 2)[0] }
    foreach ($g in $byFile) {
        $lines.Add("• $($g.Name)")
        foreach ($f in $g.Group) {
            $node = ($f.Path -split '#', 2)[1]
            $lines.Add("    [$($f.Severity)] $($f.Rule) $node — $($f.Message)")
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-ConfigLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-ConfigLint {
    <#
    .SYNOPSIS  I/O fino: lê cada arquivo e agrega os achados. try/catch por-arquivo.
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path)

    $all = @()
    foreach ($p in $Path) {
        try {
            $text = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
        }
        catch {
            $all += New-ConfigFinding -Severity error -Rule malformed -Path "$p#/" `
                -Message "arquivo ilegível: $($_.Exception.Message)"
            continue
        }
        $all += Get-ConfigLintFindings -Text $text -Source $p
    }
    return @($all)
}
