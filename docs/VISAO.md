# Visão do projeto · Project Vision

> North star do projeto. Tudo que entra no backlog é validado contra esta visão
> (ver `features/VALIDACAO.md`, no repositório de desenvolvimento).

## Objetivo (uma frase)

Um **scaffold genérico e sem contexto de tarefa** que, após um setup inicial, se
**auto-otimiza** para o projeto/tarefa atual — instalando dependências, curando agentes e
treinando uma KB — para que qualquer pessoa execute trabalho com IA com **velocidade,
consistência e qualidade**, usando **Spec-Driven Development (SDD)**.

## Para quem

**Produto aberto/reutilizável.** Um **framework genérico**, que qualquer pessoa clona e usa nos
próprios projetos.

## O porquê (dores que resolve)

| Dor | Como a metodologia resolve |
|-----|----------------------------|
| **Velocidade de início** | 1 comando deixa um projeto novo pronto (deps + config + SDD). |
| **Consistência** | Mesma forma de trabalhar e mesmo padrão de qualidade em todo projeto. |
| **Qualidade da execução** | Disciplina SDD: requisitos claros, design antes de codar, verificação real. |
| **Reuso de conhecimento** | KB acumula padrões reaproveitáveis entre projetos. |

## Princípios

1. **Genérico e context-free.** O scaffold **não carrega** contexto de tarefa. Ele é uma
   base limpa que **se especializa** quando inicializado.
2. **Auto-otimização na inicialização.** A partir do planejamento inicial, o projeto roda
   **curadoria**: ajusta/gera os agentes certos (`/audit-agents`), treina a KB do domínio
   (`/train-kb`) e sincroniza o contexto. Especialização sob demanda, não pré-fabricada.
3. **SDD como espinha de execução.** Features maiores passam por brainstorm → define →
   spec → build → ship; tarefas pequenas usam o Dev Loop.
4. **Claude-first, portável.** Otimizado para Claude Code (commands, skills, hooks, MCP),
   mas com artefatos (SDD, KB, regras) estruturados para portar a outras ferramentas.
5. **Qualidade verificável.** Nada é "pronto" sem verificação real (lint, testes, critérios
   de aceite). Não inventar dados.

## Como funciona (fluxo-alvo)

```text
1. INSTALAR     onboarding/install   → máquina pronta (deps + ~/.claude pessoal)
2. CRIAR        new-project          → copia o scaffold genérico (sem contexto)
3. SETUP        /setup               → captura contexto do projeto (stack, domínio)
4. CURADORIA    init/auto-otimização → /audit-agents + /train-kb especializam o projeto
5. EXECUTAR     SDD                  → /brainstorm → /define → /spec → /build → /ship
```

> Os passos 1–2 (instalador) e o passo 4 (curadoria automática) são as features em aberto
> que dão o diferencial "pronto para rodar e auto-otimizável".

## Definição de sucesso

- Clonar o framework e, em **1 fluxo de inicialização**, ter um projeto especializado e
  pronto para executar SDD.
- O mesmo scaffold serve a domínios diferentes (dados, web, automação) **sem** carregar
  contexto de nenhum deles por padrão.
- A KB e os agentes do projeto refletem o domínio real após a curadoria.

## Alternativas: Spec Kit e OpenSpec

Os dois projetos de SDD mais conhecidos têm comunidade muito maior que a deste. Conferido na API do
GitHub em 2026-10-18: o [Spec Kit](https://github.com/github/spec-kit) tinha 141.770 estrelas e
release v1.2.1, e o [OpenSpec](https://github.com/Fission-AI/OpenSpec) tinha 72.322 estrelas e
release v1.14.3. Os dois são MIT. O que vem abaixo sobre eles foi lido no README de cada um, na
mesma data.

| | Spec Kit | OpenSpec | Native-SDD |
|---|---|---|---|
| **Instalação** | `uv tool install specify-cli`; pede Python 3.11+ e uv | `npm install -g @fission-ai/openspec`; pede Node.js 20.19+ (ou Homebrew) | um comando instala as CLIs, o Claude Code e o `~/.claude` (`onboarding/install`), e o `new-project` cria cada projeto |
| **Agentes** | vários, por "integration" (o exemplo usa o GitHub Copilot) | "30+" ferramentas, segundo o README | Claude-first. No Codex, o guard, as skills e o `AGENTS.md` passaram num e2e (3/3, em [`MEDICOES.md`](MEDICOES.md)); nenhuma outra ferramenta foi medida |
| **Fluxo** | `constitution` uma vez; `specify → plan → tasks → implement → converge` por feature; extensões de bug e de avaliação de ideia | `explore`, `propose`, `apply`, `archive`; o README diz "no rigid phase gates" | `/brainstorm → /define → /spec → /build → /ship`, uma fase por vez, e o `/dev` para tarefa pequena |
| **Extensão** | extensions, presets, workflows, bundles e catálogos (inclusive privados) | profiles, schemas da comunidade e "stores" (beta) para planejar entre repositórios | curadoria por projeto (`/audit-agents`, `/train-kb`), suplementos opt-in e `/adapt` para projeto existente |
| **Runtime** | CLI em Python | CLI em Node.js; coleta estatística anônima de uso, com opt-out | PowerShell 7+ em Windows, Linux e macOS |

**O que este projeto faz e os READMEs dos outros dois não descrevem:** prepara a máquina inteira,
não só o projeto; o projeto já nasce com guardas que rodam fora do modelo, como o pre-commit
anti-segredo (o Spec Kit oferece hooks de evento do agente, mas como extensão); e cada projeto
treina os próprios agentes e a própria KB depois de criado. Isso foi comparado com o README, não com
a documentação inteira deles.

**Quando escolher outro:** se o time usa Copilot, Cursor ou várias ferramentas ao mesmo tempo, se
precisa de catálogo e extensões mantidos por uma comunidade grande, ou se não quer PowerShell na
máquina. Os dois são escolhas melhores nesses casos.

## Fora de escopo (não-objetivos)

- Não é um framework de aplicação (não dita linguagem/stack do projeto-alvo).
- Não embute segredos, credenciais ou contexto corporativo.
- Não tenta ser 100% agnóstico de ferramenta na v1 — Claude-first, portável depois.
