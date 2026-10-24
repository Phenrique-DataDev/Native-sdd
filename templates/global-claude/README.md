# global-claude · Config pessoal de nível usuário

Conteúdo que vai para `~/.claude/` (aplica-se a **todos** os projetos).

| Arquivo | Destino | O que é |
|---------|---------|---------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | Template: context7, comunicação, git e autonomia, regras invioláveis. *Identidade* vem em comentário HTML para você preencher |
| `statusline.ps1` | `~/.claude/statusline.ps1` | HUD do Claude Code (2 linhas: modelo, contexto, git, dir, tempo, tokens, rate limit, custo) |
| `statusline.sh` | `~/.claude/statusline.sh` | Gêmeo POSIX/bash do `statusline.ps1` (roda quando não há `pwsh`; requer `jq`) |
| `statusline.theme.example` | `~/.claude/statusline.theme.example` | Exemplo de tema — copie p/ `~/.claude/statusline.theme` p/ trocar cores/thresholds |
| `hooks/bash-guards.ps1` / `.sh` | `~/.claude/hooks/` | O hook `PreToolUse` registrado, em dois grupos (matcher `Bash` e matcher `PowerShell`, a mesma linha): um dispatcher que roda o secret-guard e o destructive-guard num processo só |
| `hooks/secret-guard.ps1` / `.sh` | `~/.claude/hooks/` | Lógica do guard de segredo: `ask` em commit/push com segredo e ao ler `.env`/chave via Bash |
| `hooks/destructive-guard.ps1` / `.sh` | `~/.claude/hooks/` | Lógica do guard destrutivo: `ask` em destrutivo não-git (`rm -rf`/`chmod -R 777` fora do cwd/TEMP, `curl\|sh`) e em git destrutivo (`clean -fdx`, `restore`, `stash drop`) fora do TEMP |
| `hooks/lib/secret-patterns.ps1` / `.sh` | `~/.claude/hooks/lib/` | **Fonte única** de detecção de segredos (regex + paths), compartilhada por hooks e pre-commit |
| `hooks/lib/destructive-patterns.ps1` / `.sh` | `~/.claude/hooks/lib/` | Padrões do destructive-guard |
| `hooks/adapters/` | `~/.claude/hooks/adapters/` | Adapters dos guards para Cursor, Codex e OpenCode — ver [`docs/HARNESS-CONTRACT.md`](../../docs/HARNESS-CONTRACT.md) |
| `skills/native-sdd-*/` | `~/.claude/skills/` | Porta de entrada fora de um projeto: `native-sdd-novo-projeto` (roda o `new-project.ps1`), `native-sdd-doctor` (`install -Check`) e `native-sdd-atualizar` (`pull --ff-only` + `-DryRun`; só por `/`, com `disable-model-invocation`). Acham o checkout por `SDD_WORKFLOW_HOME` |
| `settings.json` | `~/.claude/settings.json` | Liga `statusLine`, `env.SDD_WORKFLOW_HOME`, `enableWorkflows`, `permissions.defaultMode: "auto"` e o hook `PreToolUse` do Bash (instalado por **merge**, sem apagar sua config) |

> **`.json` = merge:** o instalador mescla `settings.json` na sua config existente (com
> backup), em vez de sobrescrever. Os demais arquivos espelham 1:1.

## Statusline

Mostra no rodapé do Claude Code: modelo · git (branch +staged ~modified ?untracked) · dir ·
versão (linha 1); barra de contexto + % · tokens do contexto/limite · **rate limit (5h/7d)** ·
tempo de sessão · custo (linha 2).

**Temas (role-based).** As cores são roles semânticas — `primary` (modelo), `accent` (dir, rótulo
`5h`/`7d`), `success`/`warning`/`caution`/`danger` (faixas), `muted`, `track`. Seleção por precedência:
`~/.claude/statusline.theme` → `$env:SDD_STATUSLINE_THEME` → `dracula` (default). Temas embutidos:
`dracula`, `onedark`, `catppuccin`. O arquivo `.theme` também sobrescreve roles individuais
(`primary = R,G,B`) e os thresholds coloridos (`th_low`/`th_mid`/`th_high`) — ver
`statusline.theme.example`.

