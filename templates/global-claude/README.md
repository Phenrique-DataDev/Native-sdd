# global-claude · Config pessoal de nível usuário

Conteúdo que vai para `~/.claude/` (aplica-se a **todos** os projetos).

| Arquivo | Destino | O que é |
|---------|---------|---------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | Identidade, stack, convenções e autonomia git pessoais |
| `statusline.ps1` | `~/.claude/statusline.ps1` | HUD do Claude Code (2 linhas: modelo, contexto, git, dir, tempo, tokens, custo) |
| `hooks/secret-guard.ps1` | `~/.claude/hooks/secret-guard.ps1` | Hook `PreToolUse`: `ask` em commit/push com segredo e ao ler `.env`/chave via Bash |
| `hooks/destructive-guard.ps1` | `~/.claude/hooks/destructive-guard.ps1` | Hook `PreToolUse`: `ask` em destrutivo não-git (`rm -rf` fora do cwd, `chmod -R`, `curl\|sh`) e git destrutivo (`clean -fdx`, `restore`, `stash drop`) |
| `hooks/lib/secret-patterns.ps1` | `~/.claude/hooks/lib/secret-patterns.ps1` | **Fonte única** de detecção de segredos (regex + paths), compartilhada por hooks e pre-commit |
| `settings.json` | `~/.claude/settings.json` | Liga `statusLine` + `permissions.defaultMode` + `hooks.PreToolUse` aos scripts (instalado por **merge**, sem apagar sua config) |

> **`.json` = merge:** o instalador mescla `settings.json` na sua config existente (com
> backup), em vez de sobrescrever. Os demais arquivos espelham 1:1.

## Statusline

Mostra no rodapé do Claude Code: modelo · git (branch +staged ~modified ?untracked) · dir ·
versão (linha 1); barra de contexto + % · tokens do contexto/limite · tempo de sessão ·
tokens totais · custo (linha 2). Cores Dracula. Roda via `pwsh` (instalado no A1).

## Destructive guard (hook PreToolUse)

`hooks/destructive-guard.ps1` é um hook **`PreToolUse`** (matcher `Bash`) que torna a proteção
contra comandos destrutivos **determinística** — em vez de só regra textual:

| Situação (comando Bash) | Decisão |
|-------------------------|---------|
| Rotineiro / destrutivo **dentro** do projeto (`rm -rf ./build`, `git status`, `git clean -n`) | **passthrough** |
| Destrutivo **não-git** fora do cwd ou amplo (`rm -rf /etc`, `chmod -R 777 /`, `curl … \| sh`, `rm -rf ../x`) | **`ask`** |
| Git destrutivo de trabalho não-commitado (`git clean -fdx`, `git restore .`, `git stash drop`) | **`ask`** |

**Fail-safe assimétrico:** antes de confirmar que o comando é destrutivo, qualquer erro vira
passthrough; depois, vira `ask` — nunca `allow` por engano. Só inspeciona o comando (regex); nunca
o executa. Tem **paridade** `.ps1` ⇆ `.sh` (a versão `.sh` roda quando não há `pwsh`).

> **Limitação do merge (`settings.json`):** o instalador mescla objetos, mas **arrays substituem**.
> Se você já tiver um `hooks.PreToolUse` próprio em `~/.claude/settings.json`, o merge do baseline
> o **sobrescreve** (com backup). Reaplique seus hooks manualmente após o merge, se for o caso.

## Secret guard (hook PreToolUse) — segredo em modo `ask`

`hooks/secret-guard.ps1` é o irmão do destructive-guard: não bloqueia, só **pede confirmação**
quando detecta possível segredo. Filosofia *educar, não barrar*.

| Situação (comando Bash) | Decisão |
|-------------------------|---------|
| Lê/exfiltra arquivo de segredo (`cat .env`, `*.pem`, `secrets/…`) | **`ask`** — fecha o bypass do `Read(.env)` da managed policy |
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

`settings.json` define `defaultMode: "auto"` — **menos prompts** no Bash geral, priorizando o
fluxo. As redes de segurança que importam **não** são o prompt: os **hooks `PreToolUse`**
(`secret-guard`, `destructive-guard`) **disparam em qualquer modo** e seu `ask`/`deny` **sobrepõe**
a auto-aprovação, e a *managed policy* nega o catastrófico/segredos de forma inviolável. Assim o
`auto` reduz o atrito sem desligar a proteção de segredo/destrutivo.

> **Risco residual:** o comportamento exato de `auto` **não está documentado** (adotado com risco
> assumido). O **destrutivo não-git** (`rm -rf` arbitrário, `curl|sh`) já tem rede determinística
> no `destructive-guard`. Para travar mais, use `acceptEdits` (pergunta no sensível) ou `dontAsk`
> (default-deny); para afrouxar tudo, `bypassPermissions` (nunca pergunta — **sem** rede).

## Como instalar (manual)

```powershell
Copy-Item .\CLAUDE.md "$env:USERPROFILE\.claude\CLAUDE.md"
```

> O instalador automático (`onboarding/`, feature A2) fará isso — com backup do arquivo
> existente antes de sobrescrever.

## Hierarquia de loading

`managed policy → este arquivo (global) → projeto/.claude/CLAUDE.md → projeto/CLAUDE.local.md`

O mais específico vence: regras de projeto têm precedência sobre as globais.
