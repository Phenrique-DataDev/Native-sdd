# Workflow SDD (sempre aplicado)

Este projeto usa **Spec-Driven Development** em 5 fases sequenciais. Quando o usuário
inicia trabalho de feature, escolha a fase certa e rode o command correspondente.

## Mapa de fases

| Fase | Gatilhos (pt-BR + EN) | Command | Artefato |
|------|------------------------|---------|----------|
| 0. Brainstorm | "brainstorm", "explorar ideia", "vamos pensar em" | `/brainstorm` | `.claude/sdd/features/BRAINSTORM_<FEATURE>.md` |
| 1. Define | "define", "requisitos", "critérios de aceite" | `/define` | `.claude/sdd/features/DEFINE_<FEATURE>.md` |
| 2. Design | "design", "arquitetura", "spec técnica" | `/design` | `.claude/sdd/features/DESIGN_<FEATURE>.md` |
| 3. Build | "build", "implemente", "execute" | `/build` | código + `.claude/sdd/reports/BUILD_REPORT_<FEATURE>.md` |
| 4. Ship | "ship", "encerrar feature", "arquivar" | `/ship` | `.claude/sdd/archive/<FEATURE>/SHIPPED_<DATE>.md` |

## Regras de engajamento

1. **Uma fase por vez.** Não pule à frente. Se pedirem `/build` sem DESIGN, faça o
   `/define`/`/design` primeiro ou pergunte em que fase entrar.
2. **Passe o artefato anterior.** Cada fase recebe o caminho do documento da fase prévia
   como contexto (BRAINSTORM → DEFINE → DESIGN → BUILD → SHIP).
3. **Não funda fases** num só documento gigante. Um artefato por fase.
4. **Não pule o BRAINSTORM** a menos que o usuário diga explicitamente que os requisitos
   já estão claros.
5. **Templates** ficam em `.claude/sdd/templates/` — leia o template da fase antes de
   gerar o artefato.
6. **Gate de qualidade:** o DEFINE tem um *Clarity Score* (mín. 12/15) antes de avançar
   para DESIGN. Não avance abaixo do mínimo sem confirmação.

## Dev Loop (alternativa para tarefas pequenas)

Para utilitários, scripts de um arquivo ou protótipos, prefira o **Dev Loop** em vez do
SDD completo:

| Gatilho | Command | Artefato |
|---------|---------|----------|
| "tarefa pequena", "script rápido", "protótipo" | `/dev` | direto ao código (sem ciclo de 5 fases) |

## Subagents

Cada command é **auto-contido** (carrega a própria lógica de fase). Para trabalho focado e
independente, as fases delegam a subagents genéricos (`explorer`, `test-writer`,
`code-reviewer`) via ferramenta `Agent` — catálogo e roteamento em
`.claude/rules/agent-routing.md`.

## Racionalizações comuns

Desculpas frequentes para pular uma fase ou um gate — e por que não colam:

| Desculpa | Realidade |
|----------|-----------|
| "Os requisitos já estão claros, posso pular o BRAINSTORM/DEFINE" | Clareza aparente vira retrabalho no BUILD. O DEFINE custa minutos; refazer o design custa horas. Só pule com autorização explícita. |
| "É uma mudança pequena, não precisa de fase" | Se é pequena mesmo, use o **Dev Loop** (`/dev`) — que é a fase certa, não a ausência dela. |
| "Junto DEFINE e DESIGN num doc só pra ir mais rápido" | Um artefato por fase existe para cada gate ser verificável. Fundir esconde a lacuna que o gate pegaria. |
| "O Clarity Score está em 11, mas dá pra seguir" | O mínimo (12/15) é o piso de "requisito não-ambíguo". Abaixo dele o DESIGN herda a ambiguidade — feche a lacuna, não o número. |

## O que NÃO fazer

- Não escrever DEFINE/DESIGN/BUILD sem ter o artefato da fase anterior.
- Não misturar várias fases num documento só.
- Não escrever o SHIPPED antes do BUILD_REPORT estar completo e verificado.