**Rate limit (5h/7d).** Vem do próprio JSON de status (`rate_limits.five_hour|seven_day`), que o
Claude Code só envia p/ assinantes **Pro/Max** e após a 1ª resposta da sessão. Cada janela mostra
**etiqueta** (`5h`/`7d`, em accent fixo) + **mini-barra** de 4 blocos (`▰▱`, cor por faixa) + **%**;
o **tempo até o reset** (resumido: `2h`, `18m`, `2d` — de `resets_at`) aparece só na janela de
**maior uso** — a que aperta. Cada janela e o custo degradam sozinhos: quem é **API-user** vê o
custo em `$`; quem é Pro/Max vê as janelas de rate.

**Portabilidade (dois shells).** `settings.json` chama uma dispatch-line que prefere `pwsh`
(`statusline.ps1`) e cai p/ `bash` (`statusline.sh`, via `jq`) quando `pwsh` falta — mesmo padrão
dos hooks. No Windows o instalador reescreve p/ `pwsh -File` nativo (sem depender de `sh` no PATH).

**Guard de harness.** Se o stdin não for o schema do Claude Code (vazio, outra harness, invocação
manual), ambos saem **silenciosos** (`exit 0`) em vez de imprimir uma linha torta.

**Profundidade de cor (tmux/psmux).** Respeita `NO_COLOR` (qualquer valor não-vazio → texto puro,
padrão [no-color.org](https://no-color.org)) e `SDD_STATUSLINE_COLOR` = `truecolor` | `256` | `off`
(default `truecolor`, preserva o comportamento atual). Em **tmux sem RGB capability**, exporte
`SDD_STATUSLINE_COLOR=256` para cores 8-bit previsíveis — ou habilite truecolor no tmux com
`set -as terminal-features ',*:RGB'`. Não caímos para 256 automaticamente só por `COLORTERM`
ausente (regrediria os muitos terminais que suportam truecolor sem anunciá-lo).

## Destructive guard (hook PreToolUse)

`hooks/destructive-guard.ps1` é um hook **`PreToolUse`** (matcher `Bash`) que torna a proteção
contra comandos destrutivos **determinística** — em vez de só regra textual:

| Situação (comando Bash) | Decisão |
|-------------------------|---------|
| Rotineiro / destrutivo **dentro** do projeto ou do TEMP (`rm -rf ./build`, `rm -rf "$TEMP/x"`, `chmod -R 777 ./bin`, `git status`, `git clean -n`) | **passthrough** |
| Variável de loop depois de um prefixo já seguro (`rm -rf "$SP/ab/$arm"`), `$$`/`$RANDOM` no nome | **passthrough** |
| `curl … \| python -c`/`node -e`/`python -m json.tool` (o download é dado, o script é inline) | **passthrough** |
| Destrutivo **não-git** fora do cwd/TEMP ou amplo (`rm -rf /etc`, `chmod -R 777 /`, `chmod -R 777 .`, `curl … \| sh`, `curl … \| python`, `rm -rf ../x`) | **`ask`** |
| Git destrutivo de trabalho não-commitado (`git clean -fdx`, `git restore .`, `git checkout -- x`, `git stash drop`, também com `git -C dir`) | **`ask`**; **passthrough** se o repositório (cwd, `cd X` ou `git -C X`) está dentro do TEMP |

**Fail-safe assimétrico:** antes de confirmar que o comando é destrutivo, qualquer erro vira
passthrough; depois, vira `ask` — nunca `allow` por engano. Só inspeciona o comando (regex); nunca
o executa. Tem **paridade** `.ps1` ⇆ `.sh` (a versão `.sh` roda quando não há `pwsh`).

> **Merge do `settings.json`:** o instalador faz merge 3-way (objetos recursam; arrays **preservam**
> o que você adicionou). Um `hooks.PreToolUse` próprio em `~/.claude/settings.json` sobrevive ao
> reinstall; só sai o que o template entregou antes e retirou depois.

## Secret guard (hook PreToolUse) — segredo em modo `ask`

`hooks/secret-guard.ps1` é o irmão do destructive-guard: não bloqueia, só **pede confirmação**
quando detecta possível segredo. Filosofia *educar, não barrar*.

| Situação (comando Bash) | Decisão |
|-------------------------|---------|
| Lê/exfiltra arquivo de segredo (`cat .env`, `*.pem`, `secrets/…`) | **`ask`** — cobre o que o deny de `Read(.env)` não pega: leitura indireta, `type`/`Get-Content`, e máquina sem managed policy |
| `git commit` cujo **diff staged** contém segredo de **alta confiança** | **`ask`** |
| `git push` cujo **diff a enviar** contém segredo de **alta confiança** | **`ask`** |
| Qualquer outro caso | **passthrough** |

> Commit/push usam confiança **`High`** (mesmo nível do pre-commit): só formatos específicos
> de credencial (`AKIA…`, `gh?_…`, `BEGIN PRIVATE KEY`, JWT). Assignments genéricos (`token = "…"`)
> **não** viram prompt aqui — evita falso-positivo em config/docs/testes. A leitura de `.env`/chave
> pede confirmação independente de confiança.

Mesmo **fail-safe assimétrico** dos demais guards. A detecção vem da **lib única**
`hooks/lib/secret-patterns.ps1` — a mesma consumida pelo git **pre-commit** do scaffold
(`.githooks/secret-scan.ps1`), que aí sim **bloqueia** o commit (rede determinística). Não há
dupla fonte de verdade: regex e paths de segredo vivem num só lugar.

## Modo de permissão (`permissions.defaultMode`)

`settings.json` define `defaultMode: "auto"` — **menos prompts**, priorizando o fluxo. No `auto`,
um classificador revisa cada comando antes de rodar (desde a v2.1.283 ele é também o modo inicial
built-in; a chave explícita cobre versões anteriores e planos em que o default é outro). As redes
determinísticas **não** são o prompt: os **hooks `PreToolUse`** (`secret-guard`,
`destructive-guard`) **disparam em qualquer modo** e seu `ask`/`deny` **sobrepõe** o `auto`, e a
*managed policy* nega o catastrófico/segredos de forma inviolável.

> **Risco residual:** a doc avisa que o auto mode *"does not guarantee safety"* — o classificador é
> probabilístico. O **destrutivo não-git** (`rm -rf` arbitrário, `curl|sh`) tem rede determinística
> no `destructive-guard`. Para travar mais, use `acceptEdits` (pergunta no sensível) ou `dontAsk`
> (default-deny); para afrouxar tudo, `bypassPermissions` (nunca pergunta — **sem** rede).
>
> **Push no `auto`:** o `CLAUDE.md` pede que o modelo confirme antes de dar push, mas isso é
> instrução, não trava. Pela doc de permission modes, o classificador deixa passar *"pushing to any
> branch of the repository you're working in, including the default branch"*, fora os casos da lista
> de bloqueio (segredo, force push). Se quiser o prompt garantido, acrescente
> `"ask": ["Bash(git push *)", "PowerShell(git push *)"]` em `permissions` no seu
> `~/.claude/settings.json`: regra `ask` que casa o conteúdo do comando volta a pedir confirmação no
> `auto`. O template não traz isso por padrão, para não pedir confirmação a cada push de quem trabalha
> em branch.

## Como instalar (manual)

```powershell
Copy-Item .\CLAUDE.md "$env:USERPROFILE\.claude\CLAUDE.md"
```

> O instalador (`onboarding/install.ps1`, passo A2 do `apply.ps1`) já faz isso para a pasta
> inteira, com backup do arquivo existente antes de sobrescrever.

## Hierarquia de loading

`este arquivo (global) → <projeto>/CLAUDE.md → <projeto>/CLAUDE.local.md`

O Claude Code **concatena** os três, do mais amplo ao mais específico, sem precedência automática.
A precedência vem do texto: este arquivo e o `CLAUDE.md` do projeto **declaram** que o projeto vence
em conflito. A managed policy (`managed-settings.json`) é outra coisa: permissão aplicada pelo
harness, que nenhum texto afrouxa.
