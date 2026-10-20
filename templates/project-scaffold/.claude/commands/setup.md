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
3. **Pergunte o que faltar.** **Predicado:** se o passo 1 encontrou `status: template` — o
   contexto que todo o resto consome ainda não existe —, carregue a skill
   [`grill-me`](../skills/grill-me/SKILL.md) (tool `Skill`) e levante o que falta em rodadas, com
   recomendação em cada pergunta. Reconfiguração de projeto já `status: active` pode ir direto ao
   ponto que o usuário quer mudar. Cubra:
   - Nome e domínio do projeto
   - Stack (linguagem, runtime/framework, dados, infra/CI)
   - Convenções (lint, testes, versionamento)
   - **Comandos de verificação** — o que se digita para instalar dependências, rodar o lint e rodar
     os testes. Proponha a partir da stack inferida; o usuário confirma ou corrige. Projeto ainda sem
     teste nenhum: diga que `/dev`, `/build` e `/iterate` ficarão sem sinal verde/vermelho, e grave
     `—` só se ele confirmar.
   - **Convenção que vale só para uma parte do projeto** (uma pasta, um tipo de arquivo)? Se houver,
     ela **não** vai para o `project-context.md`, que é always-on e vale para tudo. Leia
     [`postures/path-rules.md`](../postures/path-rules.md) e ofereça gravá-la como rule de área
     (`.claude/rules/area-<slug>.md` com `paths:`).
   Use `$ARGUMENTS` como nome do projeto se fornecido. O que o passo 2 já inferiu do repositório
   **não se pergunta** — confirma-se.
4. **Preencha** `.claude/rules/project-context.md` com os valores reais e troque o
   marcador para `<!-- status: active -->`. Na seção **`## Verificação`**, grave só comando que você
   **rodou aqui** e mostrou a saída (install primeiro, depois lint e teste): comando que não passa
   local não é verificação, é palpite. Um comando por célula, entre crases; sem a etapa, `—`.
5. **Aponte a área de trabalho.** Deixe explícito (sem criar nada à força):
   - A **raiz do projeto é o workspace** — código, dados e docs vão na estrutura que a
     stack capturada pedir (ex.: Python+dbt → `src/ tests/ models/`). É **derivado da
     stack**, não fixo. Se o usuário quiser, **ofereça criar** essas pastas (nunca-destrutivo,
     sob aprovação) — não imponha.
   - O que **chega de fora** (specs, planilhas, solicitações) vai em **`inbox/`**; os
     artefatos SDD gerados vão em `.claude/sdd/`. Ver `inbox/_ABOUT.md`.
6. **Ofereça o CI (opt-in), só onde ele faz sentido.** Sem CI, o "verde" do agente só existe na
   máquina dele. Antes de oferecer, resolva `$toolsRoot` pela cascata de
   [`rules/tooling.md`](../rules/tooling.md) e meça:

   ```powershell
   . "$toolsRoot/ci-workflow.ps1"
   $ci = Test-CiOfferApplicable -Root .   # Offer · Reasons · Tech · Caveats
   ```

   - **`Offer` falso → não ofereça.** Diga em uma linha o motivo (`Reasons`: sem remote no GitHub, já
     tem CI, monorepo, stack que precisa de credencial) e siga para o passo 7.
   - **`Offer` verdadeiro →** leia os `Caveats` (ex.: Docker: pergunte se os testes sobem serviço; se
     sim, não ofereça) e pergunte (`AskUserQuestion`) se o usuário quer um workflow do GitHub Actions
     que rode no push e no PR os mesmos comandos de verificação; diga que ele consome minutos do
     Actions da conta. Pergunte também se o projeto só roda no Windows (`-Runner windows-2025`). Sem
     resposta, siga sem criar nada. Com **"não"**, grave `.claude/ci-offer-declined` (uma linha com
     a data): é o que impede o hook `curation-nudge` de reoferecer a cada sessão.
   - **Quando o projeto ainda não tem remote,** a oferta volta sozinha: depois do primeiro push ao
     GitHub, o `curation-nudge` avisa no início da sessão, e você roda **só este passo**.
   - **Os comandos são os da `## Verificação`** (passo 4, já rodados). Sem teste declarado lá, não
     há o que o CI rode: não ofereça.
   - **Gere e grave:**

     ```powershell
     . "$toolsRoot/verification.ps1"
     $v = Get-ProjectVerification -Root .   # Install · Lint · Test · Declared
     $yaml = New-CiWorkflowYaml -TestCommand $v.Test -LintCommand $v.Lint -InstallCommand $v.Install `
                                -Tech $ci.Tech -DefaultBranch '<branch default>'   # -Runner windows-2025 se Windows-only
     Install-CiWorkflow -Root . -Content $yaml   # recusa, com o motivo, se já houver workflow
     ```

     Mostre o arquivo gerado. Stack fora de python/dbt, node e go não ganha step de setup do
     runtime: diga isso ao usuário, que acrescenta o setup à mão. Sem `$toolsRoot`, não escreva o
     YAML de memória: avise e registre a lacuna.
7. **Confirme** o resultado com o usuário e aponte o próximo passo:
   `/brainstorm` (feature nova) ou `/dev` (tarefa pequena).

## Regras

- Não invente stack — confirme o que inferiu antes de gravar.
- Mantenha o arquivo conciso; detalhes profundos vão para a KB (`.claude/kb/`).
- **Não crie estrutura de trabalho sem aprovação** — a raiz é workspace livre; sugerir
  layout derivado da stack é ok, impor não.
