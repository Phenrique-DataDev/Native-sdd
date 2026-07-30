# docs/ — Documentação do projeto (humano × LLM)

> Onde mora a documentação que **não entra na KB e nem deveria**: doc de código/módulos, ADR,
> runbook/onboarding, **registros de acontecimentos** (append-only) e referência/notas. É para **humano
> e LLM** — markdown que a pessoa lê e o agente carrega sob demanda (sem custar o orçamento da KB, que é
> sempre-on). Produzida pelo subagent `documenter` (proativo) ou pelo comando `/document`.

## Para que serve

- **Doc de código:** como módulos/partes funcionam, referência derivada do código real, ADRs (decisões).
- **Acontecimentos:** o que mudou/ocorreu — entradas **datadas, append-only** (histórico imutável).
- **Runbook / onboarding:** como rodar, operar e retomar o projeto.
- **Referência / notas:** material humano×LLM longo que não cabe na KB.

## O que NÃO é

| Não confundir com | Onde isso vive |
|-------------------|----------------|
| Conhecimento **curado e agente-facing** do domínio | `.claude/kb/` (via `/train-kb`) |
| Insumo que **chega de fora** (specs, planilhas, solicitações) | `inbox/` |
| Artefatos SDD gerados (BRAINSTORM/DEFINE/DESIGN/BUILD/SHIPPED) | `.claude/sdd/` |
| Documentação viva e **fixa** do projeto (sem changelog) | `README.md` (raiz) |

## Convenção

`docs/_index.md` é **gerado por `/sync-context`** (não editar à mão). A disciplina de escrita —
**proativa, append-only para registros, pontual e nunca-destrutiva para doc de código** — está em
`.claude/rules/documentation.md`. Nunca se escreve na KB a partir daqui.
