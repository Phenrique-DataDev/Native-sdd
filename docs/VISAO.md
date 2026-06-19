# Visão do projeto · Project Vision

> North star do projeto. Tudo que entra no backlog é validado contra esta visão
> (ver [`features/VALIDACAO.md`](../features/VALIDACAO.md)).

## Objetivo (uma frase)

Um **scaffold genérico e sem contexto de tarefa** que, após um setup inicial, se
**auto-otimiza** para o projeto/tarefa atual — instalando dependências, curando agentes e
treinando uma KB — para que qualquer pessoa execute trabalho com IA com **velocidade,
consistência e qualidade**, usando **Spec-Driven Development (SDD)**.

## Para quem

**Produto aberto/reutilizável.** Começa como ferramenta pessoal, mas é desenhado para ser
um **framework genérico** que qualquer pessoa possa clonar e usar nos próprios projetos.

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
   design → build → ship; tarefas pequenas usam o Dev Loop.
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
5. EXECUTAR     SDD                  → /brainstorm → /define → /design → /build → /ship
```

> Os passos 1–2 (instalador) e o passo 4 (curadoria automática) são as features em aberto
> que dão o diferencial "pronto para rodar e auto-otimizável".

## Definição de sucesso

- Clonar o framework e, em **1 fluxo de inicialização**, ter um projeto especializado e
  pronto para executar SDD.
- O mesmo scaffold serve a domínios diferentes (dados, web, automação) **sem** carregar
  contexto de nenhum deles por padrão.
- A KB e os agentes do projeto refletem o domínio real após a curadoria.

## Fora de escopo (não-objetivos)

- Não é um framework de aplicação (não dita linguagem/stack do projeto-alvo).
- Não embute segredos, credenciais ou contexto corporativo.
- Não tenta ser 100% agnóstico de ferramenta na v1 — Claude-first, portável depois.
