<#
.SYNOPSIS
    Fonte ÚNICA dos detectores de comando destrutivo (lib compartilhada) — J5.

.DESCRIPTION
    Funções PURAS, dot-sourceáveis e testáveis. É a fonte de verdade consumida pelo
    hook `destructive-guard.ps1` (PreToolUse, modo "ask"). Espelhada em
    `lib/destructive-patterns.sh` (paridade travada por tools/tests/destructive-guard.Tests.ps1).

    NÃO tem efeitos colaterais ao carregar (só define funções). Sem prompts, sem I/O, sem git/rede,
    sem ler env: o contexto (cwd, temp, home, TEMP/TMP/TMPDIR) chega por PARÂMETRO do hook
    (GUARD_RM_ESCOPO, v0.11.14). Sem contexto, nenhuma raiz é segura e todo absoluto pede confirmação.

    Filosofia: a postura é **ask** (educar, não barrar) — o `deny` inviolável vive na managed
    policy (C3). A decisão é por **tokenização** (não roda o shell): o lado seguro, na dúvida, é
    **pass** (silêncio) — FN exótico é aceitável (≤ ao estado atual sob `auto`). Duas exceções
    deliberadas: o absoluto no formato Windows (`C:/…`) é absoluto como o POSIX (era FN medido), e
    a variável só se resolve pelo que o PRÓPRIO comando atribui — na dúvida sobre ela, `ask`.

    Compatível com PowerShell 7+.
#>

Set-StrictMode -Version Latest

# --- PURA: divide o comando em segmentos por separadores de shell ------------------------------
function Split-CommandSegment {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return @() }
    return [regex]::Split($Command, '&&|\|\||;|\r?\n|\|')
}

# --- PURA: o segmento é um `rm` recursivo E force? (flags normalizadas, ordem livre) -----------
function Test-IsDestructiveRm {
    param([string]$Segment)
    if ([string]::IsNullOrWhiteSpace($Segment)) { return $false }
    if ($Segment -notmatch '(?:^|\s)(?:sudo\s+)?rm(?:\s|$)') { return $false }
    $hasRec = $false; $hasForce = $false
    foreach ($tok in ($Segment -split '\s+')) {
        if ($tok -eq '--recursive') { $hasRec = $true; continue }
        if ($tok -eq '--force') { $hasForce = $true; continue }
        if ($tok -match '^-[A-Za-z]+$') {        # cluster curto: -rf, -fr, -Rf, -r, -f…
            $cluster = $tok.Substring(1)
            if ($cluster -match '[rR]') { $hasRec = $true }
            if ($cluster -match 'f') { $hasForce = $true }
        }
    }
    return ($hasRec -and $hasForce)
}

# --- PURA: alvos (tokens não-flag) de um segmento `rm` -----------------------------------------
function Get-RmTarget {
    param([string]$Segment)
    $targets = @()
    $seen = $false
    foreach ($tok in ($Segment -split '\s+')) {
        if ($tok -eq '') { continue }
        if (-not $seen) {
            if ($tok -eq 'rm') { $seen = $true }
            continue
        }
        if ($tok.StartsWith('-')) { continue }   # flag
        $targets += $tok
    }
    return , $targets
}

# --- PURA: normaliza um caminho para comparação (GUARD_RM_ESCOPO, D7) --------------------------
# A MESMA pasta chega em três formas (medido 2026-09-28): `C:\Users\x\Temp` (pwsh, payload),
# `/c/Users/x/Temp` (Git Bash) e `C:/Users/x/Temp`. Aspas saem todas — é a concatenação do shell
# (`"$S"/x` == `$S/x`). NÃO resolve `..` (quem chama já tratou `..` como arriscado antes).
function ConvertTo-GuardPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $p = $Path.Trim().Replace('"', '').Replace("'", '').Replace('\', '/')
    # Sem MatchEvaluator (scriptblock): a 1ª chamada dele custa caro num hook que sobe a cada Bash.
    if ($p -match '^/([A-Za-z])(/|$)') { $p = $Matches[1].ToUpperInvariant() + ':' + $p.Substring(2) }
    if ($p -cmatch '^[a-z]:') { $p = $p.Substring(0, 1).ToUpperInvariant() + $p.Substring(1) }
    while ($p.Contains('//')) { $p = $p.Replace('//', '/') }
    if ($p -match '^[A-Z]:$') { $p += '/' }
    if ($p.Length -gt 1 -and $p.EndsWith('/') -and $p -notmatch '^[A-Z]:/$') { $p = $p.TrimEnd('/') }
    return $p
}

