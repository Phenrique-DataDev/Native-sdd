# DEFINE: {Nome da Feature}

> Uma frase descrevendo o que vamos construir.

## Metadados

| Atributo | Valor |
|----------|-------|
| **Feature** | <FEATURE> |
| **Data** | {AAAA-MM-DD} |
| **Status** | Rascunho / Em progresso / Precisa esclarecer / Pronto para Design |
| **Clarity Score** | {X}/15 |

---

## Problema
{1–2 frases: quem tem o problema e qual o impacto. Seja específico.}

## Usuários-alvo

| Usuário | Papel | Dor |
|---------|-------|-----|
| {…} | {…} | {…} |

## Goals (priorizados)

| Prioridade | Goal |
|------------|------|
| **MUST** | {não-negociável para o MVP} |
| **SHOULD** | {importante, mas há workaround} |
| **COULD** | {nice-to-have, primeiro a cortar} |

## Success Criteria (mensuráveis — com números)
- [ ] {ex.: processa 1000 registros/min}
- [ ] {ex.: latência < 200ms}

## Acceptance Tests

> **Falsificador** = a condição concreta sob a qual o AT **reprova**. É o que o `/build` reintroduz
> na verificação por mutação. Obrigatório em AT de **comportamento executável**; `N/A` **declarado**
> (com o que verifica no lugar) em AT de doc/redação/estrutura. Vazio não é opção — ver `/define`.
> AT cujo `Then` depende da **saída de um modelo** (LLM) não tem resultado exato: o Falsificador é o
> limiar do `## Eval Set` (ex.: "reprova se a acurácia < 0,9 nos 50 casos").
> Critério que **só uma pessoa julga** (game feel, dificuldade, tom de texto, clareza da UX) não tem
> Falsificador: vai para o `## Julgamento humano`, com quem julga e o que conta como aprovado.

| ID | Cenário | Given | When | Then | Falsificador — reprova se… |
|----|---------|-------|------|------|-----------------------------|
| AT-001 | {happy path} | {estado} | {ação} | {resultado esperado} | {ex.: "o campo X deixar de ser validado"} |
| AT-002 | {erro} | {…} | {…} | {…} | {…} |
| AT-003 | {edge case} | {…} | {…} | {…} | {…} |

## Eval Set (só se `Componente LLM` = sim — senão apague a seção)

> Saída de modelo varia entre rodadas: o AT dela é uma **taxa sobre N casos fixos**, nunca uma
> rodada só. O código em volta do modelo (parse, retry, roteamento, tool) continua nos AT de cima,
> com o modelo stubado. Ver `/define`.

| Campo | Valor |
|-------|-------|
| **Casos** | {caminho do dataset versionado} · N = {nº de casos} |
| **Métrica e limiar** | {ex.: acurácia ≥ 0,9 · JSON válido em 100%} |
| **Baseline** | {o degrau mais simples (ex.: um prompt só) e a métrica dele — a complexidade a mais tem de superá-lo} |
| **Juiz** | {determinístico (match, schema, execução) > rubrica > LLM-judge de outro modelo} |
| **Como roda** | {comando · modelo e versão · temperatura/seed, se o provedor deixar · custo por rodada} |

## Julgamento humano (só se algum critério só uma pessoa julga — senão apague a seção)

> O que vira número fica nos AT de cima: tempo de frame, altura do pulo, cliques até a tela X. Aqui
> entra só o resto, e cada linha diz **quem** julga, **como** e o que conta como **aprovado**. O
> `validator` não julga por ninguém: a linha fica ⏳ até o julgamento ser registrado no
> BUILD_REPORT. Ver `/define`.

| ID | Critério | Por que não vira métrica | Juiz | Como | Aprovado se… |
|----|----------|--------------------------|------|------|--------------|
| JH-001 | {ex.: o pulo "responde" ao controle} | {o que já virou AT (altura, coyote time) e o que sobra} | {quem: papel, nº de pessoas} | {ex.: playtest de 10 min com roteiro, na build X} | {ex.: 4 de 5 jogadores dizem que sim sem ajuda} |

## Out of Scope
- {o que NÃO faremos agora}

## Constraints

| Tipo | Restrição | Impacto |
|------|-----------|---------|
| Técnica | {ex.: usar schema existente} | {…} |
| Prazo | {…} | {…} |

## Contexto técnico (para o Design)

| Aspecto | Valor | Notas |
|---------|-------|-------|
| **Localização do código** | {src/ \| scripts/ \| models/ \| …} | {por quê} |
| **Domínios de KB** | {ex.: sql, python, dbt, warehouse} | {padrões a consultar} |
| **Impacto de infra/IaC** | {novo \| modifica \| nenhum \| TBD} | {…} |
| **Componente LLM** | {não \| sim: o que o modelo decide} | {sim pede o `## Eval Set` acima} |

## Assumptions

| ID | Premissa | Se errada, impacto | Validada? |
|----|----------|--------------------|-----------|
| A-001 | {…} | {…} | [ ] |

## Clarity Score

| Elemento | Nota (0–3) | Notas |
|----------|------------|-------|
| Problema | {0-3} | |
| Usuários | {0-3} | |
| Goals | {0-3} | |
| Success | {0-3} | |
| Scope | {0-3} | |
| **Total** | **{X}/15** | |

> 0 = ausente · 1 = vago · 2 = claro mas incompleto · 3 = cristalino.
> **Mínimo para avançar: 12/15.**

## Perguntas em aberto
{liste o que falta responder antes do Design, ou "Nenhuma — pronto para Design".}

---

**Próximo passo:** `/spec .claude/sdd/features/DEFINE_<FEATURE>.md`
