# BUILD REPORT: {Nome da Feature}

> Relatório da implementação conforme o DESIGN.

## Metadados

| Atributo | Valor |
|----------|-------|
| **Feature** | <FEATURE> |
| **Data** | {AAAA-MM-DD} |
| **DESIGN** | [DESIGN_<FEATURE>.md](../features/DESIGN_<FEATURE>.md) |
| **Branch** | {feat/...} |

---

## Resumo
{o que foi construído, em 2–3 frases}

## Arquivos criados/alterados

| Arquivo | Mudança | Notas |
|---------|---------|-------|
| {caminho} | criado/alterado | {…} |

## Verificação (saídas reais)

### Lint
```
{saída do linter da stack — ex.: ruff, eslint}
```
### Type-check
```
{saída — ex.: mypy, tsc}
```
### Testes
```
{saída — ex.: pytest, vitest: N passed / N failed}
```

## Verificação dos Acceptance Tests

| ID | Resultado | Evidência |
|----|-----------|-----------|
| AT-001 | ✅/❌ | {teste/log que prova} |
| AT-002 | ✅/❌ | {…} |

## Não exercitado (mapa de cobertura, obrigatória)

> O que o código **aceita** e você **não executou**: entrada, formato, encoding, ambiente, caminho
> de erro. Não é confissão de preguiça — é o mapa que dirige quem revisa depois, e é a peça mais
> barata do ciclo (dezenas de tokens). Medido quatro vezes nas rodadas 5 e 6 do baseline: **todos**
> os checks que a revisão comprou estavam declarados aqui antes de alguém procurar.

| Superfície não exercitada | Por que ficou de fora |
|---|---|
| {ex.: delimitador diferente de vírgula; arquivo em UTF-16; flag desconhecida} | {sem carga; fora dos AT; ambiente indisponível} |

> **Nada ficou de fora?** Substitua a tabela por uma linha `Nenhuma — {o que sustenta}`. A afirmação
> é forte: diz que toda entrada que o código aceita foi executada. **Não deixe em branco nem apague
> a seção** — o `sdd-lint` reprova a ausência (`build-report-sem-mapa`) e a seção só com o
> placeholder do template (`build-report-mapa-vazio`), pela mesma razão do "N/A" declarado logo
> abaixo: *não se aplica* e *não foi feito* não podem ficar iguais no papel.

## Verificação por mutação (obrigatória quando há comportamento executável)

> Um teste que **passa com o defeito reintroduzido** não cobre nada. Para cada correção/comportamento
> novo: desligue o fix, mostre **qual** teste reprova, restaure. Nome do teste, não "a suíte falhou".

| Comportamento | Como o defeito foi reintroduzido | Teste que reprovou | Restaurado |
|---|---|---|---|
| {o que o fix garante} | {a linha/condição desligada} | `{nome exato do teste}` | ✅ |

**Suíte após restaurar:** {N passed / 0 failed}

> **Sem comportamento executável?** (só redação, doc, template, prosa de rule/command) — escreva
> **"N/A — mudança sem comportamento executável"** e diga o que a torna verificável no lugar
> (ex.: revisão humana). **Não** deixe a seção em branco nem a apague: o "N/A" declarado é a
> diferença entre *não se aplica* e *não foi feito*.
>
> **Mas o "N/A" cai no instante em que existe um teste ou lint que LÊ esse texto** — e aí a mutação
> é **no texto**, não no código: apague a linha que o teste guarda e mostre qual teste reprova.
> Um assert sobre documentação é um instrumento como outro qualquer, e instrumento que ninguém
> exercita não acusa nada. Dois deles ficaram verdes neste repositório casando com prosa de outra
> parte do mesmo arquivo — um padrão sem endereço afirma sobre o arquivo inteiro, e num arquivo
> grande quase tudo casa em algum lugar.

## Revisão de repertório (quando houve revisor fresh-context)

> Cole a resposta do revisor **como ela veio**, com os IDs de
> [`../../checklists/review-repertoire.md`](../../checklists/review-repertoire.md). É o único lugar
> onde a atribuição *item → achado* fica no repositório — e é dela que sai o `grep` da §*Quando um
> item sai*, o critério que aposenta item que parou de comprar achado.

```text
[ok]    IO-01  {item}  -> {evidência da execução}
[FALHA] CT-02  {item}  -> {modo de falha + repro}
[n/v]   EC-03  {item}  -> {razão de uma linha}
```

**Achados fora do checklist** (`[FALHA] —`): {liste, ou "Nenhum"} — cada um é candidato a **virar
item novo** no checklist do projeto.

> **Sem revisor nesta feature?** (regime `solo` — ver `rules/orchestration.md`) — escreva
> **"N/A — regime `solo`, sem revisor"**. Não apague a seção: um projeto onde ela nunca aparece é um
> projeto onde o checklist nunca poderá ser podado, e isso é informação.

## Desvios do design
{o que mudou em relação ao DESIGN e por quê — ou "Nenhum"}

## Issues e blockers
{problemas encontrados; bloqueios pendentes — ou "Nenhum"}

## Status final

**Geral:** {✅ COMPLETE / 🔄 IN PROGRESS / ❌ BLOCKED}

---

**Próximo passo (quando ✅):** `/ship <FEATURE>`