# --- PURA: chave de comparação (Windows compara sem caixa; POSIX, com) --------------------------
function Get-GuardPathKey {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:') { return $Path.ToLowerInvariant() }
    return $Path
}

# --- PURA: raízes seguras = cwd e temp, menos as que apagariam demais (D8) ----------------------
# Descarta `/`, raiz de drive, a home e qualquer ANCESTRAL da home (`cwd=C:/Users` não pode
# liberar `C:/Users/<outro>`), e raiz com `..`. Sem HomeDir, só os dois primeiros descartes.
function Get-SafeRoot {
    param([string]$Cwd, [string[]]$TempDir, [string]$HomeDir)
    $homeKey = if ($HomeDir) { Get-GuardPathKey (ConvertTo-GuardPath $HomeDir) } else { '' }
    $roots = @()
    foreach ($c in @(@($Cwd) + @($TempDir))) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $r = ConvertTo-GuardPath $c
        if (-not ($r.StartsWith('/') -or $r -match '^[A-Z]:/')) { continue }   # só absoluto
        if ($r -eq '/' -or $r -match '^[A-Z]:/$') { continue }
        if ($r -match '(^|/)\.\.(/|$)') { continue }
        $k = Get-GuardPathKey $r
        if ($homeKey -and ($k -eq $homeKey -or $homeKey.StartsWith("$k/"))) { continue }
        $roots += $r
    }
    return , $roots
}

# --- PURA: o caminho (normalizado) é descendente ESTRITO de alguma raiz? (nunca a raiz) ---------
function Test-IsUnderSafeRoot {
    param([string]$Path, [string[]]$SafeRoots)
    if ([string]::IsNullOrEmpty($Path) -or -not $SafeRoots) { return $false }
    $k = Get-GuardPathKey $Path
    foreach ($r in $SafeRoots) {
        if ([string]::IsNullOrEmpty($r)) { continue }
        if ($k.StartsWith((Get-GuardPathKey $r) + '/')) { return $true }
    }
    return $false
}

