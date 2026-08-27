---
description: "Fase 3 SDD — implementar conforme o design + relatório de build"
argument-hint: "<caminho do DESIGN>"
---

# /build — Fase 3 (Build)

Implementar o que o DESIGN especifica e registrar o resultado.

## Antes de começar
- Leia o DESIGN em `$ARGUMENTS` e o DEFINE referenciado.
- Leia o template `.claude/sdd/templates/BUILD_REPORT_TEMPLATE.md`. A seção `## Não exercitado`
  dele é **obrigatória** e o `sdd-lint` reprova a ausência (`build-report-sem-mapa`) e o placeholder
  por preencher (`build-report-mapa-vazio`) — ver "Saída" abaixo.
- Trabalhe em **branch de feature** (não na `main`).

## Execução
1. Quebre o DESIGN em tarefas pequenas e verificáveis (use a lista de tarefas).
2. Implemente seguindo a stack e convenções de `project-context.md`.
3. **Verifique de verdade** a cada parte: lint, type-check e testes da stack do projeto.
   Não marque como pronto com testes falhando.
4. Cubra os **Acceptance Tests** do DEFINE.
5. **Prove o teste por mutação** — a suíte verde não prova cobertura, só ausência de falha:
   1. **Desligue o fix** (reintroduza o defeito: reverta a linha, inverta a condição, remova a chamada).
   2. **Rode a suíte e anote qual teste reprova — pelo nome.** Nenhum reprovou? O teste não cobre o
      comportamento: **conserte o teste antes de seguir**, não o registre como coberto.
   3. **Restaure o fix** e confirme a suíte verde de novo.
   4. Registre as três coisas na seção **Verificação por mutação** do BUILD_REPORT.

   Reverta a mutação com **cópia do arquivo**, nunca com `git checkout` — o checkout leva junto
   qualquer trabalho não commitado.

## Delegar trabalho mecânico a uma sessão headless (`claude -p`) — opt-in

Parte do BUILD é **mecânica e verificável por máquina**: ler o log de uma suíte que reprovou por
ambiente, varrer o repositório atrás de todos os call-sites de algo, diagnosticar uma matriz de
plataformas. Fazer isso na sessão interativa **gasta o contexto que o DESIGN precisa** — e o
resultado é conferível sozinho (o teste volta verde ou não). Nesses casos, delegue a uma sessão
**headless**:

```bash
# o prompt entra por stdin; --allowedTools restringe a superfície da sessão headless
"<prompt do diagnóstico>" | claude -p --allowedTools 'Bash,Read,Edit,Grep'
```

**Sempre com toolset restrito.** `--allowedTools` é o que separa *delegar um diagnóstico* de *abrir
uma sessão sem guarda*: dê só o que a tarefa exige. O exemplo acima (`Bash,Read,Edit,Grep`) é o de
uma correção de scripts existentes — **sem `Write`** (não é para criar arquivo novo) e **sem
`WebFetch`** (o diagnóstico é do repositório, não da internet). Outra tarefa, outro toolset.

**É opt-in, e o trade-off é explícito:** consome tokens numa sessão que você não vê acontecer, e o
agente headless **edita arquivos** — só delegue trabalho reversível, dentro do repositório, com o
resultado verificável depois (suíte, lint, `git diff`). Anuncie ao usuário antes de disparar.

| Delegue | Não delegue |
|---------|-------------|
| Diagnóstico de falha de suíte/ambiente, varredura ampla, fix mecânico guiado por erro | Decisão de design, escolha de arquitetura, qualquer coisa que o DESIGN não fixou |
| Trabalho cujo sucesso uma máquina confere (teste, lint, type-check) | Trabalho cujo veredito é julgamento — e a fase de mutação, que é sua |
| Mudança local e reversível | **Outward**: `git push`, PR, release, deploy |

