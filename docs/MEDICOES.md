# Medições / Measurements

> O que o Native-SDD já mediu sobre si mesmo, com o comando ou o método de cada número, a data e a
> versão. Os resultados ruins entram junto com os bons, porque foi por eles que o produto mudou.
>
> *What Native-SDD has measured about itself, each number with the command or method behind it.*

**Como ler.** As amostras são pequenas: 3 sessões por braço é o padrão aqui. Elas servem para ver se
um comportamento acontece, não para estimar uma taxa. O modelo das sessões vem escrito em cada linha,
e o resultado pode mudar com outro modelo ou outra versão do Claude Code. Alguns números saíram de
ferramentas internas que não vêm no template. Quando é o caso, a linha diz isso.

## O que dá para conferir sem confiar no autor

| O quê | Como você confere | Precisa de |
|---|---|---|
| O produto instala e cria projetos que passam no `/check`, em Windows e Linux | os runs públicos do [`smoke.yml`](https://github.com/Phenrique-DataDev/Native-sdd/actions/workflows/smoke.yml), um por release | só o navegador |
| Qual versão o bootstrap instala | rode o bootstrap com `-Check` (`--check`): ele imprime `release: vX.Y.Z` e não muda a sua configuração (só guarda o código baixado em `~/.claude/.native-sdd-src`) | PowerShell ou bash |
| O custo de contexto por perfil | os dois comandos da seção [Custo de contexto](#custo-de-contexto-por-perfil), que vêm no template | PowerShell 7 |
| Rules com `paths:`, a trilha de redesign e as skills | o método de cada seção, em sessões `claude -p` num projeto novo | Claude Code |
| O scaffold no Codex | **não dá:** a ferramenta da matriz é interna e não vem no template | — |
| O scaffold no Copilot e no Antigravity | o método da [seção](#o-scaffold-no-github-copilot-e-no-antigravity): um projeto `mvp` novo e os três pedidos | a CLI de cada um |

As medições com `claude -p` dependem do modelo e da versão do Claude Code, que estão escritos em cada
seção. Com outra combinação, o resultado pode mudar.

## O que ainda não está medido

Nenhuma medição compara projetos feitos com o fluxo contra projetos feitos sem ele. O que está aqui
mede custo de contexto, obediência às regras e se cada peça dispara quando deveria. Essas coisas são
pré-condição de um resultado melhor, mas não provam que ele acontece.

## Custo de contexto por perfil

| | `mvp` (default) | `full` |
|---|---|---|
| Contexto fixo por sessão, só o que o projeto entrega | **~15.002 tok** | **~21.107 tok** |

- **Como:** dois projetos novos criados com `onboarding/new-project.ps1 <pasta> -Profile mvp` e
  `-Profile full`, e depois `pwsh tools/rules-budget.ps1 -Root <pasta>` em cada um. O número é a
  parcela "produto" da saída. O resto vem do `~/.claude` de quem mede e não entra.
- **Quando:** 2026-10-18, v1.0.2. Quem quiser conferir roda os mesmos dois comandos, porque os dois
  vêm no template.
- **Escopo:** é estimativa por caracteres (2,2 chars por token, calibrada contra o `/context`), não a
  contagem do modelo. O overhead relativo cai conforme a sessão cresce. A tabela por tamanho de
  sessão está no [`USO.md`](USO.md), e ali a projeção vem marcada como projeção.

## Por que o `mvp` virou o default

Auditoria externa de 2026-09-19 (v0.11.0), com 45 sessões headless de `claude -p`:

| Medição | Resultado |
|---|---|
| 9 tarefas pareadas, `full` × `mvp` | o `full` custou **+32,9%**, com obediência **idêntica** às três regras do núcleo (e menos turnos, 26 contra 32) |
| Fan-out de subagentes | **+40% por subagente** no `full`, porque 73% do bloco fixo se propaga a cada um |
| Uma tarefa pequena | **3,6×** o custo no `full`, para entregável equivalente |

- **Limite:** o relatório da auditoria e os comandos dela não vêm no template. Os números estão
  registrados aqui e no [`USO.md`](USO.md).

## A trilha de redesign de tela no `/dev`

| Braço | Sessões que abriram o `/dev` antes de editar |
|---|---|
| Só a linha de gatilho na tabela do `workflow-sdd.md` | **0/3** (as 3 editaram a tela sem aprovação) |
| Com um parágrafo imperativo, ~60 palavras de contexto fixo | **3/3** (as 3 fizeram o brief e pararam antes de editar) |

- **Como:** `claude -p --model sonnet` num projeto `mvp` novo, com o pedido "refaz a tela do
  index.html, ela está feia e confusa".
- **Quando:** 2026-10-17, v1.0.1. A trilha depois rodou de ponta a ponta num redesign de teste, e o
  que falhou no caminho virou 10 correções na mesma versão.

## Rules que só carregam quando o arquivo é lido

| Situação | Sentinela da rule presente na sessão |
|---|---|
| Sessão que não lê nenhum arquivo casado pelo `paths:` | **0/2** |
| Sessão depois de um `Read` casado | **3/3** |

- **Como:** uma rule com `paths:` e uma sentinela no texto, em sessões `claude -p`, Claude Code CLI
  2.1.282.
- **Quando:** 2026-09-24, v0.11.3. Foi isso que permitiu tirar a `docs-first` do contexto fixo
  (~1.344 tok no `full`).

## Skills que dependiam do julgamento do modelo

| Skill | Acionada quando deveria |
|---|---|
| `page-to-markdown` | **1/30** |
| `decision-preview` | **3/30** |
| Falsos positivos | **3 em 60** |

- **Como:** 30 execuções por skill, com pedidos que deveriam acioná-la. No `page-to-markdown`,
  o modelo resolveu nativo, com `ToolSearch → WebFetch → Write` em 3/3.
- **Quando:** 2026-08-20, v0.10.12. O resultado reprovou a correção óbvia (reescrever a
  `description`), e as duas passaram a ter caminhos determinísticos.

## O scaffold fora do Claude Code (Codex)

| Caso | Resultado |
|---|---|
| O guard bloqueia, as skills exportadas chegam ao prompt, o modelo responde as fases do `AGENTS.md` | **3/3 PASS** com `gpt-5.6-terra` |
| O mesmo caso do guard com o arquivo anterior à correção | **FAIL**, que é o controle |

- **Como:** e2e ao vivo num projeto descartável, com uma ferramenta interna de matriz cross-model
  que não vem no template.
- **Quando:** 2026-10-10, v0.11.39.

## O scaffold no GitHub Copilot e no Antigravity

| Caso | Copilot CLI 1.0.91 (`gpt-5.6-luna`) | Antigravity CLI 1.4.2 (`gemini-3.8-flash-high`) |
|---|---|---|
| As fases saem na ordem do `AGENTS.md`, com o `/dev` | **PASS** | **PASS** |
| As skills aparecem | **PASS**: 32, direto de `.claude/` | **PASS**: 32 depois do `Export-CodexHarness` (não distingue se carregou ou leu a pasta) |
| O guard bloqueia `Remove-Item -Recurse -Force` numa pasta descartável | **FAIL**: quem bloqueou foi um hook do projeto que quebrou, e no Windows ele bloqueava também toda escrita (corrigido no mesmo dia: os hooks ganharam o campo `powershell`, e o log do Copilot passou de 11 erros de hook para 0) | **FAIL**: a pasta foi apagada, porque não há hook (o guard veio depois, ver abaixo) |

- **Como:** os dois agentes em panes do Herdr, sem pedir permissão por ferramenta, cada um num projeto
  `mvp` novo e descartável. O caso do guard foi conferido pelo disco (a pasta existe ou não), e a causa
  da falha do Copilot pelo log dele em `~/.copilot/logs/`.
- **Quando:** 2026-10-18, v1.0.6, Windows. Linux e macOS não foram medidos.

**Depois do guard pelo instalador** (mesmo dia, Copilot 1.0.98 e agy 1.4.2), com o guard gravado na
config de usuário de cada ferramenta e um projeto sem hook nenhum:

| Caso | Copilot CLI | Antigravity CLI |
|---|---|---|
| `Remove-Item -Recurse -Force ../alvo` | **PASS**: "Hook permission request" com a razão do guard, mesmo com `--allow-all-tools`; recusado, a pasta ficou e o modelo recebeu a razão | **FAIL esperado**: o adapter respondeu `force_ask` com a razão, mas este agy roda com `dangerouslySkipPermissions` nas settings e aprovou sozinho; a pasta foi apagada |
| Comando seguro (`Get-ChildItem`) | roda sem pergunta | roda sem pergunta |

- **Como:** o Copilot num pane do Herdr, com o arquivo que o instalador grava; o agy por `agy -p` com
  um wrapper que registra o que o adapter devolve. Sondas antes da implementação: no agy, `ask` e
  `force_ask` foram aprovados sozinhos com as permissões puladas (headless e TUI), e só `deny` barrou.
- **Não medido:** o `force_ask` com as permissões normais do agy, e as duas ferramentas fora do Windows.

## O bootstrap não fecha mais o terminal

| Modo | Resultado com download que falha (repositório inexistente) |
|---|---|
| `pwsh -NoProfile -Command "… \| iex"` (automação) | o processo sai com **código 1** |
| Sessão aberta com `-NoExit` (o terminal de quem cola) | a sessão continua, e o `$LASTEXITCODE` fica em **1** |

- **Como:** o `bootstrap.ps1` com o repositório trocado por um inexistente, rodado nos dois modos.
  A detecção do modo tem 11 casos Pester e um teste de paridade entre a cópia inline e a da lib.
- **Quando:** 2026-10-18, v1.0.3.
