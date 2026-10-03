# Backlog

> Fila de trabalho **do projeto**: o que está identificado e ainda não foi feito. Toda entrada passa
> pelo **critério de entrada** abaixo antes de virar trabalho — e nenhum item sai daqui apagado.
>
> Prioridade: 🔴 alta · 🟡 média · 🟢 baixa. Última revisão: `<data>`.

## O que NÃO é

| Não confundir com | Onde vive |
|-------------------|-----------|
| Débito de **uma feature específica** (o que ficou de fora dela) | pendências do `BUILD_REPORT_<FEATURE>.md` daquela feature |
| Insumo que **chegou de fora** e ainda não foi triado | `inbox/` |
| Fase SDD **em andamento** | `.claude/sdd/features/` — veja no `/status` |
| Doc de código, ADR, runbook, registro de acontecimento | `docs/` (ver `docs/_ABOUT.md`) |

## Critério de entrada — as 3 perguntas

Um item só entra no **Aberto** se as três têm resposta escrita **dentro dele**. Sem as três, ele
fica no `inbox/` até alguém respondê-las — não vira item por otimismo.

| # | Pergunta | Por que ela existe |
|---|----------|--------------------|
| **1. Dor observada** | Que **uso real** doeu? (sessão, log, relato, erro) | Item sem dor é hipótese. Um backlog vazio é um resultado, não um problema a resolver — não invente item para preenchê-lo. |
| **2. Causa conferida** | O que o **código** diz que causa isso? | O relato é evidência forte de *que* dói e fraca sobre *por quê*. Se a causa que veio junto não sobreviver à leitura do código, o item vira **correção do registro**, não implementação. |
| **3. Pronto verificável** | O que **reprova** se isso não for feito? (teste, lint, gate, medição) | Sem mecanismo, "pronto" é opinião — e a regra que ninguém cobra não existe na prática. |

> **Prioridade não é urgência sentida** — é o tamanho da dor de (1) dividido pelo custo. Um item 🔴
> sem (1) respondida é só um item ansioso.

## Aberto

<!-- Formato: - [ ] <prioridade> **Título curto.** Dor observada · causa conferida (arquivo/linha) ·
     o que reprova sem o fix. Uma linha em branco entre itens. -->

- [ ] 🟡 **`<título do item>`** — `<dor observada: o que aconteceu, quando>`;
  **causa conferida:** `<o que o código diz — arquivo/linha>`;
  **pronto:** `<o teste/lint/medição que reprova sem isto>`.

## Decidido: NÃO fazer

Decisão de não fazer é uma decisão — e envelhece como qualquer outra. Registre **o porquê** e, junto,
o **gatilho de reabertura**: o fato observável que faria isto voltar à fila. Sem o gatilho, a decisão
vira dogma; com ele, vira uma aposta que pode ser conferida depois.

- [x] ~~🟢 **`<título>`**~~ — **não fazer** porque `<a medição/razão, com número quando houver>`.
  **Reabre se:** `<o fato observável que muda o veredito>`.

## Concluído

Item fechado fica aqui **riscado, com o que a medição disse** — não apagado. O valor do registro é
justamente o caso em que a premissa caiu: quem vier depois precisa ver que já se tentou, e o que se
aprendeu.

- [x] ~~🟡 **`<título>`**~~ — `<o que foi feito e o que a verificação mostrou>`. *(`<data>`)*
