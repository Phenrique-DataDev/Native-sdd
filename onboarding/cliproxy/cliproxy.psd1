# cliproxy.psd1 — manifest de versão PINADA + integridade do binário `cli-proxy-api`
# (CLIProxyAPI, de terceiro: repo público GitHub router-for-me/CLIProxyAPI).
#
# PARA QUE SERVE: é o motor que permite usar modelo por LOGIN DE ASSINATURA (OAuth) em vez de
# chave de API — `Engine = 'cliproxy'` nos perfis do claudex. O outro motor (litellm) cobre o
# caminho de chave de API; este cobre o de conta.
#
# Consumido por onboarding/windows/install-cliproxy.ps1 (flag opt-in -WithCliProxy). Mesmo padrão
# de "manifest pinado" do herdr: FONTE ÚNICA declara versão + URL + SHA-256, e o instalador
# RECUSA instalar asset cujo hash não bata (ver o teste negativo de checksum).
#
# Schema (idêntico ao de herdr.psd1, de propósito — um molde só para binário de terceiro):
#   Version   versão-alvo (pin lógico). Bump AQUI (um lugar só).
#   Assets    mapa <os>-<arch> -> { Tag; AssetName; UrlTemplate; Sha256; Bytes; Archive; BinaryPath }
#             Archive     'zip' | 'tar.gz' — este projeto distribui ARQUIVO, não binário solto
#                         (diferente do herdr), então o instalador precisa extrair.
#             BinaryPath  caminho do executável DENTRO do arquivo extraído.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# VERIFICAÇÃO (2026-07-19), em três camadas:
#   1. O upstream publica `checksums.txt` assinado no próprio release — os hashes abaixo vêm de lá.
#   2. NÃO confiamos só nisso: o asset windows_amd64 foi BAIXADO e hasheado de forma independente
#      (`sha256sum`), e bateu com o publicado. Mesmo procedimento do herdr.
#   3. O binário windows_amd64 foi EXECUTADO de verdade nesta máquina:
#        CLIProxyAPI Version: 7.2.91, Commit: fde40c5a, BuiltAt: 2026-07-19T18:08:17Z
#      e o `--help` confirmou AO VIVO as flags de login OAuth que o claudex usa
#      (-claude-login, -codex-login, -antigravity-login, -kimi-login, -no-browser,
#      -oauth-callback-port, -config). Isso deixou de ser leitura de doc.
#
#   4. LINUX x64 TAMBÉM FOI EXECUTADO (2026-07-19), em container `mcr.microsoft.com/powershell`:
#      o instalador baixou, o SHA-256 bateu, o tar.gz extraiu e o binário rodou —
#        CLIProxyAPI Version: 7.2.91, Commit: fde40c5a  (MESMO commit do build Windows)
#      e o `--help` mostrou as mesmas flags de login. A 2ª rodada deu SKIP (idempotente).
#      Foi essa rodada que revelou o bug de detecção de arch em Get-CliProxyHostArch: o manifest
#      declarava linux/macos, mas o código NUNCA chegava neles fora do Windows.
#
# NÃO EXECUTADOS (só hash publicado, conferido contra o checksums.txt do release): os assets
# arm64 (windows/linux/macos) e macos-x64 — falta hardware/emulação para rodá-los aqui.
# Declarado, não presumido.
#
# VARIANTE ESCOLHIDA: os builds "com plugin" (sem o sufixo `_no-plugin`). O claudex mantém
# `plugins.enabled: false` na config que gera — plugin é código dinâmico in-process, e nada no
# nosso fluxo precisa disso.
# ─────────────────────────────────────────────────────────────────────────────────────────────
@{
    Version = 'v7.2.91'

    Assets = @{
        # ALVO PRIMÁRIO — Windows x64. Hash baixado E verificado independentemente (ver acima).
        'windows-x64' = @{
            Tag         = 'v7.2.91'
            AssetName   = 'CLIProxyAPI_7.2.91_windows_amd64.zip'
            UrlTemplate = 'https://github.com/router-for-me/CLIProxyAPI/releases/download/{tag}/{asset}'
            Sha256      = '2D6DACAFE985CCFDC635EC02A64FEF1100F8DE5ECB308500E92C5656B20195E4'
            Bytes       = 15449992
            Archive     = 'zip'
            BinaryPath  = 'cli-proxy-api.exe'
        }
        'windows-arm64' = @{
            Tag         = 'v7.2.91'
            AssetName   = 'CLIProxyAPI_7.2.91_windows_aarch64.zip'
            UrlTemplate = 'https://github.com/router-for-me/CLIProxyAPI/releases/download/{tag}/{asset}'
            Sha256      = 'CCBBC44CA4D8A628717C41275BFC74FA1E2F0726851DB5726A06691C0D168B9E'
            Bytes       = 13983348
            Archive     = 'zip'
            BinaryPath  = 'cli-proxy-api.exe'
        }

        # --- Linux/macOS -------------------------------------------------------------------------
        # linux-x64: BAIXADO, hash conferido e EXECUTADO em container (ver cabeçalho).
        # Os demais: só hash publicado.
        'linux-x64' = @{
            Tag         = 'v7.2.91'
            AssetName   = 'CLIProxyAPI_7.2.91_linux_amd64.tar.gz'
            UrlTemplate = 'https://github.com/router-for-me/CLIProxyAPI/releases/download/{tag}/{asset}'
            Sha256      = '3DD8F22D7541F3D34FB411EA24CC4C30CA8DC6141953C5CEE3EBF6583D1E6027'
            Bytes       = 15223540
            Archive     = 'tar.gz'
            BinaryPath  = 'cli-proxy-api'
        }
        'linux-arm64' = @{
            Tag         = 'v7.2.91'
            AssetName   = 'CLIProxyAPI_7.2.91_linux_aarch64.tar.gz'
            UrlTemplate = 'https://github.com/router-for-me/CLIProxyAPI/releases/download/{tag}/{asset}'
            Sha256      = 'E7AFF7BB8E68BF83EA99639594B63F0074160DA8F555C63D0B8CC0590B2D23E9'
            Bytes       = 13901791
            Archive     = 'tar.gz'
            BinaryPath  = 'cli-proxy-api'
        }
        'macos-x64' = @{
            Tag         = 'v7.2.91'
            AssetName   = 'CLIProxyAPI_7.2.91_darwin_amd64.tar.gz'
            UrlTemplate = 'https://github.com/router-for-me/CLIProxyAPI/releases/download/{tag}/{asset}'
            Sha256      = '72063D1BA0406F7A4E3C133500569CB026D1A8AB3267CC73CB2DA34F3684D12E'
            Bytes       = 15193300
            Archive     = 'tar.gz'
            BinaryPath  = 'cli-proxy-api'
        }
        'macos-arm64' = @{
            Tag         = 'v7.2.91'
            AssetName   = 'CLIProxyAPI_7.2.91_darwin_aarch64.tar.gz'
            UrlTemplate = 'https://github.com/router-for-me/CLIProxyAPI/releases/download/{tag}/{asset}'
            Sha256      = 'A4EBC39F03A8D49D089338574AC54C340773C8D46873121E4231088C56CC816E'
            Bytes       = 14218732
            Archive     = 'tar.gz'
            BinaryPath  = 'cli-proxy-api'
        }
    }
}
