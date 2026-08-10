---
description: "Especializar o scaffold — orquestra a cadeia de curadoria (/setup → /audit-agents → /train-kb → /sync-context) e fecha com nota de clareza do objetivo + confirmação; resumável"
---

# /init — especializar o scaffold (orquestra a curadoria)

Conduz, num **fluxo único e guiado**, a cadeia de especialização do projeto:
**(0) `/setup`** (se ainda não inicializado) → **`/audit-agents`** (G2) → **`/train-kb`** (G3)
→ **`/sync-context`** (G4) → **nota de clareza + confirmação do objetivo** (Passo 6). Pede
**aprovação entre cada etapa** e é **resumável**: pula o que já foi feito.

> Feature **G1** (EPIC G — curadoria/auto-otimização). Distinção importante: o **`/setup`**
> preenche o **contexto** do projeto (`project-context.md`); o **`/init`** **especializa** o
> scaffold genérico nesse contexto, orquestrando os comandos da curadoria. O `/init` **não
> reimplementa** nada dos sub-comandos — ele os **conduz**, na ordem certa, com gates.

---

## Uso

```text
/init             # fluxo completo: status → (setup?) → audit-agents → train-kb → sync-context → clareza+confirmação
/init --status    # só o painel de prontidão, sem executar nada (não roda o Passo 6)
```

---

## Passo 0 — Painel de prontidão

Carregue as funções de status e mostre o estado atual:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/init.ps1"
Format-CurationReport (Get-CurationStatus -Root .)
```

`Get-CurationStatus` é **read-only** e reusa `Get-AgentInventory` (G2) e `Get-KbInventory`
(G3). O painel lista cada etapa (✓ concluída · • próxima · – pendente) e o **`NextStep`**.
Se `--status`, **pare aqui**.

---

## Passo 1 — Etapa 0 (condicional): `/setup`

Se `Status.ProjectInitialized` é **falso** (`project-context.md` ainda é `template`/tem
placeholders), **conduza o `/setup` primeiro** — carregue a lógica de
[`setup.md`](setup.md) e execute o wizard. Sem contexto não há o que especializar.

Ao terminar, **recompute** o status (`Get-CurationStatus`) antes de seguir. Se o projeto já
está inicializado, pule direto ao Passo 2.

---

## Passo 2 — G2: `/audit-agents`

1. **Prontidão:** `Test-CurationReadiness -Stage audit-agents -Status <status>` deve ser
   `$true` (exige projeto inicializado).
2. **Resumível:** se `Status.DomainAgents > 0`, ofereça **pular** (a curadoria de agentes já
   gerou algo) ou rodar de novo (`/audit-agents` é idempotente; `--regen` reconsidera os já
   gerados).
3. **Conduza** o [`/audit-agents`](audit-agents.md) (analisa o contexto, gera agentes de
   domínio nas lacunas).
4. **Gate** (`AskUserQuestion`): *"G2 concluído. Seguir para o `/train-kb`?"* →
   (a) seguir · (b) revisar/ajustar antes · (c) parar aqui.

---

## Passo 3 — G3: `/train-kb`

1. **Prontidão:** `Test-CurationReadiness -Stage train-kb -Status <status>` deve ser `$true`.
2. **Resumível:** se `Status.KbDomains > 0`, ofereça pular ou continuar (`/train-kb` é
   idempotente — não duplica entradas; só preenche lacunas).
3. **Conduza** o [`/train-kb`](train-kb.md) (deriva ondas e povoa a KB; camada `tools/` aplica
   `docs-first`/context7).
4. **Gate** (`AskUserQuestion`): *"G3 concluído. Seguir para o `/sync-context`?"* →
   (a) seguir · (b) revisar · (c) parar aqui.

---

## Passo 4 — G4: `/sync-context`

Sem gate rígido (G4 reflete o estado atual). **Conduza** o [`/sync-context`](sync-context.md)
para **fechar o loop**: regenera `AGENT_MAP.md` + `kb/_index.yaml` e atualiza as regiões
marcadas em `AGENTS.md`/`CLAUDE.md`. Depois, **gate** final: *"Curadoria sincronizada. Conferir
`git diff` (deve mostrar só índices/refs)?"*

---

## Passo 5 — Painel final

Recompute e mostre o estado:

```text
Format-CurationReport (Get-CurationStatus -Root .)
```

O ideal é `NextStep: done` (projeto inicializado + agentes de domínio + KB povoada + índices
sincronizados). Aponte o que ficou pendente, se houver.

---

## Passo 6 — Nota de clareza do objetivo + confirmação

O painel do Passo 5 diz que a **curadoria** rodou; ele **não** diz que ela se especializou no
objetivo **certo**. Este passo fecha essa lacuna antes de o projeto começar a produzir: dá uma
**nota** ao objetivo, devolve um **resumo para o usuário confirmar** e pergunta o que já existe e
pode ser **reaproveitado**. Roda **sempre** ao fim de um `/init` completo (pule só no `--status`).

### 6.1 — Nota de clareza (0–3 por eixo, **piso 12/15**)

Pontue o **objetivo do projeto** como ele está registrado agora — fonte: `project-context.md`,
o que a KB povoou e os agentes de domínio gerados. Mesma rubrica do *Clarity Score* do
[`/define`](define.md), aplicada ao **projeto**, não a uma feature:

| Eixo | 0 | 3 |
|------|---|---|
| **Problema** — que dor o projeto resolve | não aparece em lugar nenhum | uma frase concreta, com o custo de não resolver |
| **Usuário** — para quem | "usuários" genérico | papel identificável e o que ele faz com isto |
| **Pronto** — como se sabe que funcionou | não definido | resultado **observável** (mensurável ou demonstrável) |
| **Escopo** — o que fica **de fora** | nada declarado | ao menos um "não faremos X" explícito |
| **Restrições** — stack, prazo, dados, compliance | vazio/placeholder | stack e limites reais, coerentes com o repo |

**Abaixo de 12/15 não declare o `/init` concluído.** Liste **as lacunas nomeadas** (qual eixo, o
que falta) e pergunte — não invente o que falta nem arredonde a nota para passar. Depois de o
usuário responder, **recompute** e grave o que ele esclareceu em `project-context.md`.

> A nota é **julgamento seu**, não script — e é sobre o **registro**, não sobre a sua impressão da
> conversa. Um eixo que só existe no seu contexto de sessão vale **0**: quem abrir o projeto amanhã
> lê o arquivo, não o transcript.

### 6.2 — Resumo para confirmação (estrutura fixa)

Devolva **exatamente estes 5 itens**, curtos, derivados do que está gravado — depois a nota:

```text
Objetivo    : <1 frase — o que este projeto faz e para quem>
Pronto      : <como se verifica que funcionou>
Fora do escopo: <o que este projeto NÃO vai fazer>
Stack       : <linguagem/runtime/dados/CI, como capturados>
Curadoria   : <N agentes de domínio · M domínios de KB · índices sincronizados>

