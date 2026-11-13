#!/usr/bin/env bash
# bootstrap.sh — bootstrap remoto do Native-SDD (Linux e macOS): baixa a última release (tag) do espelho
# público e delega ao onboarding/install.sh, sem exigir repo clonado nem git/gh (só bash + curl + tar).
#
# Release, não main (BOOTSTRAP_BAIXA_A_MAIN, 2026-10-18): resolve a tag por
# api.github.com/repos/<owner>/<repo>/releases/latest (tag_name, lido com sed — sem jq, como o
# onboarding/posix/lib.sh) e baixa o asset native-sdd-<tag>.tar.gz da release, conferindo o sha256 contra
# o digest da API antes de extrair (BOOTSTRAP_SEM_PIN_NEM_HASH); imprime a tag baixada. Reverte a
# Decisão 1 do DESIGN_BOOTSTRAP_REMOTO ("codeload de main, sem pinar versão"): com main, qualquer
# push mudava o que o usuário executava. A main fica como opt-in explícito: `--ref main` (ou
# `--ref=main`), consumido aqui e removido antes de repassar o resto ao install.sh. Se a API falhar
# (rate limit de 60/h anônimo, rede, espelho sem release), o bootstrap FALHA citando o `--ref main` —
# nunca cai na main em silêncio.
#
# Único script do onboarding pensado para rodar SEM nada em disco (curl <raw>/bootstrap.sh | bash):
# a URL do conteúdo fica inline aqui (owner/repo fixos no espelho público — Decisão 6 do
# DESIGN_BOOTSTRAP_REMOTO; trocar o destino exige editar este arquivo, nunca um parâmetro).
#
# Extrai num diretório temporário e MOVE o conteúdo para um cache permanente em
# ~/.claude/.native-sdd-src (substitui qualquer versão anterior) ANTES de delegar ao install.sh.
# Motivo: o install.sh grava no shim de shell (.bashrc/.profile) um atalho global (nsp/sddcheck)
# que aponta de volta para a pasta de onde rodou — se fosse o diretório temporário (que este
# script apaga ao terminar), o atalho ficaria órfão assim que o bootstrap termina (achado em uso
# real, 2026-07-07: rodar sem --check deixava nsp/sddcheck quebrados logo em seguida).
#
# Sem flags:  curl -fsSL https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/vX.Y.Z/onboarding/bootstrap.sh | bash
# Com flags:  curl -fsSL <mesma url> | bash -s -- --check
# Branch main: curl -fsSL <mesma url> | bash -s -- --ref main   (combina com os demais flags)
#
# Erros propagam (set -euo pipefail): falha de download/extração é fatal, sem modo degradado.
# O diretório temporário é removido ao final (trap EXIT), mesmo em falha — como o conteúdo é
# MOVIDO (não copiado) para o cache permanente antes da delegação, o `rm -rf` do trap não afeta o
# que já foi persistido.
#
# Tradeoff aceito: duas instâncias deste bootstrap rodando em paralelo podem colidir no cache
# permanente. Risco baixo — sem lock/mutex por YAGNI (mesmo tradeoff do lado PowerShell).
set -euo pipefail

step() { printf '[%-7s] %s\n' "$1" "$2"; }

# Sugestão de instalação por gerenciador de pacotes — best-effort, só para a mensagem de erro
# ficar acionável (achado de revisão adversarial: em imagens minimalistas comuns, como
# ubuntu:24.04/debian:12-slim "de fábrica", `curl` não vem pré-instalado; sem esta checagem o
# usuário só via um "command not found" cru, sem saber o que instalar).
suggest_install() {
    # macOS traz curl e tar (bsdtar, que aceita --strip-components) de fábrica; o brew é só a dica.
    if command -v brew >/dev/null 2>&1; then echo "brew install $1"
    elif command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y $1"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf install -y $1"
    elif command -v yum >/dev/null 2>&1; then echo "yum install -y $1"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman -Sy --noconfirm $1"
    elif command -v apk >/dev/null 2>&1; then echo "apk add $1"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper install -y $1"
    else echo "instale $1 com o gerenciador de pacotes da sua distro"
    fi
}

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        step FAIL "'$cmd' nao encontrado — pre-requisito deste bootstrap (bash + curl + tar)"
        step INFO "tente: $(suggest_install "$cmd")"
        exit 1
    fi
done

echo ''
echo '╔══════════════════════════════════════════╗'
echo '║   Bootstrap remoto · Native-SDD           ║'
echo '╚══════════════════════════════════════════╝'

# --ref é do bootstrap, não do install.sh: sai da lista antes do repasse. Os demais args seguem
# na ordem. (Expansão "${args[@]+...}" mais abaixo: bash 3.2 do macOS acusa variável não definida
# em array vazio sob set -u.)
ref=''
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      if [ $# -lt 2 ]; then step FAIL '--ref exige um valor (ex.: --ref main)'; exit 1; fi
      ref="$2"; shift 2 ;;
    --ref=*) ref="${1#--ref=}"; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ -n "$ref" ] && ! printf '%s' "$ref" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/-]*$'; then
  step FAIL "--ref com valor invalido: '$ref' (ex.: --ref main)"
  exit 1
fi

