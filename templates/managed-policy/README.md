# Managed policy (opcional) — C3

> Política de **segurança/governança** para o Claude Code, **inviolável** quando ativa: vence
> as configs de usuário e de projeto (topo da [hierarquia de loading](../../methodology/01-onboarding/README.md#hierarquia-de-loading-precedência)).
> **Opt-in consciente:** o onboarding (`install.ps1`) **pergunta** se deseja aplicá-la
> (default: não) e, ao aceitar, **exige admin** (eleva via UAC). Este diretório é o **template**;
> a ativação manual (abaixo) continua válida para quem prefere não passar pelo onboarding.

## O que ela faz

[`managed-settings.json`](managed-settings.json) nega, de forma determinística (o modelo
**não** consegue contornar), um conjunto enxuto de ações perigosas — endurece as regras
invioláveis do `~/.claude/CLAUDE.md` pessoal:

| Regra negada | Por quê |
|--------------|---------|
| `git push --force *` / `git push -f *` / `git push --force-with-lease*` | rewrite de histórico compartilhado (regra inviolável) — as 3 formas de force-push |
| `git reset --hard *` | descarte destrutivo de estado |
| `PowerShell(git push --force *)` e as outras 3 regras git acima, espelhadas | a tool `PowerShell` do Claude Code tem regras próprias: um deny de `Bash(...)` não a alcança. E, no Windows com Git Bash, **qualquer** deny de `Bash(...)` desliga a tool `PowerShell` na sessão, sem aviso, se não houver regra `PowerShell(...)` nem `CLAUDE_CODE_USE_POWERSHELL_TOOL=1` (doc *tools-reference*, conferida em 2026-10-09). O espelho mantém a tool ligada **e** negada no mesmo ponto. O wipe catastrófico (`rm -rf /`…) não tem espelho: é sintaxe POSIX, e o `Remove-Item -Recurse` de alvo arriscado pede confirmação pelo `destructive-guard` |
| `rm -rf /` · `/*` · `~` · `~/*` · `$HOME*` (e `rm -fr …`) | **wipe catastrófico** — formas que **nunca** são legítimas (≠ `rm -rf ./build`, que segue liberado) |
| `dd *of=/dev/*` | sobrescrita de disco/dispositivo |
| `mkfs*` | formatação de sistema de arquivos |
| `*:|:&*` (assinatura `:\|:&` do fork bomb) | fork bomb — casa a forma canônica `:(){ :\|:& };:` sem parênteses vazios (que o parser do Claude rejeita) |
| `Read(./.env)`, `./.env.*` | **scrub de segredos** — impede a ferramenta Read abrir o `.env` |
| `Read(./secrets/**)` | **scrub de segredos** — impede Read sob `secrets/` |

> **Escopo conservador e o porquê de cada nível.** A policy nega só (a) destruição de histórico
> git, (b) **wipe catastrófico** (formas nunca-legítimas — não pega `rm -rf ./build`, que é
> workflow normal), e (c) leitura de segredos via Read. Tudo o mais (`rm` comum, `curl`/`wget`,
> outras chaves) segue o **fluxo de permissão padrão**.
> Os `deny` casam por **padrão/prefixo** (ex.: `--force *` não pega `--force-with-lease`; `rm -fr`
> precisa de entrada própria): são trava de governança para os **casos óbvios**, **não** uma
> sandbox nem um guard tokenizado. O bloqueio **robusto** do destrutivo (que normaliza o comando,
> pegando variantes de ordem/flag) é trabalho de um **hook `PreToolUse`** — ver nota sobre `auto` abaixo.

## Postura `auto` e o que a protege

Com `permissions.defaultMode: "auto"` (escolha do `~/.claude/settings.json` pessoal — **menos
prompts**; desde a v2.1.283 o `auto` é também o modo inicial built-in das sessões interativas), um
**classificador** revisa cada comando antes de rodar e bloqueia por padrão o que escala além do
pedido (lista em *"What the classifier blocks by default"*, na doc de permission modes). A própria
doc avisa que o auto mode *"does not guarantee safety"*: o classificador é um modelo, não uma regra.
**O que protege de forma determinística:**

- **Hooks `PreToolUse` sobrevivem ao `auto`** e a decisão `ask`/`deny` deles **sobrepõe** a
  auto-aprovação: `secret-guard` (segredo em commit/push e `cat .env` → `ask`) e `destructive-guard`
  (`rm -rf`/git destrutivo → `ask`) continuam valendo. A rede de segurança do projeto é
  **hook-based**, não prompt-based.
- **Esta managed policy** nega o catastrófico/segredos de forma inviolável.

> **Risco residual (consciente):** o classificador do `auto` é probabilístico. Ele cobre o
> catastrófico comum, mas não garante; os hooks abaixo são a camada que não depende de julgamento.
>
> **Atualização (J5, 2026-06-10):** o **destrutivo não-git** (`rm -rf` de alvo absoluto/home/var/
> glob, flags reordenadas, `chmod -R 777`, `curl|sh`) — que caía no buraco entre o `auto` e o
> "deny só pega os catastróficos óbvios" — agora é coberto pelo hook **`destructive-guard`**
> (`templates/global-claude/hooks/`). O gate de viabilidade escolheu a postura **`ask`** (não `deny`):
> o hook **tokeniza/normaliza** o comando e pede **confirmação** nas variantes que escapam ao
> `deny`-por-prefixo desta policy — **sem** o risco de falso-positivo **sem escape** de um `deny` em
> hook (ele bloquearia `rm -rf ./build` legítimo). Defesa em camadas: a policy `deny` o catastrófico
> óbvio; o hook `ask` as variantes. O `deny` inviolável continua **só** aqui.
>
> **Atualização (J6, 2026-06-14):** o `destructive-guard` ganhou cobertura **universal** do que
> ainda escapava: **git destrutivo de working-tree/stash** (`git clean -f`, `git restore .`,
> `git checkout -- .`, `git stash drop`/`clear`) — que apaga trabalho **não-commitado** de forma
> irreversível — agora pede **`ask`** (o hook tokeniza o subcomando+flags; `git checkout <branch>`,
> `git restore --staged`, `git stash pop`, `git clean -n` e demais rotinas **passam** sem atrito). O
> alvo `../` num `rm -rf` (que **sobe** da cwd) passou a contar como arriscado. E o **`--force-with-lease`**
> (3ª forma de force-push) entrou no `deny` **desta policy** (acima), junto de `--force`/`-f`. As CLIs
> de dados/cloud (`DROP`/`TRUNCATE`, `aws s3 rm`, `terraform destroy`) ficaram **fora** (adiadas no
> gate: falso-positivo no dev-loop + custo de manter lista).

> **Leitura de segredo via Bash.** O deny de `Read(.env)` já vale para `cat`, `head`, `tail`, `sed`,
> `tee` e redirecionamentos (doc de permissions), mas não para leitura indireta (`grep -r`, script) nem
> para leitores que o harness não reconhece (`type`, `Get-Content`, `less`). Esses ficam com o hook
> **`secret-guard.ps1`** (em `templates/global-claude/hooks/`), em modo `ask`, inclusive sem esta
> policy. Defesa em camadas: a managed policy nega o `Read`; o hook pede confirmação no resto; e o git
> **pre-commit** do scaffold bloqueia o segredo no commit. As três compartilham a mesma lib de
> detecção (`hooks/lib/secret-patterns.ps1`).

## Como ativar (Windows)

**Via onboarding (recomendado):** rode `onboarding/install.ps1` — ao chegar no passo
*"Managed policy"* ele pergunta **"Aplicar managed policy? (exige admin) (altamente
recomendado)"**. Aceitando, eleva via UAC e copia o `managed-settings.json` para o caminho
de sistema (idempotente: pula se já estiver idêntico; faz backup se diferir).

**Manualmente** (sem onboarding), a managed policy vive num caminho de **sistema** (exige
admin). Para aplicar:

```powershell
# Como Administrador. Caminho oficial a partir do Claude Code v2.1.75+:
$dir = 'C:\Program Files\ClaudeCode'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item .\templates\managed-policy\managed-settings.json (Join-Path $dir 'managed-settings.json')
```

> **macOS/Linux:** o arquivo equivalente fica em `/Library/Application Support/ClaudeCode/`
> (macOS) ou `/etc/claude-code/` (Linux) — mesma estrutura JSON; o `install.sh` o copia via `sudo`
> quando você aceita. Há também o drop-in `managed-settings.d/` para fragmentos por equipe.

Reinicie o Claude Code. Para validar: peça um comando que a policy nega de fato, como
`git push --force origin teste` num repositório de teste — deve ser bloqueado pela permissão, não
pelo modelo. (`rm -rf` num diretório qualquer **não** serve: a policy só nega `/`, `~` e `$HOME`.)

## Endurecer ainda mais (opcional)

Para um ambiente travado, adicione ao JSON:

- `"allowManagedPermissionRulesOnly": true` — **só** as regras desta policy valem; usuário/
  projeto não podem definir `allow`/`ask`/`deny`.

## Limitação conhecida — guard de push direto na `main`

Bloquear **commit/push direto na `main`** de forma robusta depende do **branch atual** (um
arg dinâmico), que as regras `deny` (casamento por prefixo) não capturam bem. As regras acima
cobrem o `--force`; o veto a "push na main em qualquer forma" é melhor servido por um **hook
`PreToolUse`** que lê `git branch --show-current` — candidato registrado no spike do **J2**
(`features/PLANOS.MD`), a implementar se/quando houver necessidade real.

## Proveniência

Schema e caminho verificados via context7 (`/websites/code_claude`, code.claude.com),
checado **2026-06-02** (regra [`docs-first`](../project-scaffold/.claude/rules/docs-first.md)).
