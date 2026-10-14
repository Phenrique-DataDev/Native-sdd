---
description: "Dev Loop — tarefa pequena sem o ciclo SDD completo"
argument-hint: "<descrição da tarefa>"
---

# /dev — Dev Loop

Atalho para tarefas pequenas: utilitários, scripts de um arquivo, ajustes, protótipos.
Use quando o SDD de 5 fases seria peso demais.

## Quando NÃO usar
Se a tarefa envolve várias partes, decisões de arquitetura ou requisitos ambíguos,
prefira o SDD: comece por `/brainstorm` ou `/define`.

## Processo
1. Confirme o objetivo de `$ARGUMENTS` em 1 frase e os critérios de "pronto".
2. Leia `project-context.md` para respeitar stack e convenções.
3. Implemente de forma enxuta, em branch de trabalho.
4. **Verifique:** rode lint/testes pertinentes; mostre a saída real.
5. Resuma o que mudou e os arquivos afetados.

## Regras
- Sem cerimônia de artefatos SDD — mas a mesma disciplina de verificação.
- Conventional Commits; não tocar `main` sem confirmação.
