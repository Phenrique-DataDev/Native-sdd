---
description: "Coordenação entre sessões concorrentes: lista peers ativos, lê sua caixa e envia recados (file-based, read-only por padrão)"
---

# /peers — quem mais está trabalhando neste projeto

Mostra as **outras sessões do Claude Code ativas no mesmo projeto** (presença + branch + summary +
idade do heartbeat) e a **sua caixa de recados**. Versão nativa, file-based, da tática do
`claude-peers-mcp` — **sem daemon**: o quadro vive em `.claude/.cache/peers/` (gitignored), escrito
pelo hook `peer-heartbeat`. Pull on-demand; distinto do `/status` (estado do próprio projeto).

> O **seu id de peer** é o `session_id` da sessão — o hook `peer-heartbeat` o anuncia no
> `SessionStart` ("peers: sua sessão é '<id>'"). Use **esse id** nos passos abaixo (`-SelfId`/`-Id`).
> Se você não o tem no contexto (hook não rodou / sem pwsh), liste mesmo assim e avise que a caixa
> própria fica indisponível sem o id.

---

## Uso

```text
/peers                      # lista peers ativos + sua caixa (e marca os recados como lidos)
/peers msg <id> <texto>     # envia um recado a outro peer
/peers summary <texto>      # sobrescreve o summary da sua sessão
```

---

## Passo 1 — Resolver a camada `tools/` e agir

```powershell
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
if ($toolsRoot) {
    . "$toolsRoot/peers.ps1"
    $board = Resolve-PeerBoard -Root .
    $self  = '<session_id desta sessão — do anúncio do peer-heartbeat>'

    # LISTAR (default): poda mortos, lê a caixa (read-once) e imprime o painel
    Remove-StalePeers -BoardDir $board | Out-Null
    $peers = Get-PeerInventory -BoardDir $board -SelfId $self
    $inbox = if ($self) { Read-PeerInbox -BoardDir $board -Id $self } else { @() }
    Format-PeerReport -Peers $peers -Inbox $inbox -NowEpoch (Get-PeerNow) -SelfId $self

    # ENVIAR recado:   /peers msg <id> <texto>
    #   Add-PeerMessage -BoardDir $board -Dest '<id>' -From $self -Text '<texto>'
    # TROCAR summary:  /peers summary <texto>
    #   Set-PeerSummary -BoardDir $board -Id $self -Text '<texto>'
}
```

`Get-PeerInventory` lê o board e marca `IsStale` (heartbeat > TTL de 15 min) e `IsSelf`;
`Format-PeerReport` lista **só os ativos** (exclui você) e a caixa; `Read-PeerInbox` entrega cada
recado **uma vez** (move p/ `inbox/.read/`). Tudo determinístico em `tools/peers.ps1` (Pester).

---

## Passo 2 — Degradação consciente

Se `$toolsRoot` **não resolver** (sem `tools/` relativo nem `$env:SDD_WORKFLOW_HOME`), **avise** que o
quadro de peers está indisponível (camada determinística ausente) e **não** reimplemente a leitura do
board à mão em silêncio. Sem o `session_id` próprio no contexto, liste os peers, mas avise que a
**caixa própria** não pode ser resolvida.

---

## Regras

- **Default read-only para o board dos outros:** `/peers` só lê presença alheia; escreve apenas a
  **própria** presença/summary e os **recados que você envia**. Nunca toca `.claude/kb|agents|rules`.
- **Read-once:** ao listar, a sua caixa é **consumida** (os recados vão p/ `inbox/.read/`). Não relê o
  mesmo recado duas vezes — quem precisa registrar, registra em `docs/` (`/document`).
- **Sem rede, sem PII:** o summary deriva de branch + fase SDD + **nomes** de arquivos (nunca conteúdo).
  O board é runtime (`.cache/`, gitignored) — fora do git e da distribuição.
- **Mensageria assíncrona:** o recado chega na próxima vez que o destino rodar `/peers` (ou no
  `SessionStart` dele) — não é entrega instantânea.
