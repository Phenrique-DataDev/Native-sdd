# herdr.psd1 — manifest de versão PINADA + integridade do binário `herdr` (multiplexador de agentes
# terminal-native, de terceiro: repo público GitHub herdrdev/herdr).
#
# Consumido por onboarding/windows/install-herdr.ps1 (flag opt-in -WithHerdr). Espelha o padrão de
# "manifest pinado" já usado no resto do onboarding: uma FONTE ÚNICA declara versão + URL + SHA-256,
# e o instalador RECUSA instalar um asset cujo hash não bata (ver o teste negativo de checksum).
#
# Schema:
#   Version   versão-alvo (pin lógico). Bump AQUI (um lugar só).
#   Assets    mapa <os>-<arch> -> { Tag; AssetName; UrlTemplate; Sha256; Bytes }
#             Tag         release/tag de onde o asset é baixado ({tag} no template)
#             AssetName   nome do arquivo do asset no release ({asset} no template)
#             UrlTemplate URL com placeholders {tag}/{asset}
#             Sha256      hash SHA-256 do asset (64 hex) OU o placeholder 'PENDENTE-verificar-manualmente'
#             Bytes       tamanho esperado em bytes (0 = desconhecido/não verificado)
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# NOTA DE REALIDADE (verificada em 2026-07-18 via `gh api repos/<upstream>/releases`):
# as releases ESTÁVEIS (v0.7.0..v0.7.4) publicam SÓ Linux/macOS. O binário WINDOWS x64 —
# o alvo PRIMÁRIO deste onboarding — sai APENAS no canal `preview-*`.
#
# DECISÃO 2026-07-19 — a distribuição adota o canal `preview-*`, e TODOS os 5 assets vêm da
# MESMA tag. Antes o manifest era misto (windows de um preview, os outros 4 de `v0.7.4`), o que
# fazia conviver binários de COMMITS DIFERENTES numa mesma instalação. Como só o preview publica
# o .exe, alinhar todo mundo a ele é o único jeito de ter as 5 plataformas do mesmo commit.
# O `Version` é o pin lógico/documental (o schema o valida como SEMVER — uma tag `preview-*` aqui
# REPROVARIA): a "Base stable" do release. Quando o corpo do release NÃO a declara (o preview de
# 2026-09-21 não declara), o bump deixa o `Version` como estava — confira pelo `--version` do
# binário e ajuste à mão. A verdade por-asset mora em cada `Tag`.
#
# COMO SUBIR DE VERSÃO: `pwsh tools/bump-herdr.ps1` (`-Check` só relata, `-DryRun` mede sem
# gravar). Ele resolve a release mais recente que publica TODOS os assets, baixa cada um, mede o
# SHA-256 e reescreve este arquivo. NÃO existe "latest em runtime" por decisão: o upstream não
# publica checksums (nenhum `.sha256`/`checksums.txt` em release nenhuma — verificado 2026-07-19),
# então resolver a última versão na hora de instalar significaria rodar binário de terceiro sem
# verificar NADA. O pin é a garantia; o script só torna barato mantê-lo atualizado.
#
# O ASSET DO WINDOWS VIROU .zip (upstream, 2026-07-29) — e não é o binário embrulhado.
# Medido abrindo o próprio arquivo (2026-08-08): traz `herdr.exe` + `conpty/` (conpty.dll,
# OpenConsole x64 e arm64, e um `herdr-conpty.json` que lista o SHA-256 de cada um) +
# THIRD-PARTY-NOTICES. As notas da v0.8.0 confirmam a intenção: *"Windows preview downloads now
# include Herdr and a modern app-local ConPTY runtime in one archive"*. Por isso o instalador
# extrai a ÁRVORE INTEIRA (`Expand-HerdrArchive`) — instalar só o `.exe` entregaria um herdr sem
# o runtime que o acompanha. Enquanto o `AssetName` daqui dizia `.exe`, o bump ficava preso na
# última release que ainda publicava `.exe` (2026-07-21) — em silêncio, até a v0.9.19.
#
# VALIDAÇÃO (2026-09-26, bump para preview-2026-09-21 / base stable v0.9.1): os 5 SHA-256 abaixo
# foram medidos por `tools/bump-herdr.ps1` baixando cada asset — nenhum placeholder. O do Windows
# tem verificação INDEPENDENTE por caminho diferente: `0BFD610F…` bate byte a byte com o hash
# computado à parte em Python sobre um download separado (`gh release download`). O `.zip` foi
# EXTRAÍDO e o binário EXECUTADO neste host: `--version` respondeu
# `herdr 0.9.1-preview.2026-09-21-0ff0f27e2226`, e a árvore preservou `conpty/x64`, `conpty/arm64`
# e o `herdr-conpty.json`. POR QUE este bump: a upstream #1849 (setas nos prompts de agente dentro
# do herdr no Windows) foi fechada em 2026-09-22 apontando o preview mais recente como o que traz o
# fix — é o gatilho de reabertura do `HERDR_SETAS_WINDOWS`. Que o sintoma de fato sumiu NÃO foi
# verificado: exige teclado físico num pane (ver o item no `features/BACKLOG.md`).
# O QUE NÃO FOI EXECUTADO (o limite continua igual ao de 2026-07-19): 'linux-x64', 'linux-arm64',
# 'macos-x64' e 'macos-arm64' — hash sólido (independe de execução), mas sem host compatível nesta
# sessão. O `config.toml` deste repositório foi extraído de um build v0.7.4 e NÃO foi reconfirmado
# contra o schema do 0.9.1; para casar com a versão instalada: `herdr --default-config`.
# ─────────────────────────────────────────────────────────────────────────────────────────────
@{
    Version = 'v0.9.1'

    Assets = @{
        # ALVO PRIMÁRIO — Windows x64. É um .zip (9.684.145 bytes) com o binário MAIS o runtime
        # ConPTY app-local, não um .exe solto — ver a nota acima. O hash é do ARCHIVE publicado; o
        # instalador aborta se o download não bater, e só então extrai a árvore.
        'windows-x64' = @{
            Tag         = 'preview-2026-09-21-0ff0f27e2226'
            AssetName   = 'herdr-windows-x86_64.zip'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = '0BFD610F32BECB5F299BB7BBCB48E4E6D07C1F57E41601FF3C0D7C99600B586D'
            Bytes       = 9684145
        }

        # --- Linux/macOS: hashes REAIS, verificados em Docker (ver NOTA DE REALIDADE acima) -------
        # 'linux-x64' foi EXECUTADO de verdade (--version/--help/--default-config); os outros 3
        # foram baixados e hasheados, mas não executados (sem host compatível nesta sessão).
        'linux-x64' = @{
            Tag         = 'preview-2026-09-21-0ff0f27e2226'
            AssetName   = 'herdr-linux-x86_64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = '70A91903C62630616C07786B955ADB513897889FFE77946BF8E29DEFC7B9D309'
            Bytes       = 29303328
        }
        'linux-arm64' = @{
            Tag         = 'preview-2026-09-21-0ff0f27e2226'
            AssetName   = 'herdr-linux-aarch64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = 'DA11BF1FBCC07950962788F251220118DBB693585D7BB1EAC8A4BB630A731A18'
            Bytes       = 27019192
        }
        'macos-x64' = @{
            Tag         = 'preview-2026-09-21-0ff0f27e2226'
            AssetName   = 'herdr-macos-x86_64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = '29837230A907DD01D684F54646500CAEE8ED24B667F8965F975EBD70F9DF693D'
            Bytes       = 23408728
        }
        'macos-arm64' = @{
            Tag         = 'preview-2026-09-21-0ff0f27e2226'
            AssetName   = 'herdr-macos-aarch64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = '203D7B29599A8BAFAF94BA476912E7173CAC2FB73D2988492AE9ABE4E0FB44DA'
            Bytes       = 21672688
        }
    }
}
