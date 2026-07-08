# Repositórios complementares — referência read-only (postura, opt-in)

> Registro declarativo (`.claude/complementary-repos.psd1`) de outros repositórios do próprio
> usuário — locais e/ou remotos — que já resolveram um padrão/convenção parecido. Consulte **só
> sob demanda** (quando a tarefa atual claramente se beneficia), leia **sempre read-only** e
> **adapte** o que encontrar — nunca copie arquivo/módulo inteiro. Molde de postura:
> [`simulation.md`](simulation.md)/[`doubt-driven.md`](doubt-driven.md) (pull-only, sem engine).
> O boundary read-only tem um **backstop determinístico** — hook
> `complementary-repo-guard` (`PreToolUse`, `Write|Edit`) pede confirmação se você tentar
> escrever dentro de um repo complementar; esta regra é a disciplina, o hook é a rede de segurança.

## Princípio

Cada projeto reinventa convenções/soluções que já existem noutro repositório do mesmo usuário. O
registro dá ao agente um jeito de **consultar** esse conhecimento sem misturar histórico/conteúdo
entre repos nem vendorizar código de lá pra cá — o valor é a **referência**, não a importação.

## Quando aplicar (opt-in)

Consulte o registro quando a tarefa atual tiver um sinal como:

| Sinal | Exemplo |
|-------|---------|
| Pedido para seguir um padrão "como no outro projeto" | "faz igual o `design-system` faz nos componentes" |
| Convenção que provavelmente já foi resolvida alhures | versionamento de API, estrutura de módulo, nomeação |
| O próprio registro tem uma entrada com `Reason` que bate com a tarefa | entrada diz "convenções de UI já validadas" e a tarefa é criar um componente |

**Não** consulte por hábito em toda tarefa — se nenhuma entrada do registro é claramente
relevante, ignore o registro e siga o trabalho normal. Postura opt-in, não always-on.

## Pré-condição (registro existe)

`.claude/complementary-repos.psd1` **ausente** → nada a consultar; a postura fica em silêncio
total (não crie o arquivo sozinho — ele só existe se o usuário rodou `/complementary-repos add`).

## O ciclo CONSULTAR → RESOLVER → LER → ADAPTAR

| Passo | O que acontece |
|-------|-----------------|
| **CONSULTAR** | Verifique se alguma entrada do registro é relevante para a tarefa atual (pelo `Reason`). |
| **RESOLVER** | `Path` local existente → use direto. Só `Url` → pode exigir clone lazy (cache em `.claude/.cache/complementary-repos/`, gitignored) na primeira consulta — ver `tools/complementary-repos.ps1` (`Resolve-ComplementaryRepoLocation`). |
| **LER** | Leitura **sempre read-only** — nunca edite/escreva nada dentro do repo complementar (path local ou cache). |
| **ADAPTAR** | Reimplemente o padrão encontrado no contexto do **projeto atual**, adaptado às convenções locais — **cite a origem** (nome do repo complementar + caminho) no código/commit, para rastreabilidade. |

## Boundary read-only (nunca escrever no repo complementar)

- **Nunca** editar, criar ou apagar arquivo dentro de um `Path` registrado ou do cache de clone.
- O hook `complementary-repo-guard` (`PreToolUse`, matcher `Write|Edit`) pede confirmação
  (`ask`, nunca bloqueia sozinho) se um `Write`/`Edit` mirar um caminho protegido — é o backstop
  determinístico, não a única defesa. Escrita via `Bash` bruto (`cp`/`>`/`mv` apontando para o
  repo complementar) **não** é interceptada pelo hook — a disciplina desta regra é quem cobre
  esse caso.
- Se identificar algo que "deveria mudar" no repo complementar, **não mexa por aqui** — no
  máximo sugira ao usuário abrir essa mudança diretamente naquele projeto.

## Nunca vendorizar (só referência/padrão)

Adaptar **não** é copiar. Nunca copie um arquivo/módulo inteiro do repo complementar esperando que
funcione como está — reimplemente adaptado ao contexto local (convenções, stack, dependências já
existentes aqui). Mesma disciplina do caso `md-fetch` (preferir versão nativa adaptada a vendorizar
um binário/skill externo).

## Red flags

| Red flag | O que indica |
|----------|---------------|
| Consultou o registro numa tarefa sem nenhum sinal de relevância | Postura devia ficar em silêncio — não é always-on |
| Copiou um arquivo inteiro do repo complementar sem adaptar | Vendorização — viola a disciplina desta regra |
| Não citou de onde veio o padrão adaptado | Perde a rastreabilidade — sempre cite repo + caminho |
| Editou um arquivo dentro do `Path`/cache de um repo complementar | Violou o boundary read-only — o hook deveria ter pedido confirmação; não force um `Bash` bruto pra contornar |

## O que NÃO fazer

- **Não** crie o registro sozinho — ele só existe se o usuário rodou `/complementary-repos add`.
- **Não** consulte um repo complementar em toda tarefa — é opt-in, sob sinal de relevância real.
- **Não** escreva nada dentro de um `Path` registrado ou do cache de clone — read-only sempre.
- **Não** copie arquivo/módulo inteiro — sempre reimplemente adaptado, citando a origem.
- **Não** tente contornar o hook `complementary-repo-guard` via `Bash` bruto — a intenção da
  regra é não escrever ali, o mecanismo de contorno existir não muda a intenção.
- **Não** construa indexação prévia/motor de sincronização — leitura é sempre sob demanda nesta
  versão (ver `DESIGN_REPOS_COMPLEMENTARES.md`, Abordagem B cortada por YAGNI).
