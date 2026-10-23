<#
.SYNOPSIS
    Fonte ÚNICA de detecção de segredos (lib compartilhada).

.DESCRIPTION
    Funções PURAS de deteccao de segredos, dot-sourceaveis e testaveis. É a fonte de
    verdade consumida por:
      - secret-guard.ps1   (hook PreToolUse do Claude Code — modo "ask")     [global]
      - .githooks/secret-scan.ps1 (git pre-commit — bloqueia o commit)        [scaffold]

    NÃO tem efeitos colaterais ao carregar (só define funções). Sem prompts, sem I/O.

    Confidence:
      - 'High'   : padrao especifico de credencial (AKIA…, gh?_…, BEGIN PRIVATE KEY…). Baixo
                   falso-positivo -> serve para BLOQUEAR (pre-commit).
      - 'Medium' : atribuicao generica (api_key = "…"). Mais ruidoso -> serve para AVISAR
                   (hook "ask"), nao para bloquear.

    Redacao: as amostras devolvidas sao MASCARADAS (nunca o segredo cru) para nao vazar em
    logs/saida do hook.

    Compativel com Windows PowerShell 5.1+ e PowerShell 7+ (sem ternario).
#>

Set-StrictMode -Version Latest

# --- PURA: catalogo de padroes de credencial --------------------------------------------------
function Get-SecretPattern {
    # Cada item: Name (rotulo), Regex (case-sensitive salvo (?i)), Confidence (High|Medium).
    @(
        [pscustomobject]@{ Name = 'AWS Access Key ID';   Confidence = 'High';   Regex = '\b(?:AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b' }
        [pscustomobject]@{ Name = 'GitHub token';        Confidence = 'High';   Regex = '\bgh[pousr]_[A-Za-z0-9]{36,}\b' }
        [pscustomobject]@{ Name = 'GitHub fine-grained'; Confidence = 'High';   Regex = '\bgithub_pat_[A-Za-z0-9_]{40,}\b' }
        [pscustomobject]@{ Name = 'Google API key';      Confidence = 'High';   Regex = '\bAIza[0-9A-Za-z_\-]{35}\b' }
        [pscustomobject]@{ Name = 'Slack token';         Confidence = 'High';   Regex = '\bxox[baprs]-[0-9A-Za-z-]{10,}\b' }
        [pscustomobject]@{ Name = 'Private key block';   Confidence = 'High';   Regex = '-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----' }
        [pscustomobject]@{ Name = 'JWT';                 Confidence = 'High';   Regex = '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b' }
        [pscustomobject]@{ Name = 'Stripe secret key';   Confidence = 'High';   Regex = '\b[sr]k_live_[A-Za-z0-9]{16,}\b' }
        [pscustomobject]@{ Name = 'OpenAI/Anthropic key'; Confidence = 'High';  Regex = '\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}\b' }
        [pscustomobject]@{ Name = 'Azure storage key';   Confidence = 'High';   Regex = '\bAccountKey=[A-Za-z0-9+/]{40,}={0,2}' }
        [pscustomobject]@{ Name = 'DB conn string w/ password'; Confidence = 'High'; Regex = '\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|rediss?|amqp)://[^:@/\s]+:[^@/\s]+@' }
        [pscustomobject]@{ Name = 'Generic secret assignment'; Confidence = 'Medium'; Regex = '(?i)(?:api[_-]?key|secret|token|password|passwd|pwd|client[_-]?secret|access[_-]?key)\s*[:=]\s*["'']?[A-Za-z0-9/+_\-]{16,}' }
    )
}

# --- PURA: mascara um trecho para exibir sem vazar (mantem 4 chars + ***) ----------------------
function Get-MaskedSample {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $v = $Value.Trim()
    if ($v.Length -le 4) { return ('*' * $v.Length) }
    return ($v.Substring(0, 4) + ('*' * [Math]::Min(8, $v.Length - 4)))
}

# --- PURA: o path aponta para um arquivo de segredo (env/chave)? -------------------------------
function Test-IsSecretFilePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Trim().Replace('\', '/')
    $leaf = ($p -split '/')[-1]
    if ($leaf -match '^\.env(\..+)?$') { return $true }            # .env, .env.local, .env.prod…
    if ($leaf -match '^id_(rsa|dsa|ecdsa|ed25519)$') { return $true } # chaves SSH privadas
    if ($p -match '\.(pem|pfx|p12|key|keystore|jks)$') { return $true } # material de chave
    if ($p -match '(^|/)secrets?/') { return $true }               # pasta secrets/
    return $false
}

# --- PURA: uma passada de UM padrao (funcao propria para o teste contar as passadas) ----------
function Get-SecretRegexMatch {
    param([string]$Text, [string]$Regex)
    return , [regex]::Matches($Text, $Regex)
}

# --- PURA: encontra segredos num texto -> lista de achados (mascarados) ------------------------
function Find-SecretMatch {
    # -MinConfidence: 'High' ignora padroes 'Medium'. Default 'Medium' (pega tudo).
    param(
        [string]$Text,
        [ValidateSet('High', 'Medium')][string]$MinConfidence = 'Medium'
    )
    $found = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text)) { return , @($found.ToArray()) }
    $pats = @(Get-SecretPattern | Where-Object { $MinConfidence -ne 'High' -or $_.Confidence -eq 'High' })
    # Pre-filtro: UMA passada com os padroes alternados. A uniao nao casa se, e so se, nenhum padrao
    # casa, entao o texto limpo sai aqui sem mudar o resultado. Cada regex varrendo o texto inteiro
    # custava ~0,8 s numa cena de 14 MB (11 regex = 9,2 s); a uniao, ~1,1 s (medido 2026-10-22).
    # Texto com achado segue para o laco abaixo, que monta a lista como sempre.
    $union = ($pats | ForEach-Object { "(?:$($_.Regex))" }) -join '|'
    try { if (-not [regex]::IsMatch($Text, $union)) { return , @($found.ToArray()) } }
    catch { }   # uniao defeituosa cai no laco, que isola o padrao ruim
    foreach ($pat in $pats) {
        try {
            $hits = Get-SecretRegexMatch -Text $Text -Regex $pat.Regex
        }
        catch { continue }   # padrao defeituoso nunca derruba o chamador
        foreach ($m in $hits) {
            $found.Add([pscustomobject]@{
                    Pattern    = $pat.Name
                    Confidence = $pat.Confidence
                    Sample     = (Get-MaskedSample $m.Value)
                })
        }
    }
    return , @($found.ToArray())
}

# --- PURA: ha pelo menos um segredo no texto? -------------------------------------------------
function Test-TextHasSecret {
    param(
        [string]$Text,
        [ValidateSet('High', 'Medium')][string]$MinConfidence = 'Medium'
    )
    return ((Find-SecretMatch -Text $Text -MinConfidence $MinConfidence).Count -gt 0)
}
