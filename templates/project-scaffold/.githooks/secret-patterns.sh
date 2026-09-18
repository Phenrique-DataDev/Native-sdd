#!/usr/bin/env bash
# Fonte UNICA (shell) de deteccao de segredos — espelho fiel de lib/secret-patterns.ps1.
#
# Apenas padroes de confianca HIGH (o uso do secret-guard em commit/push e' MinConfidence High).
# Sem efeitos colaterais ao ser sourced: so define funcoes (sem prompts, sem I/O).
#
# PORTABILIDADE (macOS): os regex sao ERE (`grep -E`), NAO PCRE. O grep do macOS e' BSD ("BSD grep,
# GNU compatible 2.6.0-FreeBSD", medido no runner macos-15 em 2026-09-10) e nao tem `-P`; com o erro
# engolido, o find_secret_match devolvia ZERO achados e o guard liberava tudo em silencio.
# Traducao do dialeto .NET do .ps1:  (?:…) -> (…)  ·  \s -> [[:space:]]  ·  \+ -> [+]
# O `\b` fica como esta': o grep BSD o aceita em -E (medido no mesmo runner).
#
# Paridade com o .ps1 — inclusive sob userland BSD — verificada por tools/tests/secret-guard-sh.Tests.ps1.

# Catalogo HIGH: cada item "Nome|||REGEX" (mesma ordem/semantica do Get-SecretPattern .ps1).
_SECRET_PATTERNS_HIGH=(
  "AWS Access Key ID|||\b(AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b"
  "GitHub token|||\bgh[pousr]_[A-Za-z0-9]{36,}\b"
  "GitHub fine-grained|||\bgithub_pat_[A-Za-z0-9_]{40,}\b"
  "Google API key|||\bAIza[0-9A-Za-z_-]{35}\b"
  "Slack token|||\bxox[baprs]-[0-9A-Za-z-]{10,}\b"
  "Private key block|||-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"
  "JWT|||\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"
  "Stripe secret key|||\b[sr]k_live_[A-Za-z0-9]{16,}\b"
  "OpenAI/Anthropic key|||\bsk-(ant-)?[A-Za-z0-9_-]{20,}\b"
  "Azure storage key|||\bAccountKey=[A-Za-z0-9+/]{40,}={0,2}"
  "DB conn string w/ password|||\b(postgres(ql)?|mysql|mongodb([+]srv)?|rediss?|amqp)://[^:@/[:space:]]+:[^@/[:space:]]+@"
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
# rc: 0 = varreu tudo (com ou sem achado) · 2 = o motor de regex FALHOU em algum padrao — o chamador
# decide (o secret-guard pede confirmacao). Nunca converte erro em "nenhum segredo".
find_secret_match() {
  local text="${1-}"
  [ -z "$text" ] && return 0
  local entry name regex out rc err=0 line
  for entry in "${_SECRET_PATTERNS_HIGH[@]}"; do
    name="${entry%%|||*}"
    regex="${entry##*|||}"
    out="$(printf '%s\n' "$text" | grep -oE -e "$regex" 2>/dev/null)"; rc=$?
    if [ "$rc" -gt 1 ]; then err=1; continue; fi
    [ -z "$out" ] && continue
    while IFS= read -r line; do printf '%s\n' "$name"; done <<< "$out"
  done
  [ "$err" -eq 0 ] || return 2
  return 0
}

# PURA: ha pelo menos um segredo HIGH no texto? Espelha Test-TextHasSecret.
# Motor de regex falhou -> trata como segredo (na duvida, confirmar; nunca liberar calado).
text_has_secret() {
  local out
  out="$(find_secret_match "${1-}")" || return 0
  [ -n "$out" ]
}