Clareza: X/15  (Problema n · Usuário n · Pronto n · Escopo n · Restrições n)
```

Então **pergunte** (`AskUserQuestion`): *"É isto mesmo?"* → (a) confirmar e seguir · (b) corrigir
um item (diga qual) · (c) refazer o `/setup`. **Não siga sem resposta** — o ponto do passo é o
usuário reconhecer o próprio projeto na descrição, ou descobrir agora que a curadoria entendeu
outra coisa.

### 6.3 — Reaproveitar o que já existe

Antes de qualquer trabalho novo, verifique se há **código/pasta/repositório já existente** que este
projeto deveria absorver ou consultar. **Não construa varredura de disco** — olhe o observável e
**pergunte**:

| Sinal observável | Rota |
|---|---|
| O próprio diretório já tem código/manifesto anterior ao scaffold (`git log` com história prévia, `package.json`/`pyproject.toml`/etc. não criados agora) | **[`/adapt`](adapt.md)** — brownfield: detecta stack + higiene, absorve o `.claude/` já aplicado |
| O usuário aponta **outra pasta/repo** com o trabalho que este projeto continua | **[`/adapt`](adapt.md)** naquele caminho, ou mover o conteúdo para cá **por decisão dele** — nunca copie por conta própria |
| Existe repo **de referência** (padrão/convenção já resolvidos alhures) que não deve ser absorvido | **[`/complementary-repos`](complementary-repos.md) `add`** — consulta read-only, nunca vendoriza |
| Nada disso | siga — nenhuma pergunta a mais |

Se nenhum sinal aparecer no repo, **pergunte uma vez**: *"Existe repositório ou pasta já existente
que este projeto deve aproveitar (absorver) ou consultar como referência?"* — e roteie pela tabela.
Uma vez. Se a resposta for "não", não volte a perguntar em execuções seguintes.

### O que NÃO fazer neste passo

- **Não** declarar `/init` concluído com clareza < 12/15 sem o usuário ter respondido às lacunas.
- **Não** inflar a nota para fechar o fluxo — nota alta com `project-context.md` vago é a falha que
  este passo existe para pegar.
- **Não** preencher lacuna com suposição sua: pergunte, e grave a **resposta**.
- **Não** copiar, mover ou vendorizar conteúdo de outra pasta/repo por iniciativa própria — este
  passo **roteia** (`/adapt`, `/complementary-repos`), não transfere arquivo.
- **Não** varrer o disco atrás de "projetos parecidos" — o sinal é o repo atual + o que o usuário disser.
- **Não** repetir a pergunta do 6.3 a cada `/init` depois de já respondida.

---

## Idempotência e regras

- **Resumável:** o `/init` deriva o estado do repo a cada execução (`Get-CurationStatus`) e
  **não refaz** o que já está concluído — herda a idempotência de cada sub-comando.
- **Uma etapa por vez, na ordem** (`audit-agents` → `train-kb` → `sync-context`); o G4 depende
  do que G2/G3 produzem.
- **Aprovação entre etapas** (seguir / revisar / parar) — o usuário controla o ritmo e pode
  parar a qualquer momento sem deixar o projeto inconsistente.
- O `/init` **delega** aos comandos da curadoria; **não** reimplementa varredura, geração nem
  idempotência — só orquestra e reporta o estado.
- `--status` é **read-only**: só mostra o painel, não executa etapa nenhuma — **nem o Passo 6**.
- O **Passo 6 não é resumível pelo `Get-CurationStatus`**: ele julga o *objetivo*, não um artefato
  que o painel conte. Rode-o ao fim de todo `/init` completo; o que não se repete é a **pergunta de
  reaproveitamento** (6.3), uma vez respondida.
