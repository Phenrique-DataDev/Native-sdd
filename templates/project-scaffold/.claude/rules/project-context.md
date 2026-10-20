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

## Verificação

Comandos que provam que o projeto está verde, confirmados rodando. `/dev`, `/build`, `/iterate`, o
gate do `/orchestrate` e o CI usam estes, não deduzem outros. Sem a etapa, `—`.

| Etapa | Comando |
|-------|---------|
| install | `<comando ou —>` |
| lint | `<comando ou —>` |
| test | `<comando>` |

---

## Como os agentes usam este arquivo

- `status: template` → projeto não configurado: instruir o usuário a rodar `/setup` antes de executar trabalho.
- `status: active` → ler como **fonte de verdade** de stack, domínio e convenções.
