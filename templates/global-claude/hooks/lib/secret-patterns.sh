#!/usr/bin/env bash
# Fonte UNICA (shell) de deteccao de segredos — espelho fiel de lib/secret-patterns.ps1.
#
# Apenas padroes de confianca HIGH (o uso do secret-guard em commit/push e' MinConfidence High).
# Sem efeitos colaterais ao ser sourced: so define funcoes (sem prompts, sem I/O).
# Os regex sao casados com `grep -P` (PCRE) p/ fidelidade aos regex .NET do .ps1.
#
# Paridade com o .ps1 verificada por tools/tests/hooks-portable.Tests.ps1 (AT-009).

# Catalogo HIGH: cada item "Nome|||REGEX" (mesma ordem/semantica do Get-SecretPattern .ps1).
_SECRET_PATTERNS_HIGH=(
  "AWS Access Key ID|||\b(?:AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b"
  "GitHub token|||\bgh[pousr]_[A-Za-z0-9]{36,}\b"
  "GitHub fine-grained|||\bgithub_pat_[A-Za-z0-9_]{40,}\b"
  "Google API key|||\bAIza[0-9A-Za-z_-]{35}\b"
  "Slack token|||\bxox[baprs]-[0-9A-Za-z-]{10,}\b"
  "Private key block|||-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"
  "JWT|||\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"
)

# PURA: mascara um trecho p/ exibir sem vazar (4 chars + ate' 8 '*'). Espelha Get-MaskedSample.
mask_sample() {
  local v
  v="$(printf '%s' "${1-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  local n=${#v}
  if [ "$n" -le 4 ]; then printf '%*s' "$n" '' | tr ' ' '*'; return; fi
  local stars=$(( n - 4 ))
  [ "$stars" -gt 8 ] && stars=8
  printf '%s%s' "${v:0:4}" "$(printf '%*s' "$stars" '' | tr ' ' '*')"
}

# PURA: o path aponta p/ um arquivo de segredo (env/chave)? Espelha Test-IsSecretFilePath.
is_secret_file_path() {
  local p
  p="$(printf '%s' "${1-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$p" ] && return 1
  p="${p//\\//}"
  local leaf="${p##*/}"
  printf '%s' "$leaf" | grep -qE '^\.env(\..+)?$'            && return 0   # .env, .env.local…
  printf '%s' "$leaf" | grep -qE '^id_(rsa|dsa|ecdsa|ed25519)$' && return 0   # chaves SSH
  printf '%s' "$p"    | grep -qE '\.(pem|pfx|p12|key|keystore|jks)$' && return 0   # material de chave
  printf '%s' "$p"    | grep -qE '(^|/)secrets?/'            && return 0   # pasta secrets/
  return 1
}

# PURA: encontra segredos HIGH num texto -> imprime o NOME do padrao, 1 linha por match.
# Espelha Find-SecretMatch -MinConfidence High (uma linha por ocorrencia, ordem do catalogo).
find_secret_match() {
  local text="${1-}"
  [ -z "$text" ] && return 0
  local entry name regex hits i
  for entry in "${_SECRET_PATTERNS_HIGH[@]}"; do
    name="${entry%%|||*}"
    regex="${entry##*|||}"
    hits="$(printf '%s' "$text" | grep -oP -e "$regex" 2>/dev/null | grep -c '')"
    [ -z "$hits" ] && hits=0
    i=0
    while [ "$i" -lt "$hits" ]; do printf '%s\n' "$name"; i=$((i + 1)); done
  done
  return 0
}

# PURA: ha pelo menos um segredo HIGH no texto? Espelha Test-TextHasSecret.
text_has_secret() {
  [ -n "$(find_secret_match "${1-}")" ]
}
