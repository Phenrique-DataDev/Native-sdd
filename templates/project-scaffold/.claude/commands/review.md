---
description: "Revisar um PR ou o diff atual em busca de bugs e melhorias"
argument-hint: "[número do PR ou vazio p/ diff local]"
---

# /review — Revisão de código

Revisar `$ARGUMENTS` (um PR) ou, se vazio, o **diff atual** da branch contra a base.

## Processo
1. Obtenha o diff: `git diff` (local) ou o PR indicado (`gh pr diff <n>` se disponível).
2. Leia `project-context.md` e os arquivos tocados para ter contexto.
3. Avalie, em ordem de prioridade:
   - **Correção** — bugs, edge cases, erros de lógica, concorrência, dados.
   - **Segurança** — input não validado, segredos, injeção.
   - **Aderência** — bate com o DESIGN/DEFINE e as convenções do projeto?
   - **Simplicidade/reuso** — duplicação, código morto, complexidade desnecessária.
   - **Testes** — cobrem os Acceptance Tests? Faltou caso?
4. Verifique afirmações rodando lint/testes quando fizer sentido.

## Saída
Liste achados por severidade (🔴 bloqueante / 🟡 sugerido / 🟢 nit), cada um com
arquivo:linha e a correção proposta. Seja específico e acionável; sem elogios vazios.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "O código parece certo, aprovo sem rodar nada" | "Parece" não é prova. Rode lint/testes quando a afirmação for verificável. |
| "Achei um bug mas é pequeno, deixo passar" | Severidade ≠ existência. Marque (🟢 nit / 🟡 sugerido / 🔴 bloqueante) e deixe o autor decidir. |
| "Elogio o PR pra não travar o merge" | Elogio vazio não é revisão. Achado acionável com arquivo:linha é. |

## O que NÃO fazer

- Aprovar afirmando que testes passam sem ter rodado.
- Omitir um achado por ser "pequeno" — registre com a severidade certa.
- Devolver elogio genérico no lugar de achado acionável.
