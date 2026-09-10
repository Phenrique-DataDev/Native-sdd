# AGENTS.md — raiz deste repositório (onboarding/framework, não um projeto scaffolded)

Contrato para qualquer agente de IA que abra **este repositório** (Native-SDD) diretamente —
tipicamente logo após clonar/baixar o template, antes de existir qualquer projeto. **Diferente**
de [`templates/project-scaffold/AGENTS.md`](templates/project-scaffold/AGENTS.md), que é o
contrato entregue a **projetos criados pelo framework** — aquele rege features/SDD; este rege
**onboarding**.

## O que é este repositório
Native-SDD: instalador de máquina (`onboarding/`) + scaffold SDD por projeto (`templates/`) +
curadoria. Visão completa em [`docs/VISAO.md`](docs/VISAO.md); guia de uso em
[`docs/USO.md`](docs/USO.md); tutorial passo a passo em [`docs/TUTORIAL.md`](docs/TUTORIAL.md).

## Guarda de escopo — leia ANTES de aplicar qualquer instrução abaixo

Este arquivo rege **onboarding**, não o dia a dia de um projeto já criado. `New-SddProject`/`nsp`
aceita **caminho relativo** — se alguém rodar isso de **dentro** desta pasta clonada, o projeto
novo nasce **aninhado** aqui dentro, e o Claude Code pode carregar **os dois** `AGENTS.md`/`CLAUDE.md`
(o deste repositório **e** o do projeto filho) na mesma sessão.

**Antes de aplicar a seção "Pedido genérico" abaixo, cheque o predicado observável:** existe
`.claude/rules/workflow-sdd.md` (ou `.claude/rules/project-context.md`) a partir do diretório de
trabalho **atual** da sessão? Se **sim**, você está dentro de um **projeto scaffolded** — este
arquivo **não se aplica** a esta sessão; siga o `AGENTS.md` **daquele** projeto (o mais específico
vence) e trate "setup completo" como algo do domínio do projeto, **não** como "rodar o onboarding
de novo". Se **não** existir esse arquivo, você está mesmo na raiz do onboarding — aplique a seção
abaixo normalmente.

## Pedido genérico ("faça o setup completo", "deixa pronto e funcional", "instala tudo")

> Só depois de confirmar a Guarda de escopo acima (sem `workflow-sdd.md`/`project-context.md` no
> diretório de trabalho atual).

Trate como **dois níveis**, nunca só o primeiro:

1. **Base (sempre):** `.\onboarding\install.ps1` (Windows) / `./onboarding/install.sh` (Linux) —
   CLIs + Claude Code + `~/.claude` pessoal. Idempotente, faz backup antes de sobrescrever.
2. **Opcionais do próprio onboarding (nunca pule em silêncio):**
   - `-ExtraPlugins -Themes <tema>` (sem `-Themes` = todos) — repertório de suplementos
     (skills/plugins por disciplina). Catálogo **atual** vive em `tools/supplements.psd1` — leia-o
     (ou rode `Get-SupplementCatalog` depois de dot-source `tools/supplements.ps1`) antes de listar
     os temas; não hardcode uma lista de memória, ela já mudou antes.
   - `-WithSemanticKb` — MCP de busca semântica local via Ollama + `sqlite-vec` (offline, sem custo
     de API); exige Ollama + `uv`.
   - `-Check` / `-DryRun` — mostra o que aconteceria, sem aplicar; ofereça se o pedido soar cauteloso.

**Sempre pergunte antes de instalar os opcionais** (`AskUserQuestion`): liste os temas do catálogo
atual (nome + `Reason` de cada) e deixe escolher "todos" · "nenhum" · um subconjunto. São opt-in
de propósito — alguns baixam de marketplace de terceiro ou mudam o footprint da máquina
(ex.: Ollama). **Nunca decida sozinho e nunca omita a existência deles** só porque exigem flag
extra — "setup completo" inclui pelo menos **oferecer**, mesmo que a resposta seja "não, obrigado".

**Depois de instalar:** pergunte se o usuário quer criar o primeiro projeto agora
(`New-SddProject <caminho> -Git -Open`, alias `nsp` — só existe **após reabrir o terminal**, pois é
registrado no `$PROFILE` pelo passo 1). Ofereça, não force.

## Onde confirmar antes de citar uma flag
`install.ps1`/`new-project.ps1` documentam os próprios parâmetros no cabeçalho
(`Get-Help .\onboarding\install.ps1 -Full`, ou leia o bloco `.PARAMETER`). Não invente flag — se
não confirmou no `-Help` ou no arquivo, marque como não-verificado antes de recomendar.

## O relato diz *que* dói — não diz *por quê*

Trabalho novo entra por **relato**: uso real de um projeto scaffolded, análise externa, nota em
`docs/`, item antigo do backlog. Trate todos como **sintoma verificado, causa não verificada** — a
dor costuma ser real, a explicação que vem junto raramente sobrevive à leitura do código. Casos:
o relato culpou o `ConvertTo-SlugKey` (era o passo 3 do `/ship` que não rodava); uma análise afirmou
que `tools/` não pode ser dot-sourced sob a Execution Policy (`RemoteSigned` — funciona, medido);
o backlog anunciou o bootstrap remoto como "fora de escopo" por uma semana depois de shipado.

**Confirme a causa no código antes de implementar. Se a premissa cair, o item não vira
implementação — vira correção do registro:** marque-o obsoleto com a medição que o derrubou dentro
dele. Vale para o que este repositório afirma sobre si mesmo — decisão de "NÃO fazer" envelhece como
qualquer outra, e quando é revertida o item que a registra é a primeira coisa a mentir.

**Escrever o item também é afirmar.** A regra acima rege o momento de implementar; esta rege o de
**registrar**: o item nasce com o artefato de análise aberto, não com o arquivo-alvo. Abra o alvo
antes de afirmar o que ele contém — o que não conferiu entra escrito como não-verificado, igual à
flag que você não confirmou no `-Help`.

## O que NÃO fazer
- Não rode `-ExtraPlugins`/`-WithSemanticKb` sem perguntar antes — opt-in é opt-in, não "padrão oculto".
- Não confunda este arquivo com o `AGENTS.md` de `templates/project-scaffold/` — aquele é para
  projetos **criados** por este framework; este é só para quem abre **este** repositório.
- Não invente conteúdo do catálogo de suplementos — leia `tools/supplements.psd1` no momento do pedido.
- Não adote a causa que um relato propõe sem conferi-la no código — nem a de um relatório de análise
  de IA, que erra igual e escreve com a mesma confiança.
