# Docs-first — doc atual antes da memória (context7 → web → unverified)

> **Otimização.** Ao documentar uma **lib/framework/SDK/CLI versionável** (camada `tools/`
> da KB), consulte a **documentação atual via context7** em vez de confiar na memória do
> modelo. Sintaxe e flags mudam entre versões; a doc corrente garante comandos funcionais.
> Sem context7 (ou lib não resolvida), **escale para `WebSearch`/`WebFetch`** antes de
> desistir — mesma escada de custo crescente do [`external-observer`](../agents/external-observer.md)
> (context7 → `WebFetch` → browser). Só cai em `unverified` se **as duas** fontes falharem.

## Princípio

Antes de escrever conhecimento sobre uma **tecnologia versionável**, pergunte: *"a doc atual
confirma esta sintaxe/flag?"*. Se o MCP **context7** estiver disponível, **prefira-o** à
memória — e **registre a proveniência** na entrada.

## Quando aplica

| Tarefa | Fonte preferida | Em vez de |
|--------|-----------------|-----------|
| Documentar lib/framework/CLI versionável (dbt, pandas, ClickHouse, Terraform…) | **context7** (`resolve-library-id` → `query-docs`) | memória do modelo (possivelmente desatualizada) |
| Conceito agnóstico, sem fornecedor/versão (window functions, modelagem dimensional, idempotência) | conhecimento estável | — (não aciona context7; sem `lib_id`) |
| Regra de negócio, schema interno, runbook (camadas `business`/`implementation`/`operations`) | contexto do projeto | — (context7 não se aplica) |

## Como aplicar

1. **Verifique o MCP:** se `mcp__context7__*` não estiver disponível, vá direto ao passo 5 (fallback web).
2. **Resolva a lib:** `mcp__context7__resolve-library-id` (nome → `lib_id`).
3. **Puxe a doc:** `mcp__context7__query-docs` e extraia a sintaxe/flags **atuais**.
4. **Grave a proveniência** no frontmatter da entrada:
   ```yaml
   source: context7
   lib_id: <id resolvido>
   checked_at: YYYY-MM-DD
   ```
   Sucesso aqui **encerra o ciclo** — não passe pelos passos 5/6.
5. **Fallback web (só se o passo 1 faltou ou o passo 2 não resolveu):** tente `WebSearch`
   (achar a doc oficial) e/ou `WebFetch` (puxar o conteúdo da página oficial/changelog da
   versão). Achou a sintaxe/flag atual numa fonte oficial/confiável? Grave a proveniência:
   ```yaml
   source: web
   url: <URL da doc consultada>
   checked_at: YYYY-MM-DD
   ```
   Isso **não** é `unverified` — é verificado, só que por uma fonte diferente de context7.
6. **Degradação graciosa (as duas fontes falharam):** gere a entrada mesmo assim com
   `status: unverified` e **avise** o usuário — nunca finja que verificou.

## O que NÃO fazer

- Não documentar flags/sintaxe **de memória** para uma lib versionável sem marcar `unverified`.
- Não acionar context7 (nem o fallback web) para conceito agnóstico (sem fornecedor) — desperdício,
  e não há `lib_id`/URL de versão para ancorar.
- Não pular direto para `unverified` sem tentar o fallback web — o `unverified` é o **último**
  recurso, não o segundo passo.
- Não **quebrar** quando o MCP faltar — context7 é opcional; o fallback web (e, por fim, a
  degradação) é o caminho normal.
