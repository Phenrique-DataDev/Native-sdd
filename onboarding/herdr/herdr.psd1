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
# O `Version` fica em 'v0.7.4' como pin lógico/documental (o schema o valida como SEMVER — uma
# tag `preview-*` aqui REPROVARIA); é a "Base stable" declarada pelo próprio release. A verdade
# por-asset mora em cada `Tag`.
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
# VALIDAÇÃO (2026-08-08, bump para preview-2026-08-04 / base stable v0.8.0): os 5 SHA-256 abaixo
# foram medidos por `tools/bump-herdr.ps1` baixando cada asset — nenhum placeholder. O do Windows
# tem verificação INDEPENDENTE por caminho diferente: `B1D28811…` bate byte a byte com o hash
# computado à parte em Python sobre o mesmo download. O `.zip` foi EXTRAÍDO e o binário resultante
# EXECUTADO neste host: `--version` respondeu `herdr 0.8.0-preview.2026-08-04-d78e3d3b5126`, e a
# árvore instalada preservou `conpty/x64`, `conpty/arm64` e o `herdr-conpty.json`.
# O QUE NÃO FOI EXECUTADO (o limite continua igual ao de 2026-07-19): 'linux-x64', 'linux-arm64',
# 'macos-x64' e 'macos-arm64' — hash sólido (independe de execução), mas sem host compatível nesta
# sessão. O `config.toml` deste repositório foi extraído de um build v0.7.4 e NÃO foi reconfirmado
# contra o schema do 0.8.0; para casar com a versão instalada: `herdr --default-config`.
# ─────────────────────────────────────────────────────────────────────────────────────────────
@{
    Version = 'v0.8.0'

    Assets = @{
        # ALVO PRIMÁRIO — Windows x64. É um .zip (7.871.795 bytes) com o binário MAIS o runtime
        # ConPTY app-local, não um .exe solto — ver a nota acima. O hash é do ARCHIVE publicado; o
        # instalador aborta se o download não bater, e só então extrai a árvore.
        'windows-x64' = @{
            Tag         = 'preview-2026-08-04-d78e3d3b5126'
            AssetName   = 'herdr-windows-x86_64.zip'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = 'B1D288118848ECD3EF33532A34506EDC53A38A416057AEE5B7FE1DE4188A16FC'
            Bytes       = 7871795
        }

        # --- Linux/macOS: hashes REAIS, verificados em Docker (ver NOTA DE REALIDADE acima) -------
        # 'linux-x64' foi EXECUTADO de verdade (--version/--help/--default-config); os outros 3
        # foram baixados e hasheados, mas não executados (sem host compatível nesta sessão).
        'linux-x64' = @{
            Tag         = 'preview-2026-08-04-d78e3d3b5126'
            AssetName   = 'herdr-linux-x86_64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = '338AFBFE03F0EB32EFC52E30A5EFFC6C5EE772846BDB5E059F73D04B89B467D6'
            Bytes       = 21795896
        }
        'linux-arm64' = @{
            Tag         = 'preview-2026-08-04-d78e3d3b5126'
            AssetName   = 'herdr-linux-aarch64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = 'F79F3AD5B24DD1B6BA49EBEE1B26D69AB5DCBEAF15BE4FD7F3357AB0D17F6096'
            Bytes       = 19966672
        }
        'macos-x64' = @{
            Tag         = 'preview-2026-08-04-d78e3d3b5126'
            AssetName   = 'herdr-macos-x86_64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = '384EE2F2A805260D24F3D398BA8169AA68B502452AB1457C5DA40A8E4D9C975F'
            Bytes       = 19677488
        }
        'macos-arm64' = @{
            Tag         = 'preview-2026-08-04-d78e3d3b5126'
            AssetName   = 'herdr-macos-aarch64'
            UrlTemplate = 'https://github.com/herdrdev/herdr/releases/download/{tag}/{asset}'
            Sha256      = 'D02190962293CCF19186E0EA8A162D7F670EF49E61DFC10051BFFD7DA08A7EE4'
            Bytes       = 18121568
        }
    }
}
