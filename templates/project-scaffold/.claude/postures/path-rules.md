# Rules de área — regra que vale só para uma parte do projeto (sob demanda)

> **Carregada sob demanda**, não always-on. Leia antes de gravar uma regra que o usuário declarou
> valer só para **uma parte** do projeto. Quem pergunta por essas regras e manda ler este arquivo são
> o `/setup`, o `/train-kb` e o `/learn`. Numa sessão que não grava rule, custa **0 token**.

## O que é

Um arquivo em `.claude/rules/` com `paths:` no frontmatter. O Claude Code **não** o carrega no início
da sessão. Ele é injetado quando o modelo **lê** um arquivo que casa um dos globs. Isso vale também
para o subagente que lê o arquivo. Até então, custa 0 token.

```markdown
---
paths:
  - "migrations/**"
---
# Migrations

- Migration já aplicada não se edita. Correção entra como migration nova.
```

## Quando vira rule de área — e quando não vira

| A regra é… | Destino |
|------------|---------|
| **Prescritiva** ("sempre/nunca faça X") **e** presa a um glob ("em `models/marts/**`") | **rule de área** (este contrato) |
| Prescritiva e vale para o projeto inteiro | `rules/project-context.md` → *Convenções* (via `/setup`) |
| Descritiva: o que algo **é**, como funciona, onde fica | KB (`/train-kb`), na camada certa |
| Procedimento para rodar/recuperar | KB `operations` (runbook) |
| Tem que valer **ao criar o primeiro arquivo** da área | `project-context.md`, **não** rule de área (ver *Limite*) |

Na dúvida entre KB e rule de área, pergunte: *"se o modelo editar um arquivo daqui sem saber disso,
ele erra?"* Se erra, é rule de área. Se só fica menos informado, é KB.

## Limite: só a leitura carrega a rule

Medido em 2026-09-25 pela contagem de tokens: **Read** do arquivo casado carrega a rule (sessão
4/4, subagente 6/6). **Write de arquivo novo, Glob, Grep e `cat` pelo Bash não carregam** (0/2
cada). **Edit** passa porque exige Read antes. Consequência: a rule protege quem **mexe** em arquivo
da área, não quem **cria** o primeiro arquivo nela, nem quem só busca nela. Uma regra de criação
("todo model novo leva `schema.yml`") precisa ser always-on, ou vir de um command que a leia
explicitamente.

## Formato

- **Um arquivo por área:** `.claude/rules/area-<slug>.md` (`area-migrations.md`,
  `area-marts.md`). O prefixo separa as rules do usuário das rules do scaffold.
- **Frontmatter:** só `paths:`, em lista de bloco com aspas. Os globs são relativos à raiz do
  projeto: `**` cobre qualquer profundidade, `*` não cruza `/`, `{ts,tsx}` expande.
  `"src/**/*.{ts,tsx}"` cobre `src/a.ts` e `src/x/y/b.tsx`.
- **Corpo curto:** a regra no imperativo, com o porquê em uma linha. Uma rule de área carrega
  inteira toda vez que um arquivo da área é lido. **Até ~40 linhas.** Se passar disso, a parte
  descritiva vai para a KB e a rule fica só com o que o modelo erraria sem saber.
- **Não repita** o que já está no `project-context.md` nem na KB. A rule de área é o que só vale ali.

## Depois de gravar

1. **Confirme com o usuário** o texto e o glob antes de gravar. A regra é dele.
2. Rode **`/sync-context`**: a lista `rules` do `AGENTS.md` ganha a linha, **com a área**
   (Codex e Cursor não leem `paths:`, e sem a área tratariam a rule como global).
3. Rode **`/check`**: a seção `rules` avisa se um glob não casa nenhum arquivo (`dead-glob`, que
   geralmente é erro de digitação) ou se a lista não diz a área (`area-missing-in-list`).

## Match the Form to the Failure

Vale para qualquer rule ou command **novo**, de área ou não: escolha a forma pelo **tipo de falha**
que ele precisa prevenir — a forma que blinda um tipo de falha **piora** outro:

| Falha de base | Forma certa | Forma errada |
|----------------|-------------|--------------|
| Pula/viola a regra sob pressão (sabe, mas ignora) | Proibição + tabela de racionalização + red flags (ex.: `rules/workflow-sdd.md` §Racionalizações) | Orientação frouxa ("prefira...", "considere...") |
| Cumpre, mas a saída sai na forma errada (formato inchado, veredito enterrado, spec reescrita) | Receita positiva: diga o que a saída **é** — as partes, em ordem | Lista de proibições ("não faça X", "nunca narre Y") |
| Omite um elemento obrigatório de algo que já produz | Campo/seção **estrutural** obrigatória no template | Lembrete em prosa perto do template |
| Comportamento deveria depender de uma condição | Condicional amarrado a um **predicado observável** ("se a KB tem ≥1 domínio…") | Regra incondicional + cláusulas de exceção soltas |

Identifique a falha-alvo **primeiro**; a forma vem depois — não o inverso.

## O que NÃO fazer

- Não transforme em rule de área uma regra que o usuário não declarou. Esta postura **oferece**,
  não infere.
- Não crie rule de área com glob amplo (`**`, `src/**` num projeto que é todo `src/`). Isso é
  always-on disfarçado. Nesse caso o destino é o `project-context.md`.
- Não use rule de área como índice de conhecimento. Para isso existe a KB.
