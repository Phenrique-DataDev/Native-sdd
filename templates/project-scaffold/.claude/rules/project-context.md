<!-- status: template -->

# Contexto do projeto

> **Este arquivo ainda não foi preenchido.** Rode **`/setup`** para o wizard de
> configuração — ele faz as perguntas certas e preenche este arquivo automaticamente.
> Enquanto o marcador acima for `status: template`, o projeto está **não inicializado**.

---

## Identidade

| Campo | Valor |
|-------|-------|
| Nome do projeto | `<NOME>` |
| Domínio | `<DOMÍNIO>` |
| Repositório | `<URL ou caminho>` |

## Stack

| Camada | Tecnologia | Notas |
|--------|------------|-------|
| Linguagem principal | `<ex.: Python, SQL, TypeScript>` | |
| Runtime / framework | `<ex.: Python 3.12, FastAPI, dbt>` | |
| Dados | `<ex.: ClickHouse, BigQuery, PostgreSQL>` | |
| Infra / CI | `<ex.: GitHub Actions, Docker>` | |

## Convenções de código

- Estilo / lint: `<ferramenta>`
- Testes: `<framework>`
- Versionamento: `<SemVer, Conventional Commits?>`

---

## Como os agentes usam este arquivo

- `status: template` → avisar que o projeto não foi configurado e sugerir `/setup`.
- `status: active` → ler como **fonte de verdade** de stack, domínio e convenções.

## Onde buscar mais contexto

| Necessidade | Local |
|-------------|-------|
| Contrato canônico de agentes | `AGENTS.md` (raiz) |
| Fases SDD | `.claude/rules/workflow-sdd.md` |
| CLI-first (otimização) | `.claude/rules/cli-first.md` |
| Roteamento de agentes | `.claude/rules/agent-routing.md` |
| Taxonomia da KB | `.claude/rules/kb-taxonomy.md` |
| Templates SDD | `.claude/sdd/templates/` |
