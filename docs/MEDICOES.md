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

Há uma série de comparações entre projetos feitos com o fluxo e projetos feitos sem ele
([abaixo](#fluxo-contra-sem-fluxo-piloto-de-9-tarefas)). Em tarefas pequenas e médias, **nada separou os braços**;
no cenário de legado com armadilhas, **o fluxo não superou a pasta crua** (veja a última seção da série).
O resto do que está aqui mede custo de contexto, obediência às regras e se cada peça dispara quando
deveria. Essas coisas são pré-condição de um resultado melhor, mas não provam que ele acontece.

## Fluxo contra sem fluxo: piloto de 9 tarefas

| | Com fluxo (`mvp`) | Sem fluxo (pasta vazia) |
|---|---|---|
| Testes de aceitação ocultos | **142/142** | **142/142** |
| Rodadas de correção até verde | 0 | 0 |
| Custo das 18 sessões | US$ 0,1290 | US$ 0,0841 (**+53%** no braço com fluxo) |
| Turnos | 77 | 81 |

- **Como:** 9 tarefas pareadas, cada uma nos dois braços, 1 sessão por célula. Mesmo prompt nos dois
  (nunca cita o fluxo), `claude -p --model haiku --setting-sources project`. O braço com fluxo é um
  projeto criado com `onboarding/new-project.ps1 <pasta> -Profile mvp`; o outro é uma pasta vazia.
  Funções puras em Python, uma CLI multi-arquivo e regras de borda. Duas alavancas de dificuldade:
  tarefa maior e ambígua (2 tarefas) e `--effort low` (2 tarefas). Quem julga o defeito é o `pytest`
  com testes escritos antes e não vistos pelo gerador, validados contra uma implementação de referência.
- **Quando:** 2026-11-09, v1.0.19, Claude Code 2.1.321. Custo, turnos e tempo vêm do JSON de cada sessão.
- **O que isso diz:** nada sobre qualidade. O Haiku acertou tudo nos dois braços, então o teste não
  discrimina e a pergunta "o fluxo evita defeito?" segue **sem resposta**. O que se sustenta é o custo:
  o contexto fixo do fluxo encareceu as sessões em cerca de metade neste molde.
- **Limite:** n=1 por célula, variância não medida. Tarefas pequenas e autocontidas, que são onde o
  fluxo menos ajuda. O `~/.claude/CLAUDE.md` pessoal carregou nos dois braços. O relatório, os
  testes ocultos e o script não vêm no template.

### Três sessões sem memória: o código bastou

| Cadeia (3 sessões independentes) | Testes ocultos acumulados S1 / S2 / S3 | Custo total |
|---|---|---|
| Com fluxo, réplica 1 | 19/19 · 39/39 · 51/51 | US$ 0,0729 |
| Com fluxo, réplica 2 | 19/19 · 39/39 · 51/51 | US$ 0,1389 |
| Sem fluxo, réplica 1 | 19/19 · 39/39 · 51/51 | US$ 0,0727 |
| Sem fluxo, réplica 2 | 19/19 · 39/39 · 51/51 | US$ 0,0746 |

- **Como:** um pacote de estoque (persistência JSON, reservas, backorder, `desfazer` com estorno) em 3
  sessões `claude -p --model haiku`, cada uma nova e sem `--continue`. A sessão 2 traz uma mudança de
  negócio que contradiz uma regra da sessão 1; a 3 cruza histórico, reservas, backorder e persistência.
  Depois de cada sessão roda-se o acumulado dos testes ocultos, sem correção entre elas. Duas réplicas
  por braço.
- **Quando:** 2026-11-09, v1.0.19, Claude Code 2.1.321.
- **O que isso diz:** o modelo releu o código a cada sessão e não regrediu nada, com ou sem fluxo. Nos
  projetos do braço com fluxo, `BACKLOG.md`, `docs/_index.md` e `inbox/` ficaram **iguais ao template**:
  o scaffold não foi usado como memória. A diferença de custo (+44% com fluxo) é do tamanho da variância
  entre as duas réplicas do mesmo braço, então não vale como número.
- **Limite:** ~400 linhas de código no fim. Não cobre decisão cujo motivo só existe numa conversa,
  base grande ou legado.

### Legado com armadilhas: o scaffold não inicializado perdeu

| Cadeia (3 sessões independentes, 13 armadilhas) | Testes ocultos acumulados S1 / S2 / S3 |
|---|---|
| Sem fluxo, 3 réplicas | 8/8 · 23/23 · 32/32 (as três) |
| Com fluxo (`mvp` não inicializado), réplica 1 | 8/8 · 17/23 · 22/32 |
| Com fluxo, réplica 2 | 8/8 · 21/23 · 19/32 (sessão 3 não entregou) |
| Com fluxo, réplica 3 | 8/8 · 16/23 · 21/32 |

- **Como:** um faturador legado de 347 linhas, com 13 armadilhas contra o senso geral (encoding do ERP,
  half-up, corte às 18h de Brasília, centavos em formato novo, migração do formato antigo, cliente bloqueado,
  reversão de regra com cascata, entre outras). O cenário e os testes ocultos foram projetados pelo Opus 5.5 e
  validados antes: referência 32/32, solução ingênua reprova 18. Haiku gera; 3 sessões `claude -p` sem memória;
  4 decisões de negócio ditas uma única vez na sessão 1.
- **Quando:** 2026-11-09, v1.0.19, Claude Code 2.1.321. Custo igual: US$ 0,314 com fluxo e 0,310 sem.
- **O que isso diz:** é a única medição em que os dois braços se separaram, e o scaffold perdeu. As decisões
  só sobrevivem se a sessão 1 as registra e a 2 as lê; sem fluxo, os 3 agentes registraram (README ou módulo)
  e os 3 passaram. Com fluxo, só 1 de 3 registrou, e ele não leu o próprio registro na sessão seguinte. Uma
  sessão parou sem entregar porque o projeto estava em `status: template` e o `AGENTS.md` exige `/setup`.
- **Limite:** o braço "com fluxo" é o scaffold **entregue e não inicializado**, sem `/setup` nem as fases
  rodadas. 0/3 contra 3/3 dá p = 0,05 unilateral (Fisher). A rodada seguinte isolou a causa (abaixo).

### Scaffold inicializado e fluxo em uso: sem ganho medido

| Braço (3 cadeias de 3 sessões cada, mesmo cenário) | Cadeias perfeitas (32/32) | Custo médio por cadeia |
|---|---|---|
| Pasta crua | 3/3 | US$ 0,103 |
| Scaffold não inicializado (`status: template`) | 0/3 | US$ 0,105 |
| Scaffold inicializado (`project-context.md` ativo) | 3/3 | US$ 0,122 (+18%) |
| Inicializado + `/dev` na entrada e `/document` ao fechar a sessão | 2/3 | US$ 0,290 (2,8×) |

- **Como:** o mesmo faturador legado de 13 armadilhas, Haiku, 3 sessões `claude -p` sem memória. Cada braço novo
  muda uma coisa em relação ao anterior. O `project-context.md` ativo foi escrito no formato do `/setup`, com o
  comando de verificação rodado antes (11 testes). `/dev` e `/document` são os comandos do próprio produto.
- **Quando:** 2026-11-09, v1.0.19, Claude Code 2.1.321.
- **O que isso diz:** (1) o scaffold **não inicializado perde** da pasta crua, e é a inicialização que corrige;
  (2) **nenhum braço superou a pasta crua em qualidade**, e o fluxo em uso custou 2,8× e teve 1 cadeia
  reprovada, mesmo depois de gravar e ler um documento de decisões correto. Neste cenário e com este modelo,
  o fluxo **não deu ganho de corretude**.
- **Limites:** a pasta crua já está em 3/3, então o teste não tem folga para mostrar ganho, só perda. n=3 por
  braço (2/3 contra 3/3 não se distingue), um modelo, cenário sintético, só testes como juiz. Não mede
  rastreabilidade, ADRs nem onboarding, que o fluxo produz. O ciclo SDD de 5 fases, que exige aprovação humana
  entre fases, não foi exercitado: o braço "fluxo" usou o Dev Loop.

Repetido com `--effort low` (menos raciocínio do gerador), para dar folga à pasta crua:

| Braço (3 cadeias, `--effort low`) | Cadeias perfeitas | Testes ocultos no fim (de 96) | Custo total |
|---|---|---|---|
| Pasta crua | 1/3 | 84 | US$ 0,229 |
| Scaffold inicializado | 2/3 | 95 | US$ 0,328 (+43%) |
| Inicializado + `/dev` + `/document` | 1/3 | 80 | US$ 0,624 (2,7×) |

- **O que isso diz:** com folga, o scaffold inicializado fica nominalmente na frente (95 contra 84 testes), mas
  com 2/3 contra 1/3 cadeias perfeitas isso não se distingue de paridade (p = 1,0). O fluxo em uso não melhora
  e custa 2,7×. As cadeias que falham perdem quase sempre a mesma decisão (dinheiro em centavos em formato novo)
  e a migração do legado, e **criar um módulo ou registro na sessão 1 não protegeu**: três cadeias que o criaram
  falharam, duas que não criaram passaram.
- **Limite:** n=3 por braço, um modelo, um cenário. Nenhum resultado desta série mostra ganho de corretude do
  fluxo; nenhum prova que ele não exista fora deste cenário.

### Cadeia longa de 6 sessões: os três braços quebram

Cenário `locadora` (Opus 5.5 projetou: 23 armadilhas, 3 reversões de regra, formato persistido v1→v2→v3), Haiku
com `--effort low`, 6 sessões sem memória, 3 réplicas por braço. Relatório completo em
`.claude/sdd/reports/TESE_AB_PAREADO_2026-11-09.md`.

| Braço | Cadeias perfeitas | Falhas ao fim (de 60) | Custo médio/cadeia |
|-------|-------------------|-----------------------|--------------------|
| Pasta crua | 0/3 | 19, 19, 15 | US$ 0,216 |
| Scaffold inicializado | 0/3 | 9, 19, 19 | US$ 0,288 (+33%) |
| Inicializado + `/dev` + `/document` | 0/3 | 22, 9, 21 | US$ 0,723 (3,3×; 62% é `/document`) |

- **O que isso diz:** cadeia longa com decisões que só mordem sessões depois derruba todos os braços; o
  fluxo não trouxe ganho de corretude medido. **Ressalva da auditoria:** em headless o `/document` quase nunca gravou
  (exige `AskUserQuestion`, e a rule manda ficar em silêncio com KB não treinada), então o braço F não mediu o fluxo
  em uso e ~60% do seu custo é `/document` sem entrega. Só 1 de 9 cadeias registrou a regra do ISS, e foi a que a respeitou.
- **Limite:** n=3 por braço, um modelo, um cenário sintético, juiz só de testes.

### Rodada 8: o `/document` passou a gravar, e o resultado não mudou

Mesmo cenário `locadora`, mesmo juiz e script da cadeia longa, só o braço com fluxo em uso (3 réplicas, `--effort low`, Haiku, perfil `mvp`), depois que o `/document` passou a gravar em sessão não interativa, e três testes de acompanhamento.

| | Rodada 7 (`/document` sem gravar) | Rodada 8 (`/document` gravando) |
|---|---|---|
| Falhas ao fim (de 60) | 22, 9, 21 | 15, 15, 12 |
| Cadeias perfeitas | 0/3 | 0/3 |
| Custo médio/cadeia | US$ 0,723 | US$ 0,926 (+28%; US$ 0,606 só de `/document`) |

- **O que isso diz:** a regra do ISS e a do código de cliente chegaram a `docs/` na sessão 2 em 3/3 cadeias (antes 1/3), então o braço agora mede o fluxo em uso. Ainda assim, sem ganho de corretude distinguível. Registrar a decisão não faz a sessão seguinte usá-la.
- **Controle no mesmo dia (2026-11-11):** pasta crua (B) e scaffold inicializado (I) rodadas de novo, 3 réplicas cada, mesmo cenário, juiz e `--effort low`, Haiku.

| Braço | Cadeias perfeitas | Falhas ao fim da S6 (de 60) | Custo médio/cadeia |
|---|---|---|---|
| Pasta crua | 0/3 | 15, 18 e 1 cadeia sem medida (B3) | US$ 0,215 |
| Scaffold inicializado | 0/3 | 9, 18, 17 | US$ 0,256 (+19%) |

  B3 não entregou o módulo `locadora.receita` na S3, então os testes ocultos das sessões 3 a 6 nem coletaram (4 erros de importação) e a cadeia fica sem contagem de falhas. Excluída B3, B tem média de 16,5 falhas e I de 14,7: não se distinguem, como na rodada 7. O custo extra do scaffold (+19%) fica no que já foi medido (+18% a +33%).
- **Método:** `drive_c8.sh` (3 ondas de `run_c4.sh B|I`, `EFFORT=low`, `TAG=L8`) sobre a `main` com #192 e #197; falhas do `pytest` nos testes ocultos cumulativos; custo e turnos somados de `total_cost_usd`/`num_turns` dos JSON de cada sessão (nenhuma com `is_error`).
- **Limite:** n=3 por braço, um modelo, um cenário. O F não foi rodado de novo neste lote, então B e I vêm de outra hora que o F da rodada 8.
- **Teste A: `/dev` lendo `docs/` antes de editar (2026-11-11).** Só o passo 2 do `/dev` mudou: além do `project-context.md`, ler o índice e os registros de decisões e regras de `docs/` antes de editar (o registro vence a suposição). Braço F no `mvp`, 3 réplicas, mesmo cenário e juiz. Falhas ao fim da S6 (de 60): **sem contagem** (F1: a S3 não criou o módulo e os testes das sessões 3 a 6 não coletaram), **9** e **5**; custo médio US$ 1,15 (+24% sobre os US$ 0,926 da rodada 8). Os dois números medidos são menores que os 15, 15 e 12 da rodada 8 e que os 22, 9 e 21 da rodada 7, mas com uma réplica sem contagem e n=3 isso **não separa do ruído**. Não verificamos nos transcripts se foi o `/dev` que leu os registros. A mudança não foi para a `main`.
- **Teste B: perfil `full` (2026-11-11).** Mesmo cenário e juiz, `new-project.ps1 -Profile full` (14 agentes, 30 commands, 12 rules, contra 7 rules do `mvp`), 3 réplicas por braço, `dev.md` original.

| Braço no `full` | Cadeias perfeitas | Falhas ao fim da S6 (de 60) | Custo médio/cadeia |
|---|---|---|---|
| Inicializado (I) | 0/3 | 21, 20, 6 | US$ 0,458 (+79% sobre o I do `mvp`, US$ 0,256) |
| Inicializado + `/dev` + `/document` (F) | 0/3 | 8, 9, 18 | US$ 1,306 (+41% sobre o F do `mvp`, US$ 0,926) |

  O perfil `full` custa mais e não corrigiu mais: a média de falhas do I fica em 15,7 (contra 14,7 do `mvp` no controle) e a do F em 11,7. Nenhuma diferença se distingue com n=3 e variância de 6 a 21 dentro do mesmo braço.
- **Método dos testes A e B:** `run_c4.sh` com `TAG=L9` (A) e `TAG=L10` + `PROFILE=full` (B), `EFFORT=low`, Haiku; falhas do `pytest` nos testes ocultos cumulativos; custo e turnos somados de `total_cost_usd`/`num_turns` dos JSON de cada sessão (nenhuma com `is_error`).
- **Teste D: tarefas reais num projeto Node privado de terceiros (2026-11-12).** Reaplicação de 3 commits reais com teste (Finanças valida valor/data, MCP fecha lacunas, MCP baixa links): cada tarefa parte do estado anterior ao commit e recebe como pedido os itens da mensagem do commit; o juiz é o teste do commit, nunca visto. Pasta crua, scaffold `mvp` inicializado e scaffold + `/dev`, 2 réplicas por célula, Haiku `--effort low`, 18 sessões. **Resultado: 0/18 passam nos testes ocultos, nos três braços.** Smoke e `node --check` limpos em todas. Custo médio por sessão: B US$ 0,070, I US$ 0,104 (+48%), F US$ 0,070.
  - **O que isso diz:** nada sobre qualidade. As falhas são sempre a mesma verificação por tarefa, e ela exige contrato que o pedido não escreve (mensagem de erro de data, um helper `sendJson` injetado pelo teste novo, formatos aceitos). O teste mede especificação incompleta, não implementação.
  - **Limite:** 3 tarefas de backend Node, n=2 por célula, um modelo, repositório privado de terceiros, sem nome aqui (cópias descartáveis, nada enviado a ele). Um juiz por comportamento, ou pedidos que carreguem o contrato, ainda não foram feitos.
- **Correção de método (2026-11-12): conectores da conta inflam o custo do scaffold em `claude -p`.** As sessões acima rodaram com os conectores do claude.ai da conta de quem mede (Gmail, Calendar, Docs…). Esses conectores só entram no prompt se já estiverem `connected` quando a primeira chamada sai. O hook `SessionStart` do scaffold roda `pwsh` (centenas de ms), o que dá tempo de eles conectarem; a pasta crua não tem hook e sai antes, com os conectores ainda `pending`. Resultado: os braços com scaffold carregavam ~2.900 tokens de ferramentas de conector que o braço cru não carregava. Medido com uma sessão de um turno (Haiku, `--setting-sources project`): o mesmo texto de hook passado por `sh` custa +133 tokens sobre nenhum hook; uma saída trivial passada por `pwsh` custa +2.909, e o `init` da sessão lista 50 ferramentas `mcp__*` contra 0. Com `ENABLE_CLAUDEAI_MCP_SERVERS=false` o efeito some (35.107 contra 37.967). **Os custos relativos desta série (+18% a +79% do scaffold) estão superestimados por esse artefato**, em ordem de ~15% da diferença (ESTIMADO, não recalculei cada rodada). O número limpo do contexto fixo, com os conectores desligados e a mesma sonda: pasta crua 18.846 tokens, `mvp` 35.128 (**+16.282**), `full` 41.641 (**+22.795**). As conclusões sobre corretude não mudam, porque o artefato é só de custo. Medições futuras de custo com `claude -p` devem exportar `ENABLE_CLAUDEAI_MCP_SERVERS=false` nos dois braços.
- **Conclusão da série:** em corretude, nenhum braço com fluxo superou a pasta crua neste molde; o custo subiu de +18% a 3,3×. Não medimos tarefas reais, rastreabilidade das decisões nem o ciclo SDD completo.

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