owner='Phenrique-DataDev'
repo='Native-sdd'
if [ -n "$ref" ]; then
  url="https://codeload.github.com/$owner/$repo/tar.gz/refs/heads/$ref"
  step INFO "ref: branch $ref (opt-in --ref; conteudo nao versionado por release)"
else
  # Padrão: a última release com tag. Falha da API é fatal — nunca cai na main em silêncio.
  api="https://api.github.com/repos/$owner/$repo/releases/latest"
  step INFO "consultando a ultima release em $api"
  # -S mostra o erro mesmo com -s; o 2>&1 leva o motivo (ex.: "error: 403") para a mensagem.
  if ! release_json="$(curl -fsSL "$api" 2>&1)"; then
    step FAIL "nao foi possivel consultar a ultima release (${release_json:-sem resposta})"
    step INFO 'para baixar o branch main em vez da release: ... | bash -s -- --ref main'
    exit 1
  fi
  # Here-string (não pipe): sem SIGPIPE sob pipefail quando o JSON é grande.
  tag="$(sed -n -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)".*/\1/p' <<<"$release_json")"
  tag="${tag%%$'\n'*}"
  if [ -z "$tag" ]; then
    step FAIL "a resposta de $api nao trouxe um tag_name valido"
    step INFO 'para baixar o branch main em vez da release: ... | bash -s -- --ref main'
    exit 1
  fi
  step INFO "release: $tag"
  # O que se baixa é o asset native-sdd-<tag>.tar.gz da release (git archive do commit publicado), conferido
  # contra o digest sha256 que a API devolve (BOOTSTRAP_SEM_PIN_NEM_HASH). Sem asset ou sem digest é fatal:
  # nunca cai no codeload sem verificação. Cobre corrupção/troca no download; NÃO cobre repositório
  # comprometido (o digest vem do mesmo GitHub). A API responde JSON indentado, um campo por linha.
  asset="native-sdd-$tag.tar.gz"
  asset_fields="$(awk -v want="$asset" '
    /"name"[[:space:]]*:/ { n = $0; sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", n); sub(/".*/, "", n); cur = (n == want) }
    cur && /"digest"[[:space:]]*:/ { d = $0; sub(/.*"digest"[[:space:]]*:[[:space:]]*"/, "", d); sub(/".*/, "", d); print "digest=" d }
    cur && /"browser_download_url"[[:space:]]*:/ { u = $0; sub(/.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", u); sub(/".*/, "", u); print "url=" u }
  ' <<<"$release_json")"
  expected_sha="$(sed -n -E 's/^digest=sha256:([0-9a-fA-F]{64})$/\1/p' <<<"$asset_fields" | head -n 1 | tr 'A-F' 'a-f')"
  url="$(sed -n 's/^url=//p' <<<"$asset_fields" | head -n 1)"
  if [ -z "$expected_sha" ] || [ -z "$url" ]; then
    step FAIL "a release $tag nao tem o asset $asset com digest sha256 — sem hash para conferir"
    step INFO 'para baixar o branch main (sem verificacao): ... | bash -s -- --ref main'
    exit 1
  fi
  case "$url" in
    "https://github.com/$owner/$repo/releases/download/"*) ;;
    *) step FAIL "URL do asset fora de https://github.com/$owner/$repo/releases/download/: $url"; exit 1 ;;
  esac
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
permanent="$HOME/.claude/.native-sdd-src"

step INFO "baixando $url"
curl -fsSL "$url" -o "$tmp/native-sdd.tar.gz"

if [ -z "$ref" ]; then
  if command -v sha256sum >/dev/null 2>&1; then actual_sha="$(sha256sum "$tmp/native-sdd.tar.gz" | cut -d ' ' -f 1)"
  elif command -v shasum >/dev/null 2>&1; then actual_sha="$(shasum -a 256 "$tmp/native-sdd.tar.gz" | cut -d ' ' -f 1)"
  else
    step FAIL "nem sha256sum nem shasum encontrados — impossivel conferir o hash do asset"
    exit 1
  fi
  if [ "$actual_sha" != "$expected_sha" ]; then
    step FAIL "sha256 do asset nao confere (esperado $expected_sha, baixado $actual_sha) — download abortado, nada foi instalado"
    exit 1
  fi
  step INFO "sha256 conferido: $actual_sha"
fi

step INFO "extraindo em $tmp"
tar -xzf "$tmp/native-sdd.tar.gz" -C "$tmp" --strip-components=1
rm -f "$tmp/native-sdd.tar.gz"

# Guard explícito: sem isso, estrutura inesperada (tar sem o wrapper de pasta-raiz que o codeload
# real sempre gera) vira um "No such file or directory" cru do bash, sem indicar a causa real
# (achado de revisão adversarial).
if [ ! -f "$tmp/onboarding/install.sh" ]; then
  step FAIL "estrutura inesperada apos extrair o tarball — onboarding/install.sh nao encontrado em $tmp"
  exit 1
fi

# Move (não copia) o conteúdo extraído para o cache permanente — substitui qualquer versão
# anterior (sempre reflete o último bootstrap rodado). Ver cabeçalho para o motivo (shim do shell).
step INFO "persistindo em $permanent"
rm -rf "$permanent"
mkdir -p "$(dirname "$permanent")"
mv "$tmp" "$permanent"

step INFO 'delegando a onboarding/install.sh (args repassados)'
bash "$permanent/onboarding/install.sh" ${args[@]+"${args[@]}"}