# --- PURA: o alvo é "arriscado"? (absoluto fora das raízes / home / var / glob amplo / sobe) ----
# O token chega JÁ expandido (Expand-GuardVariable). O que sobrou de `$` não se resolveu -> ask.
# Sem SafeRoots, todo absoluto é arriscado — POSIX e drive Windows (GUARD_RM_CEGO_A_CAMINHO_WINDOWS).
function Test-IsRiskyTarget {
    param([string]$Token, [string[]]$SafeRoots = @())
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    $t = $Token.Trim().Replace('"', '').Replace("'", '')
    if ($t -eq '') { return $false }
    if ($t -match '\$') { return $true }          # var não resolvida ($DIR, ${HOME})
    if ($t.StartsWith('~')) { return $true }      # home (~ , ~/x)
    $u = $t.Replace('\', '/')
    if ($u -eq '..' -or $u.StartsWith('../')) { return $true }   # sobe da cwd — J6
    if ($u -match '/\.\.(/|$)') { return $true }  # /../ ou /.. no fim — ANTES da raiz (D10)
    if ($t.StartsWith('*')) { return $true }      # glob amplo (* , */ , *.bak)
    if ($t -eq '.*') { return $true }             # glob .*
    if ($u.StartsWith('/') -or $u -match '^[A-Za-z]:') {        # absoluto: POSIX ou drive
        $n = ConvertTo-GuardPath $t
        if ($n -match '[*?\[]') { return $true }  # glob no absoluto nunca passa (AT-011)
        return (-not (Test-IsUnderSafeRoot $n $SafeRoots))
    }
    return $false                                 # relativo-sob-cwd: ./build, build, node_modules, dist
}

# --- PURA: o segmento é UMA atribuição limpa (`NOME=valor` / `export NOME=valor`)? (D4) ---------
# Devolve @{ Name; Raw } ou $null. Valor sem aspas com espaço NÃO é atribuição limpa: é prefixo de
# comando (`S=x rm -rf "$S"`), em que o bash expande `$S` ANTES de atribuir — não pode resolver.
# Exceção: `$(mktemp -d …)`, que tem espaço e é inteiro.
function Get-LiteralAssignment {
    param([string]$Segment)
    if ($Segment -cnotmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*$') { return $null }
    $name = $Matches[1]; $raw = $Matches[2]
    $quoted = ($raw -match '^"[^"]*"$') -or ($raw -match "^'[^']*'$")
    if (-not $quoted -and $raw -match '\s' -and -not (Test-IsMktempTemp $raw)) { return $null }
    if (-not $quoted -and $raw -match '["'']') { return $null }   # aspa desbalanceada: não confia
    return @{ Name = $name; Raw = $raw }
}

# --- PURA: `$(mktemp -d)` / `$(mktemp -d -t NOME)` exatos (sem -p/--tmpdir) — D6 ---------------
function Test-IsMktempTemp {
    param([string]$Raw)
    $v = $Raw.Trim()
    if ($v -match '^"(.*)"$') { $v = $Matches[1] }
    return ($v -cmatch '^\$\(mktemp -d(?: -t [A-Za-z0-9._-]+)?\)$')
}

# --- PURA: marca o corpo de heredoc (`<<TAG` … `TAG`) com o prefixo `#HD ` ----------------------
# Corpo de heredoc é DADO: um `S=/` ali não atribui nada no shell que roda o `rm`. Com o prefixo, a
# linha deixa de ser atribuição limpa (Get-LiteralAssignment exige `^NOME=`) e passa a ENVENENAR o
# nome — mas um `rm -rf` dentro dela continua sendo visto (`bash <<EOF` executa o corpo).
function ConvertTo-GuardAnalysisText {
    param([string]$Command)
    if ([string]::IsNullOrEmpty($Command) -or -not $Command.Contains('<<')) { return $Command }
    $out = [System.Collections.Generic.List[string]]::new()
    $tag = $null
    foreach ($line in ($Command -split '\r?\n')) {
        if ($null -ne $tag) {
            $out.Add("#HD $line")
            if ($line.Trim() -ceq $tag) { $tag = $null }
            continue
        }
        $out.Add($line)
        $m = [regex]::Match($line, '(?<!<)<<-?\s*([''"]?)([A-Za-z_][A-Za-z0-9_]*)\1')
        if ($m.Success) { $tag = $m.Groups[2].Value }
    }
    return ($out -join "`n")
}

# --- PURA: nomes que o comando (re)define por um caminho que o guard NÃO acompanha --------------
# Laço, `read`, `unset`, `declare`, `${X:=}`, atribuição dentro de `if`/`do`/função/heredoc… Um
# nome desses não é resolvido (fica `$` -> ask). Devolve '*' quando nada pode ser resolvido:
# `eval`, `source`/`.`, ou aspas que atravessam linha fora de heredoc (o split por linha mentiria).
# Conservador de propósito: errar aqui só custa um `ask` a mais. Recebe o texto JÁ marcado por
# ConvertTo-GuardAnalysisText.
function Get-GuardPoisonedName {
    param([string]$Command)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ([string]::IsNullOrEmpty($Command)) { return , $set }
    if ($Command -match '(?:^|[\s;&|(])(?:eval|source)\s' -or $Command -match '(?:^|[;&|(\n])\s*\.\s+\S') {
        [void]$set.Add('*'); return , $set
    }
    $inS = $false; $inD = $false
    foreach ($line in ($Command -split '\n')) {
        if ($line.StartsWith('#HD ')) { continue }        # corpo de heredoc: aspas ali são texto
        foreach ($ch in ($line + "`n").ToCharArray()) {
            if ($ch -eq "'" -and -not $inD) { $inS = -not $inS; continue }
            if ($ch -eq '"' -and -not $inS) { $inD = -not $inD; continue }
            if ($ch -eq "`n" -and ($inS -or $inD)) { [void]$set.Add('*'); return , $set }
        }
    }
    foreach ($m in [regex]::Matches($Command, '\$\{([A-Za-z_][A-Za-z0-9_]*):?[=]')) { [void]$set.Add($m.Groups[1].Value) }
    foreach ($seg in (Split-CommandSegment $Command)) {
        if (Get-LiteralAssignment $seg) { continue }
        foreach ($m in [regex]::Matches($seg, '(?<![\w$])([A-Za-z_][A-Za-z0-9_]*)\+?=')) { [void]$set.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($seg, '\b(?:for|select)\s+([A-Za-z_][A-Za-z0-9_]*)')) { [void]$set.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($seg, '\b(?:read|mapfile|readarray|getopts|declare|local|typeset|readonly|export|unset)\b([^;&|]*)')) {
            foreach ($w in [regex]::Matches($m.Groups[1].Value, '\b[A-Za-z_][A-Za-z0-9_]*\b')) { [void]$set.Add($w.Value) }
        }
    }
    return , $set
}

# --- PURA: troca `$X`/`${X}` pelo valor conhecido (D3/D5) ---------------------------------------
# $Vars: nome -> valor literal, ou $null (conhecido como NÃO resolvível). $EnvVars: TEMP/TMP/TMPDIR
# do env do HOOK, só quando o nome não foi atribuído no comando e não está envenenado.
function Expand-GuardVariable {
    param([string]$Text, $Vars, $EnvVars, $Poisoned)
    if ([string]::IsNullOrEmpty($Text) -or $Text -notmatch '\$') { return $Text }
    if ($Poisoned -and $Poisoned.Contains('*')) { return $Text }
    return [regex]::Replace($Text, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)', {
            param($m)
            $n = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if ($Poisoned -and $Poisoned.Contains($n)) { return $m.Value }
            if ($Vars -and $Vars.ContainsKey($n)) {
                if ($null -eq $Vars[$n]) { return $m.Value }
                return [string]$Vars[$n]
            }
            if ($EnvVars -and $EnvVars.ContainsKey($n) -and $EnvVars[$n]) { return [string]$EnvVars[$n] }
            return $m.Value
        })
}

