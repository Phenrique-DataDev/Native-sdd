# 03 · Padrões e convenções

> Convenções de trabalho (**D1**) e padrões de qualidade no uso de IA (**D2**), consolidados
> aqui. Não reescreve as regras vivas — **referencia** os artefatos que já as aplicam
> (`~/.claude/CLAUDE.md` e `.claude/rules/`).

## Convenções de versionamento (D1)

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`…), mensagens em
  **pt-BR**. O tipo comunica a natureza da mudança e alimenta histórico/changelog.
- **Branches:** trabalho em branch de **feature** (`feat/...`, `fix/...`, `docs/...`),
  partindo da default atualizada. `main` é **protegida**.
- **`main`:** nunca commit/push direto nem merge sem **confirmação explícita**. Merges de
  integração usam `--no-ff` (commit de merge com a mensagem `merge: ...`).
- **Nunca** `push --force`, reset destrutivo ou rewrite de histórico compartilhado sem
  autorização explícita.
- **PRs:** descrevem o quê/porquê, referenciam o artefato SDD (DEFINE/DESIGN) e passam por
  revisão antes do merge.

> Fonte viva: seção *Git e autonomia* de [`~/.claude/CLAUDE.md`](../../templates/global-claude/CLAUDE.md).

## Padrões de qualidade no uso de IA (D2)

### Verificação real, sempre

Nada é **"pronto"** sem prova. No BUILD: lint, type-check e testes da stack do projeto,
cobrindo os *Acceptance Tests* do DEFINE. Relate falhas **honestamente** (mostre a saída) —
não marque verde sem rodar.

### Não inventar dados

Usar **apenas** o que se pode verificar: código, arquivos, saídas de comando. Se um dado
não foi confirmado, dizer que não foi — em vez de preencher com suposição.

### Gates de revisão

- `/review` (ou `@code-reviewer`) avalia, em ordem: **correção → segurança → aderência ao
  DESIGN/convenções → simplicidade/reuso → testes**.
- O gate do DEFINE (*Clarity Score* ≥ 12/15) impede avançar com requisito ambíguo.

### CLI-first (otimização)

Antes de implementar algo na mão, verificar se uma **CLI** já resolve (`gh`, `jq`, `yq`,
`rg`, `uv`, `git`). Menos código, mais rápido, já testado.
Regra: [`cli-first.md`](../../templates/project-scaffold/.claude/rules/cli-first.md).

### Higiene de segredos

**Não versionar** tokens, PATs, `.env` nem contexto confidencial de terceiros. Sanitizar o
que for público antes de cada commit.

### Anti-racionalização nos artefatos com gate (D4)

Um gate só vale se for **difícil de racionalizar para fora**. Todo artefato SDD com gate
(a regra [`workflow-sdd.md`](../../templates/project-scaffold/.claude/rules/workflow-sdd.md)
e os commands `/define`, `/build`, `/ship`, `/review`) documenta, junto da lógica:

- **`## Racionalizações comuns`** — tabela `| Desculpa | Realidade |` com as desculpas
  frequentes para pular um passo e a refutação direta de cada uma.
- **`## O que NÃO fazer`** (ou `## Red flags`) — os anti-padrões/sinais de que algo saiu do
  trilho.

Não é runtime — é **disciplina de autoria**: a desculpa que o agente (ou a pessoa) usaria
para pular o gate já vem refutada no próprio artefato. A presença das duas seções é
**verificável** por `tools/standards-lint.ps1` (achado `error` se faltar), rodado no CI sobre
o conjunto de artefatos com gate. Escopo deliberadamente **enxuto**: só onde há gate real —
não em todo command/agent.

## Retrato de contexto always-on (G8)

O Claude Code **auto-carrega o diretório `.claude/rules/` inteiro** como contexto **sempre-ativo**
(validado empiricamente) — junto de `CLAUDE.md`/`AGENTS.md`. Cada rule é, portanto, **imposto
permanente de token** na inicialização de toda sessão; o custo **cresce a cada nova postura** que vira
rule. Para que esse custo não fique invisível, `tools/rules-budget.ps1` **mede** o footprint always-on
(chars→tokens, reusando `Measure-KbContentSize` do B7 — exclui fenced code) e imprime o **total absoluto
+ ranking por-arquivo** (maior→menor).

É um **retrato**, não uma quota: **sem teto fixo, sem `%`, sem headroom, sem flag** (revisão de
2026-06-16). Um teto absoluto seria **arbitrário** e dispararia falso-positivo sobre o crescimento
**legítimo** do framework — contrário a "token é servo da qualidade" (abaixo). O `check.ps1` imprime o
retrato a cada run (visibilidade no PR) **fora do veredito** (exit 0; nunca bloqueia). Drift se percebe
**a olho / git** (o número aparece em todo run); nada compara contra uma barra.

> **Princípio-mãe:** o orçamento é **servo** da qualidade/velocidade — economia de token **nunca** as
> reduz. Por isso enxugar uma rule só vale quando **toda a verificação continua verde** (os `*-lint`
> exigem conteúdo na própria rule; esvaziá-la quebraria a disciplina). **Na dúvida, manter.**

## Tabela-resumo

| Padrão | Regra | Onde vive |
|--------|-------|-----------|
| Contexto always-on | retrato advisory das rules (total + ranking; sem teto/%; nunca bloqueia) | `tools/rules-budget.ps1`, `check.ps1` |
| Commits | Conventional Commits, pt-BR | `~/.claude/CLAUDE.md` |
| Branches / `main` | feature branch; `main` protegida | `~/.claude/CLAUDE.md` |
| Verificação | lint/test/acceptance antes de "pronto" | `workflow-sdd.md`, `/build` |
| Revisão | severidade priorizada | `/review`, `code-reviewer` |
| CLI-first | CLI antes de reimplementar | `.claude/rules/cli-first.md` |
| Segredos | nunca versionar | `~/.claude/CLAUDE.md` |
| Anti-racionalização | tabela desculpa→realidade + red flags nos gates | `workflow-sdd.md`, `/define`/`/build`/`/ship`/`/review`, `tools/standards-lint.ps1` |

## Veja também

- Onboarding de IA: [`../01-onboarding/`](../01-onboarding/)
- Execução com SDD: [`../02-execution/`](../02-execution/)
