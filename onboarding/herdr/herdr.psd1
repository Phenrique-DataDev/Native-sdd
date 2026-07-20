# herdr.psd1 — manifest de versão PINADA + integridade do binário `herdr` (multiplexador de agentes
# terminal-native, de terceiro: repo público GitHub ogulcancelik/herdr).
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
# NOTA DE REALIDADE (verificada em 2026-07-18 via `gh api repos/ogulcancelik/herdr/releases`):
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
# VALIDAÇÃO (2026-07-19, após o bump para o preview): os 5 SHA-256 abaixo foram medidos por
# `tools/bump-herdr.ps1` baixando cada asset — nenhum placeholder sobra. Dois deles têm
# verificação INDEPENDENTE, por caminho diferente: 'windows-x64' bate byte a byte com o hash que
# já estava pinado (obtido antes por outro método), e 'linux-x64' foi re-medido com `sha256sum`
# dentro de um container `debian:bookworm-slim` isolado (`docker run --rm`), onde também foi
# EXECUTADO — `--version` respondeu `herdr 0.7.4-preview.2026-07-17-813fec141faa` (binário
# funcional, não só bytes corretos) e `--default-config` reconfirmou o schema de
# onboarding/herdr/config.toml para ESTE build, não para o v0.7.4 anterior.
# O QUE NÃO FOI EXECUTADO (honestidade sobre o limite): 'linux-arm64' (QEMU falhou — o Docker
# Desktop desta máquina não tem binfmt_misc para arm64) e 'macos-x64'/'macos-arm64' (não dá para
# rodar Mach-O neste host sem VM macOS, fora de escopo). Nesses 3 o hash é sólido — ele independe
# de execução — mas o `--default-config` não foi reconfirmado; o config.toml assume schema igual
# entre plataformas (razoável para um binário Rust cross-compilado do mesmo commit, e agora
# TODOS vêm mesmo do mesmo commit, mas não confirmado nessas 3 arquiteturas).
# ─────────────────────────────────────────────────────────────────────────────────────────────
@{
    Version = 'v0.7.4'

    Assets = @{
        # ALVO PRIMÁRIO — Windows x64. Hash SHA-256 REAL, verificado nesta sessão baixando o asset
        # uma vez e computando `Get-FileHash -Algorithm SHA256` / `sha256sum` (2026-07-18).
        # Binário = 17.780.224 bytes. O instalador aborta se o download não bater com este hash.
        'windows-x64' = @{
            Tag         = 'preview-2026-07-17-813fec141faa'
            AssetName   = 'herdr-windows-x86_64.exe'
            UrlTemplate = 'https://github.com/ogulcancelik/herdr/releases/download/{tag}/{asset}'
            Sha256      = '2B53A21755D6393515F84C246B6297D46103E7E741714BCF2244B408C1178D57'
            Bytes       = 17780224
        }

        # --- Linux/macOS: hashes REAIS, verificados em Docker (ver NOTA DE REALIDADE acima) -------
        # 'linux-x64' foi EXECUTADO de verdade (--version/--help/--default-config); os outros 3
        # foram baixados e hasheados, mas não executados (sem host compatível nesta sessão).
        'linux-x64' = @{
            Tag         = 'preview-2026-07-17-813fec141faa'
            AssetName   = 'herdr-linux-x86_64'
            UrlTemplate = 'https://github.com/ogulcancelik/herdr/releases/download/{tag}/{asset}'
            Sha256      = '9EF34A56091F5B3E2054C2A8E6AABD9056FE22E2FAD36147A51EC8DC8F4FDE73'
            Bytes       = 19392608
        }
        'linux-arm64' = @{
            Tag         = 'preview-2026-07-17-813fec141faa'
            AssetName   = 'herdr-linux-aarch64'
            UrlTemplate = 'https://github.com/ogulcancelik/herdr/releases/download/{tag}/{asset}'
            Sha256      = 'D1FC0DDD3CE161A5718131B9FDE063846CA1348BDE50ABF71D5E01A43FD93D8D'
            Bytes       = 17769784
        }
        'macos-x64' = @{
            Tag         = 'preview-2026-07-17-813fec141faa'
            AssetName   = 'herdr-macos-x86_64'
            UrlTemplate = 'https://github.com/ogulcancelik/herdr/releases/download/{tag}/{asset}'
            Sha256      = 'F0C2541C3A21CCCD95173B5E9356884415E41B77AEB66C536324FA70227B5598'
            Bytes       = 17297760
        }
        'macos-arm64' = @{
            Tag         = 'preview-2026-07-17-813fec141faa'
            AssetName   = 'herdr-macos-aarch64'
            UrlTemplate = 'https://github.com/ogulcancelik/herdr/releases/download/{tag}/{asset}'
            Sha256      = '9103B90851242053A4778D5E16364C1AFD178A2A2F6CF8C1705F0E75B4C470B3'
            Bytes       = 15980816
        }
    }
}