# --- PURA: o segmento é um `git` que apaga trabalho não-commitado (working-tree/stash)? — J6 -----
# Tabela por-subcomando (DESIGN D-001): só `ask` p/ o que destrói o não-commitado; rotina/branch passa.
function Test-IsDestructiveGit {
    param([string]$Segment)
    if ([string]::IsNullOrWhiteSpace($Segment)) { return $false }
    if ($Segment -notmatch '(?:^|\s)(?:sudo\s+)?git(?:\s|$)') { return $false }
    $tokens = @($Segment -split '\s+' | Where-Object { $_ -ne '' })

    $stage = 0          # 0 = antes de `git`; 1 = achou git (procura subcomando); 2 = coletando pós-sub
    $sub = $null
    $hasForce = $false; $hasDry = $false; $hasStaged = $false; $hasWorktree = $false
    $hasDDash = $false; $hasDot = $false; $stashFirst = $null
    foreach ($tok in $tokens) {
        switch ($stage) {
            0 { if ($tok -eq 'git') { $stage = 1 } }
            1 { if (-not $tok.StartsWith('-')) { $sub = $tok; $stage = 2 } }   # flags globais ignoradas
            2 {
                switch -regex ($tok) {
                    '^--force$'    { $hasForce = $true }
                    '^--dry-run$'  { $hasDry = $true }
                    '^(?:--staged|-S)$'   { $hasStaged = $true }
                    '^(?:--worktree|-W)$' { $hasWorktree = $true }
                    '^--$'         { $hasDDash = $true }
                    '^\.$'         { $hasDot = $true }
                    '^-[A-Za-z]+$' {                       # cluster curto: -fdx, -fd, -n…
                        $c = $tok.Substring(1)
                        if ($c -match 'f') { $hasForce = $true }
                        if ($c -match 'n') { $hasDry = $true }
                    }
                }
                if ($null -eq $stashFirst -and -not $tok.StartsWith('-')) { $stashFirst = $tok }
            }
        }
    }
    if (-not $sub) { return $false }
    switch ($sub) {
        'clean'    { return ($hasForce -and -not $hasDry) }          # apaga untracked; -n/--dry-run não
        'restore'  { return ((-not $hasStaged) -or $hasWorktree) }   # sem --staged = descarta working tree
        'checkout' { return ($hasDDash -or $hasDot) }                # checkout de paths (--/.) descarta
        'stash'    { return ($stashFirst -eq 'drop' -or $stashFirst -eq 'clear') }
        default    { return $false }                                 # status/diff/log/pull/add/commit…
    }
}

