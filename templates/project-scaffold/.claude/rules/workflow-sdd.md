# Workflow SDD (sempre aplicado)

Este projeto usa **Spec-Driven Development** em 5 fases sequenciais. Quando o usuário
inicia trabalho de feature, escolha a fase certa e rode o command correspondente.

## Mapa de fases

| Fase | Gatilhos (pt-BR + EN) | Command | Artefato |
|------|------------------------|---------|----------|
| 0. Brainstorm | "brainstorm", "explorar ideia", "vamos pensar em" · *"let's explore", "think through"* | `/brainstorm` | `.claude/sdd/features/BRAINSTORM_<FEATURE>.md` |
| 1. Define | "define", "requisitos", "critérios de aceite" · *"requirements", "acceptance criteria"* | `/define` | `.claude/sdd/features/DEFINE_<FEATURE>.md` |
| 2. Design | "design", "arquitetura", "spec técnica" · *"architecture", "tech spec", "write the spec"* | `/spec` | `.claude/sdd/features/DESIGN_<FEATURE>.md` |
| 3. Build | "build", "implemente", "execute" · *"implement", "let's code this"* | `/build` | código + `.claude/sdd/reports/BUILD_REPORT_<FEATURE>.md` |
| 4. Ship | "ship", "encerrar feature", "arquivar" · *"wrap up", "close the feature", "archive"* | `/ship` | `.claude/sdd/archive/<FEATURE>/SHIPPED_<DATE>.md` |

> **O idioma do projeto é seu.** Artefatos, `BACKLOG.md` e as seções que os lints exigem
> (`## Não exercitado`/`## Not exercised`, `## Aberto`/`## Open`, `## Regras críticas`/`## Critical rules`)
> valem em português ou inglês: **mantenha um só por documento**, porque o idioma do cabeçalho decide como a seção é lida.

## Regras de engajamento

1. **Uma fase por vez.** Não pule à frente. Se pedirem `/build` sem DESIGN, faça o
   `/define`/`/spec` primeiro ou pergunte em que fase entrar.
2. **Um artefato por fase, sem fundir.** Cada fase recebe o caminho do documento da fase
   anterior (BRAINSTORM → DEFINE → DESIGN → BUILD → SHIP) e não escreve sem ele.
3. **Não pule o BRAINSTORM** a menos que o usuário diga explicitamente que os requisitos
   já estão claros.
4. **Templates** ficam em `.claude/sdd/templates/` — leia o da fase antes de gerar o artefato.
5. **Gate de qualidade:** o DEFINE tem um *Clarity Score* (mín. 12/15) antes de avançar
   para DESIGN. Não avance abaixo do mínimo sem confirmação.
6. **SHIPPED só depois** do BUILD_REPORT completo e verificado.

## Dev Loop (alternativa para tarefas pequenas)

Para utilitários, scripts de um arquivo ou protótipos, prefira o **Dev Loop** em vez do
SDD completo:

| Gatilho | Command | Artefato |
|---------|---------|----------|
| "tarefa pequena", "script rápido", "protótipo" | `/dev` | direto ao código (sem ciclo de 5 fases) |
| "redesign", "refazer a tela" · *"redesign this screen"* | `/dev` (trilha de redesign) | antes/depois aprovado + `visual-check` |

**Redesign de tela que já existe não vai direto ao código.** Pedido para refazer ou melhorar a cara de uma tela existente ("refaz a tela", "está feia", "redesign") sem mudar dado nem fluxo: antes de editar qualquer arquivo de UI, rode `/dev` (via `Skill`) e siga a trilha de redesign dele. O antes e as direções vêm primeiro; sem aprovação do usuário, não implemente.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "Os requisitos já estão claros, posso pular o BRAINSTORM/DEFINE" | Clareza aparente vira retrabalho no BUILD. Só pule com autorização explícita. |
| "É uma mudança pequena, não precisa de fase" | Se é pequena mesmo, use o **Dev Loop** (`/dev`): é a fase certa, não a ausência dela. |
| "Junto DEFINE e DESIGN num doc só pra ir mais rápido" | Um artefato por fase deixa cada gate verificável; fundir esconde a lacuna. |
| "O Clarity Score está em 11, mas dá pra seguir" | 12/15 é o piso de requisito não-ambíguo: feche a lacuna, não o número. |
