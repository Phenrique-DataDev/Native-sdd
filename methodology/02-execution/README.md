# 02 · Execução com SDD

> Como **tocar o trabalho** com IA via **Spec-Driven Development (SDD)**: especificar antes
> de codar, uma fase por vez, com verificação real. O *porquê* aqui; os comandos em
> [`../../docs/USO.md`](../../docs/USO.md); a regra operacional em
> [`workflow-sdd.md`](../../templates/project-scaffold/.claude/rules/workflow-sdd.md).

## Princípio

Código é a **última** etapa, não a primeira. SDD força clareza antes do esforço: cada fase
produz um artefato que a próxima consome, então ambiguidade é resolvida no papel — barato —
antes de virar retrabalho — caro. A disciplina vale porque **um artefato por fase** mantém
o raciocínio rastreável e revisável.

## As 5 fases

| # | Fase | Pergunta que responde | Artefato |
|---|------|------------------------|----------|
| 0 | **Brainstorm** | *Vale a pena? Quais caminhos existem?* | `BRAINSTORM_<FEATURE>.md` |
| 1 | **Define** | *O que exatamente, e como sei que está pronto?* | `DEFINE_<FEATURE>.md` |
| 2 | **Design** | *Como vou construir? Que trade-offs?* | `DESIGN_<FEATURE>.md` |
| 3 | **Build** | *Construir + provar que funciona.* | código + `BUILD_REPORT_<FEATURE>.md` |
| 4 | **Ship** | *Encerrar, arquivar, registrar o aprendizado.* | `SHIPPED_<DATE>.md` |

Artefatos vivem em `.claude/sdd/` (`features/`, `reports/`, `archive/`).

## Regras de engajamento

1. **Uma fase por vez.** Não pule à frente; se pedirem `/build` sem DESIGN, faça
   `/define`/`/design` antes ou pergunte em que fase entrar.
2. **Passe o artefato anterior** como contexto da fase seguinte (a cadeia BRAINSTORM →
   DEFINE → DESIGN → BUILD → SHIP).
3. **Não funda fases** num documento gigante — um artefato por fase.
4. **Gate de qualidade no DEFINE:** *Clarity Score* mínimo (12/15) antes de avançar para
   DESIGN. Abaixo disso, não avança sem confirmação.
5. **Verificação real no BUILD:** lint, type-check e testes da stack; cobrir os
   *Acceptance Tests* do DEFINE. Nada é "pronto" com teste falhando.

## Dev Loop (tarefas pequenas)

Para utilitários, scripts de um arquivo ou protótipos, o ciclo completo é peso morto. Use
**`/dev`**: vai direto ao código, sem os 5 artefatos. A escolha SDD-completo × Dev Loop é
de **proporção** — quanto de incerteza e de risco a tarefa carrega.

## Subagents

Trabalho focado e independente é delegado a subagents (ferramenta `Agent`), que rodam em
contexto próprio:

- `@explorer` — mapear código/arquitetura desconhecida (read-only).
- `@test-writer` — gerar/completar testes cobrindo os Acceptance Tests.
- `@code-reviewer` — revisar diff/PR antes de encerrar.

Quando não há subagent dedicado, o slash command da fase é **auto-contido**. Roteamento e
mapa em [`agent-routing.md`](../../templates/project-scaffold/.claude/rules/agent-routing.md).

## Veja também

- Como contextualizar a IA antes de executar: [`../01-onboarding/`](../01-onboarding/)
- Padrões de qualidade e convenções: [`../03-standards/`](../03-standards/)