> Distinto do [`/iterate`](iterate.md): lá o laço é **bounded, em sandbox**, martelando uma meta até
> o verde; aqui é **uma** sessão não-interativa, disparada por você, para um trabalho pontual.
> Registre no BUILD_REPORT o que foi delegado e o que voltou — resultado de sessão headless entra
> como qualquer outro: com a saída real, nunca como "o agente disse que passou".

## Saída
Gere `.claude/sdd/reports/BUILD_REPORT_<FEATURE>.md` com:
- Resumo, arquivos criados/alterados
- Resultados de verificação (lint / type-check / testes — saídas reais)
- Desvios do design e o porquê, issues e blockers
- Verificação dos Acceptance Tests
- **Não exercitado** (mapa de cobertura) — o que o código aceita e você não rodou, ou
  `Nenhuma — <o que sustenta>`. **Obrigatória**, com backstop no `sdd-lint`
  (`build-report-sem-mapa` / `build-report-mapa-vazio`) — é dela que a revisão parte
- **Verificação por mutação** (qual defeito foi reintroduzido, qual teste reprovou, suíte restaurada)
  — ou `N/A` **declarado**, quando a mudança não tem comportamento executável
- Status final: ✅ COMPLETE / 🔄 IN PROGRESS / ❌ BLOCKED

## Regras
- Relate falhas honestamente (mostre a saída). Não fabrique resultados de teste.
- **Teste que passa com o defeito reintroduzido não conta** — é decoração, não cobertura.
- Commits seguem Conventional Commits; push livre na branch de trabalho.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "Os testes estão quase passando, marco como ✅" | "Quase" é ❌. O status reflete a saída real do lint/teste, não a expectativa. |
| "Escrevo os testes depois de entregar" | Sem teste, o Acceptance Test do DEFINE não foi coberto — a fase não fechou. |
| "Esse desvio do DESIGN é óbvio, não preciso registrar" | O BUILD_REPORT registra desvio + porquê para quem vier depois. Óbvio hoje ≠ óbvio em 3 meses. |
| "Declarar o que não exercitei parece confissão de trabalho malfeito" | É o oposto: é a peça mais barata do ciclo e a que mais dirige a revisão. Nas rodadas 5 e 6, **todo** defeito que a revisão comprou estava numa superfície declarada ali — quem não declara não esconde o buraco, só o deixa sem quem procure. |
| "A suíte está verde, o teste obviamente cobre" | Verde prova que nada falhou, **não** que algo foi exercitado. Um `-ForEach` mal formado gera **zero** casos e passa igual. Só a mutação distingue. |
| "Escrevi o teste olhando o fix, então ele cobre" | Teste escrito a partir do fix tende a afirmar o que o código faz, não o que ele **deve** fazer — inclusive quando o contrato está errado. Desligue e veja reprovar. |
| "Desligar o fix pra testar é perda de tempo" | São segundos. As duas mordidas conhecidas (teste com zero casos; teste que ratificava o default errado) passaram por revisão humana e só a mutação pegou. |
| "Reprovou alguma coisa na suíte, deve ser esse teste" | Anote o **nome**. "Algo reprovou" não distingue o seu teste de um efeito colateral em outro arquivo. |

## O que NÃO fazer

- Marcar ✅ com lint/teste falhando ou sem rodar.
- Fabricar resultado de teste — mostre a saída real.
- Implementar fora do DESIGN sem registrar o desvio + porquê.
- Declarar um comportamento coberto **sem** ter visto um teste reprovar com o defeito reintroduzido.
- Disparar `claude -p` **sem** `--allowedTools`, ou delegar a ela decisão de design/ação outward.
- Deixar a seção **Verificação por mutação** em branco ou apagá-la — se não se aplica, escreva o
  `N/A` e o porquê. Seção ausente lê como "não foi feito", e é indistinguível disso.

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`).
Aqui `n` é o **sinal mais forte**: nº de re-rodadas até o lint/testes/critérios passarem.
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase build -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

**Próximo passo (quando ✅):** `/ship <FEATURE>`
