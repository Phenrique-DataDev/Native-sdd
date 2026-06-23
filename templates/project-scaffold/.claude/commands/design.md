---
description: "Fase 2 SDD — arquitetura e spec técnica"
argument-hint: "<caminho do DEFINE>"
---

# /design — Fase 2 (Design)

Desenhar **como** construir o que o DEFINE pediu.

## Antes de começar
- Leia o DEFINE em `$ARGUMENTS` e o template `.claude/sdd/templates/DESIGN_TEMPLATE.md`.
- Confirme que o DEFINE atingiu Clarity Score ≥ 12/15. Se não, volte para `/define`.
- **Aterre o design na KB curada** (passo abaixo) e nos padrões existentes no código.

## Aterrar na KB (grounding)

Quando a KB já foi treinada (`/train-kb`), o design **não improvisa** nomes/contratos: ancora-se nos
**schemas/IDs reais** (`implementation/`) e **runbooks** (`operations/`) do domínio. Passo:

1. **Domínios** — leia o campo **"Domínios de KB"** do DEFINE (seção *Contexto técnico*). Sem domínios
   declarados → registre "domínios não declarados no DEFINE" e siga (não adivinhe a KB inteira).
2. **Inventário** — resolva `$toolsRoot` pela cascata da [`tooling.md`](../rules/tooling.md) e leia a KB:
   ```powershell
   # cascata tooling.md: relativo → $env:SDD_WORKFLOW_HOME → degradação consciente
   $toolsRoot =
     if     (Test-Path 'tools' -PathType Container) { 'tools' }
     elseif ($env:SDD_WORKFLOW_HOME -and (Test-Path (Join-Path $env:SDD_WORKFLOW_HOME 'tools') -PathType Container)) { Join-Path $env:SDD_WORKFLOW_HOME 'tools' }
     else   { $null }
   if ($toolsRoot) {
       . "$toolsRoot/kb-lint.ps1"
       $kb = @(Get-KbInventory -Dir .claude/kb | Where-Object Valid)
   } else {
       Write-Warning 'camada tools/ indisponivel — leia .claude/kb/ à mão (degradação, ver rules/tooling.md)'
   }
   ```
3. **Pré-condição (KB treinada?)** — se `$kb` está **vazio** (KB não treinada): **no-op gracioso** — preencha
   a seção do template com a nota "KB não treinada (rode `/train-kb`)" e **siga o design normalmente**.
   **Nunca** bloqueie o design por isso.
4. **Filtrar** — das entradas, use por **default** as camadas `implementation` + `operations` cujos
   `Domain` ∈ domínios do DEFINE; inclua `business`/`tools` **só** se o design for desse tipo.
5. **Ler e ancorar** — leia o conteúdo das entradas (pelo `Path`) e ancore arquitetura/componentes/
   integration points nos nomes/IDs/contratos **reais** delas.
6. **Registrar** — preencha a seção **"Conhecimento da KB consultado"** do DESIGN com as entradas citadas.

> Leitura **local** da KB já curada — **não** aciona context7/rede (isso é o `docs-first`, para popular
> `tools/`). `Get-KbInventory` é read-only.

## Produza
Gere `.claude/sdd/features/DESIGN_<FEATURE>.md` com:
- **Arquitetura** (diagrama Mermaid e/ou ASCII de componentes e fluxo de dados)
- **Componentes** (responsabilidade + tecnologia)
- **Data Flow** e **Integration Points**
- **Testing Strategy** (que testes provam os Acceptance Tests do DEFINE)
- **Error Handling**, **Security**, **Observability**
- **Conhecimento da KB consultado** (entradas que ancoraram o design — do passo *Aterrar na KB*)
- **Localização do código** (onde os arquivos vão morar) e impacto de infra/IaC

## Regras
- Respeite as Constraints do DEFINE.
- Cada Success Criterion deve ter um caminho claro de verificação no design.
- Aplique YAGNI: o design mais simples que satisfaz os requisitos.

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`):
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase design -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

**Próximo passo:** `/build .claude/sdd/features/DESIGN_<FEATURE>.md`
