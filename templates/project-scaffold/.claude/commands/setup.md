---
description: Inicializa o projeto — wizard que preenche project-context.md
argument-hint: "[nome do projeto opcional]"
---

# /setup — Inicialização do projeto

Você vai configurar este projeto preenchendo `.claude/rules/project-context.md`.

## Passos

1. **Leia o estado atual** de `.claude/rules/project-context.md`. Se já estiver
   `status: active`, confirme com o usuário se quer reconfigurar antes de prosseguir.
2. **Explore o repositório** (estrutura, arquivos de manifesto como `pyproject.toml`,
   `package.json`, `dbt_project.yml`, `requirements.txt`; commits recentes) para inferir
   stack e domínio — assim você pergunta menos.
3. **Pergunte o que faltar**, uma coisa de cada vez, preferindo múltipla escolha:
   - Nome e domínio do projeto
   - Stack (linguagem, runtime/framework, dados, infra/CI)
   - Convenções (lint, testes, versionamento)
   Use `$ARGUMENTS` como nome do projeto se fornecido.
4. **Preencha** `.claude/rules/project-context.md` com os valores reais e troque o
   marcador para `<!-- status: active -->`.
5. **Aponte a área de trabalho.** Deixe explícito (sem criar nada à força):
   - A **raiz do projeto é o workspace** — código, dados e docs vão na estrutura que a
     stack capturada pedir (ex.: Python+dbt → `src/ tests/ models/`). É **derivado da
     stack**, não fixo. Se o usuário quiser, **ofereça criar** essas pastas (nunca-destrutivo,
     sob aprovação) — não imponha.
   - O que **chega de fora** (specs, planilhas, solicitações) vai em **`inbox/`**; os
     artefatos SDD gerados vão em `.claude/sdd/`. Ver `inbox/_ABOUT.md`.
6. **Confirme** o resultado com o usuário e aponte o próximo passo:
   `/brainstorm` (feature nova) ou `/dev` (tarefa pequena).

## Regras

- Não invente stack — confirme o que inferiu antes de gravar.
- Mantenha o arquivo conciso; detalhes profundos vão para a KB (`.claude/kb/`).
- **Não crie estrutura de trabalho sem aprovação** — a raiz é workspace livre; sugerir
  layout derivado da stack é ok, impor não.