# --- PURA: o segmento é um `chmod` recursivo com modo perigoso? --------------------------------
function Test-IsRiskyChmod {
    param([string]$Segment)
    if ([string]::IsNullOrWhiteSpace($Segment)) { return $false }
    if ($Segment -notmatch '(?:^|\s)(?:sudo\s+)?chmod(?:\s|$)') { return $false }
    $hasRec = $false; $hasMode = $false
    foreach ($tok in ($Segment -split '\s+')) {
        if ($tok -eq '--recursive' -or $tok -match '^-[A-Za-z]*R[A-Za-z]*$') { $hasRec = $true }
        if ($tok -match '^(?:777|666|000)$' -or $tok -eq 'a+rwx') { $hasMode = $true }
    }
    return ($hasRec -and $hasMode)
}

# --- PURA: o comando baixa um script e o executa direto no shell? (no comando bruto) ----------
function Test-IsDownloadToShell {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    return ($Command -match '(?i)\b(?:curl|wget|fetch)\b[^|]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|ksh|dash|pwsh|powershell|python[0-9.]*|perl|ruby|node)\b')
}

# --- PURA: comando -> decisão { Decision = 'ask'|'pass'; Reason } ------------------------------
# Contexto OPCIONAL (GUARD_RM_ESCOPO, D1): quem chama é o hook, que lê cwd do payload e temp/home/
# TEMP-TMP-TMPDIR do próprio env. Sem contexto, nenhuma raiz segura: todo absoluto é `ask`.
function Get-DestructiveDecision {
    param(
        [string]$Command,
        [string]$Cwd,
        [string[]]$TempDir,
        [string]$HomeDir,
        [hashtable]$TempVars
    )
    if ([string]::IsNullOrWhiteSpace($Command)) {
        return [pscustomobject]@{ Decision = 'pass'; Reason = '' }
    }
    # 1) download-to-shell roda no comando bruto (antes do split, que quebraria `curl x | sh`).
    if (Test-IsDownloadToShell $Command) {
        return [pscustomobject]@{ Decision = 'ask'
            Reason = 'Download de script executado direto no shell (curl/wget | sh). Confirmacao exigida.'
        }
    }
    # Tudo o que vem abaixo é PREGUIÇOSO (espelho do .sh): quase todo comando de Bash não tem `rm`,
    # e montar raízes/dicionários antes de saber custava +15 ms por chamada (medido 2026-09-28).
    # - raízes: só no 1º segmento `rm` recursivo+force;
    # - variáveis: só com `$` E `rm` no comando — sem isso nada disso muda a decisão (e o heredoc
    #   marcado não muda a detecção de rm/git/chmod).
    $roots = $null
    $need = $Command.Contains('$') -and $Command -match '(?:^|\s)rm(?:\s|$)'
    $analise = $Command
    $poisoned = $null; $vars = $null; $envVars = $null
    if ($need) {
        $analise = ConvertTo-GuardAnalysisText $Command
        $poisoned = Get-GuardPoisonedName $analise
        # Nome de variável de shell diferencia caixa ($s != $S); hashtable do PowerShell não.
        $vars = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $envVars = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        if ($TempVars) {
            foreach ($k in $TempVars.Keys) {
                if ([string]$k -cin @('TEMP', 'TMP', 'TMPDIR') -and $TempVars[$k]) { $envVars[[string]$k] = [string]$TempVars[$k] }
            }
        }
    }
    foreach ($seg in (Split-CommandSegment $analise)) {
        # Atribuição limpa ANTES do rm: registra o valor (a última vence — D4/D5).
        $asg = if ($need) { Get-LiteralAssignment $seg } else { $null }
        if ($asg) {
            $v = $null
            if (Test-IsMktempTemp $asg.Raw) {
                if (@($TempDir).Count -gt 0 -and $TempDir[0]) { $v = (ConvertTo-GuardPath $TempDir[0]) + '/mktemp.XXXXXX' }
            }
            else {
                $raw = $asg.Raw
                if ($raw -match '^"(.*)"$') { $raw = Expand-GuardVariable $Matches[1] $vars $envVars $poisoned }
                elseif ($raw -match "^'(.*)'$") { $raw = $Matches[1] }
                else { $raw = Expand-GuardVariable $raw $vars $envVars $poisoned }
                if ($raw -notmatch '[$`(]') { $v = $raw }
            }
            $vars[$asg.Name] = $v
            continue
        }
        if (Test-IsDestructiveRm $seg) {
            # ATENCAO: Get-RmTarget devolve `, $targets` (virgula unaria, para preservar o array
            # com 0/1 elemento). Mandar isso DIRETO para o pipe emite UM item -- o proprio array --
            # e o Where-Object testaria a coercao-para-string dele ("./a /etc/foo"), que nao casa
            # nenhum padrao de Test-IsRiskyTarget. Atribuir primeiro desembrulha. Nao repipe.
            $targets = Get-RmTarget $seg
            if ($null -eq $roots) { $roots = Get-SafeRoot -Cwd $Cwd -TempDir $TempDir -HomeDir $HomeDir }
            $risky = @()
            foreach ($t in $targets) {
                $r = Expand-GuardVariable $t $vars $envVars $poisoned
                if (Test-IsRiskyTarget $r $roots) {
                    # D11: mostra o que será apagado de fato quando houve substituição.
                    $risky += if ($r -ne $t) { "$t (= $r)" } else { $t }
                }
            }
            if ($risky.Count -gt 0) {
                return [pscustomobject]@{ Decision = 'ask'
                    Reason = "Comando destrutivo (rm recursivo de alvo arriscado): $($risky -join ', '). Confirmacao exigida."
                }
            }
        }
        if (Test-IsRiskyChmod $seg) {
            return [pscustomobject]@{ Decision = 'ask'
                Reason = 'Permissao recursiva perigosa (chmod -R 777/666/000). Confirmacao exigida.'
            }
        }
        if (Test-IsDestructiveGit $seg) {
            return [pscustomobject]@{ Decision = 'ask'
                Reason = 'Git destrutivo de working-tree/stash (clean -f / restore / checkout -- / stash drop). Confirmacao exigida.'
            }
        }
    }
    return [pscustomobject]@{ Decision = 'pass'; Reason = '' }
}
