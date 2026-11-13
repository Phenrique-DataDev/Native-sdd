/**
 * DADOS DO GRAFO DE AGENTES — gerado, não editar à mão.
 *
 * Fonte de verdade (todos no repo, nada inventado):
 *   templates/project-scaffold/.claude/agents/graph.json   (nós + arestas, saída do tools/graph-export.ps1)
 *   templates/project-scaffold/.claude/agents/*.md         (frontmatter: tools, model)
 *   templates/project-scaffold/.claude/skills/<nome>/SKILL.md (description das skills vendorizadas)
 *   tools/supplements.psd1                                  (source/theme/reason das skills referenciadas)
 *
 * Regenerar: pwsh -NoProfile -File docs/tools/gen-graph-data.ps1
 * Carregado por <script defer> ANTES de graph.js (que consome window.__AGENT_GRAPH__).
 */
window.__AGENT_GRAPH__ ={
  "generatedAt": "2026-11-12",
  "source": "templates/project-scaffold/.claude/agents/graph.json + agents/*.md (frontmatter) + skills/<nome>/SKILL.md + tools/supplements.psd1",
  "nodes": [
    {
      "id": "code-reviewer",
      "type": "Agent",
      "role": "review",
      "description": "Revisor sênior de diff/PR: prioriza por risco (correção, concorrência, contrato, performance), lê os chamadores além do diff, sinal alto sem nit-bombing. Estilo fica com o linter e segurança profunda com o security-reviewer. Read-only.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "debugger",
      "type": "Agent",
      "role": "debug",
      "description": "Da falha à causa-raiz pelo método científico: reproduz primeiro, reduz o reprodutor, instrumenta e usa git bisect em regressão; trata flaky e concorrência. Use quando algo quebra ou um teste falha sem causa óbvia.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "designer",
      "type": "Agent",
      "role": "design",
      "description": "Cria e revisa UI/frontend em três modos: Refinar (UI existente), Fidelidade (reproduzir Figma/print) e Greenfield. Confere por screenshot (`visual-check`) ou declara que não rodou. Cobre acessibilidade, tokens, performance e motion.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash",
        "PowerShell",
        "Skill",
        "Artifact",
        "mcp__figma",
        "mcp__plugin_figma_figma",
        "mcp__claude_ai_Figma"
      ],
      "model": "inherit"
    },
    {
      "id": "documenter",
      "type": "Agent",
      "role": "documentation",
      "description": "Escrita técnica em `docs/` (fora da KB): Diátaxis, ADR, changelog derivado de Conventional Commits, runbook e diagramas Mermaid. Registros append-only datados, derivados do git/código; nunca inventa. Use para registrar o que mudou ou explicar como algo funciona.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "explorer",
      "type": "Agent",
      "role": "search",
      "description": "Explora codebase desconhecida e devolve um mapa conciso (entradas, como conecta, onde a mudança entra), seguindo o call graph e confirmando no trecho. Use para \"onde fica X\" antes de implementar. Read-only, sem Bash.",
      "tools": [
        "Read",
        "Grep",
        "Glob"
      ],
      "model": "inherit"
    },
    {
      "id": "external-observer",
      "type": "Agent",
      "role": "observation",
      "description": "Observador de caixa-preta: valida ou mapeia alvo externo/opaco (site, API, app rodando) por observação read-only (rede/HAR, headers de cache/CDN, OpenAPI), separando fato de hipótese e respeitando autorização. Nunca replica nem burla. Saída: relatório.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "PowerShell",
        "WebFetch",
        "mcp__context7__resolve-library-id",
        "mcp__context7__query-docs",
        "mcp__claude-in-chrome__navigate",
        "mcp__claude-in-chrome__read_page",
        "mcp__claude-in-chrome__read_network_requests",
        "mcp__claude-in-chrome__read_console_messages"
      ],
      "model": "inherit"
    },
    {
      "id": "git-workflow",
      "type": "Agent",
      "role": "vcs",
      "description": "Fluxo em volta do código: commits atômicos (Conventional Commits), PRs pequenos, rebase × merge, worktrees, CI vermelho (acha o job/step; a causa-raiz é do debugger) e GitHub Projects. Use ao preparar commit/PR, destravar CI ou revisar histórico. Roda git/gh.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "reverse-engineer",
      "type": "Agent",
      "role": "reverse-engineering",
      "description": "Engenharia reversa de artefato local opaco (binário nativo, Electron/ASAR, APK, .NET, firmware, HAR/pcap salvo), estática primeiro, com evidência (offset, símbolo, hash). Exige autorização; nunca burla DRM/licença nem executa o alvo sem OK. Saída: relatório clean-room.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "PowerShell",
        "WebFetch",
        "mcp__context7__resolve-library-id",
        "mcp__context7__query-docs"
      ],
      "model": "inherit"
    },
    {
      "id": "security-reviewer",
      "type": "Agent",
      "role": "security",
      "description": "Revisão de segurança em profundidade (AppSec) por fronteira de confiança: OWASP/ASVS, injeção/SSRF/IDOR, authn/authz, cripto, supply-chain, prompt injection em sistema com LLM, segredos no working-tree e no histórico git, audit de dependências. Read-only.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "test-writer",
      "type": "Agent",
      "role": "testing",
      "description": "Escreve/completa testes na stack do projeto: caminho feliz, bordas, falhas e os Acceptance Tests do DEFINE; testa contrato, determinismo anti-flaky, sem sobre-mock. Lê o setup do projeto, não inventa framework. Cria/edita testes e roda.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "tracker",
      "type": "Agent",
      "role": "tracking",
      "description": "Tráfego/traqueamento server-side: sGTM, dedup client×server por `event_id`, click-ids (fbclid/gclid) com fallback, PII com SHA-256, Enhanced Conversions, Consent Mode v2 e QA de runtime. Lê o setup do projeto, sem IDs fixos.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "validator",
      "type": "Agent",
      "role": "validation",
      "description": "Verifica se a entrega cumpre a spec e os Acceptance Tests do DEFINE: executa e observa o comportamento real, checa exit code, cobre caso negativo e fronteira, em ambiente reprodutível. Veredito cumpre/parcial/não-cumpre com evidência. Não conserta. Read-only.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "PowerShell"
      ],
      "model": "inherit"
    },
    {
      "id": "max",
      "type": "Hub",
      "role": "orchestrator-hub",
      "description": "Modo MAX — hub orquestrador-mestre do grafo de agentes (H7)"
    },
    {
      "id": "decision-preview",
      "type": "Skill",
      "role": "",
      "description": "Generate a single self-contained Artifact that compares 2-4 variants of an as-yet-undecided design choice side by side, grounded in real project data, and closes with an explicit choice question. Use when a decision has multiple viable options and getting it wrong after implementing would be costly to redo — a UI copy choice, a terminal/CLI output design, a schema layout, a component variant, an architecture option. Not for explaining or reviewing something already decided (use visual-explainer for that) or for a single mockup with no comparison (use artifact-design directly).",
      "scope": "project",
      "status": "valid",
      "argumentHint": "\"<a decisão + as variantes a comparar>\""
    },
    {
      "id": "gerador-de-manuais",
      "type": "Skill",
      "role": "",
      "description": "",
      "scope": "",
      "status": "referenced",
      "source": "gerador-de-manuais",
      "theme": "docs",
      "reason": "gera tutorial/manual de marca/guia de convenções a partir de template — referência do agente documenter",
      "supplementType": "skill"
    },
    {
      "id": "grill-me",
      "type": "Skill",
      "role": "",
      "description": "Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.",
      "scope": "project",
      "status": "valid",
      "argumentHint": "\"<o plano, decisão ou ideia a ser interrogado>\""
    },
    {
      "id": "handoff",
      "type": "Skill",
      "role": "",
      "description": "Compact the current conversation into a handoff document for another agent to pick up.",
      "scope": "project",
      "status": "valid",
      "argumentHint": "\"What will the next session be used for?\""
    },
    {
      "id": "impeccable",
      "type": "Skill",
      "role": "",
      "description": "",
      "scope": "",
      "status": "referenced",
      "source": "pbakaus/impeccable",
      "theme": "design",
      "reason": "design fluency / anti-patterns de UI (cache per-projeto em .impeccable/)",
      "supplementType": "plugin"
    },
    {
      "id": "page-to-markdown",
      "type": "Skill",
      "role": "",
      "description": "Fetch a web page and return clean, LLM-ready Markdown using only native tools — no external binary to install. Tries WebFetch first (built-in, zero setup); escalates to claude-in-chrome browser automation when the page needs real JS rendering or blocks simple fetches (anti-scraping/bot detection). Use whenever asked to convert a URL into Markdown, pull external reference content, or save a page for later reading. Not for library/framework documentation (use context7) or investigative black-box analysis (use the external-observer agent).",
      "scope": "project",
      "status": "valid",
      "argumentHint": "\"<url> [caminho de saída]\""
    },
    {
      "id": "security-guidance",
      "type": "Skill",
      "role": "",
      "description": "",
      "scope": "",
      "status": "referenced",
      "source": "anthropics/claude-plugins-official",
      "theme": "security",
      "reason": "review de segurança do código gerado: avisos por padrão + diagnóstico LLM (Anthropic). Ligado, roda hooks Python em SessionStart, UserPromptSubmit, Edit/Write, Stop e SubagentStop, monta um venv do Agent SDK na 1ª sessão (30-60 s, pede Python 3.8+) e a revisão LLM consome o plano ou a API. Para revisar o diff sob demanda, sem hook, o /security-review nativo basta",
      "supplementType": "plugin"
    },
    {
      "id": "ui-ux-pro-max",
      "type": "Skill",
      "role": "",
      "description": "",
      "scope": "",
      "status": "referenced",
      "source": "nextlevelbuilder/ui-ux-pro-max-skill",
      "theme": "design",
      "reason": "design system / UI (auto-ativa só em pedidos de design)",
      "supplementType": "plugin"
    },
    {
      "id": "visual-check",
      "type": "Skill",
      "role": "",
      "description": "Renderiza uma UI (página ou jogo Godot) em larguras comprovadas, lê o screenshot e confere contra a intenção ou uma fonte (Figma/print). Use antes de afirmar que um layout está certo — responsivo, fidelidade, anti-slop. Sem rota de captura calibrada, declara que não rodou.",
      "scope": "project",
      "status": "valid",
      "argumentHint": "\"<URL, arquivo HTML ou projeto Godot> [larguras] [fonte: link do Figma ou print]\""
    },
    {
      "id": "visual-explainer",
      "type": "Skill",
      "role": "",
      "description": "",
      "scope": "",
      "status": "referenced",
      "source": "nicobailon/visual-explainer",
      "theme": "reporting",
      "reason": "visualização de saída em HTML (diffs, planos, slides, relatórios)",
      "supplementType": "plugin"
    }
  ],
  "edges": [
    {
      "from": "code-reviewer",
      "to": "security-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "code-reviewer",
      "to": "test-writer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "debugger",
      "to": "explorer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "debugger",
      "to": "test-writer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "designer",
      "to": "code-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "designer",
      "to": "impeccable",
      "type": "USES_SKILL"
    },
    {
      "from": "designer",
      "to": "ui-ux-pro-max",
      "type": "USES_SKILL"
    },
    {
      "from": "designer",
      "to": "validator",
      "type": "CONNECTS_TO"
    },
    {
      "from": "designer",
      "to": "visual-check",
      "type": "USES_SKILL"
    },
    {
      "from": "documenter",
      "to": "explorer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "documenter",
      "to": "gerador-de-manuais",
      "type": "USES_SKILL"
    },
    {
      "from": "documenter",
      "to": "visual-explainer",
      "type": "USES_SKILL"
    },
    {
      "from": "explorer",
      "to": "code-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "explorer",
      "to": "debugger",
      "type": "CONNECTS_TO"
    },
    {
      "from": "external-observer",
      "to": "debugger",
      "type": "CONNECTS_TO"
    },
    {
      "from": "external-observer",
      "to": "documenter",
      "type": "CONNECTS_TO"
    },
    {
      "from": "external-observer",
      "to": "page-to-markdown",
      "type": "USES_SKILL"
    },
    {
      "from": "external-observer",
      "to": "security-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "external-observer",
      "to": "validator",
      "type": "CONNECTS_TO"
    },
    {
      "from": "git-workflow",
      "to": "code-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "git-workflow",
      "to": "debugger",
      "type": "CONNECTS_TO"
    },
    {
      "from": "max",
      "to": "code-reviewer",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "debugger",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "designer",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "documenter",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "explorer",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "external-observer",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "git-workflow",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "reverse-engineer",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "security-reviewer",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "test-writer",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "tracker",
      "type": "ORCHESTRATES"
    },
    {
      "from": "max",
      "to": "validator",
      "type": "ORCHESTRATES"
    },
    {
      "from": "reverse-engineer",
      "to": "debugger",
      "type": "CONNECTS_TO"
    },
    {
      "from": "reverse-engineer",
      "to": "documenter",
      "type": "CONNECTS_TO"
    },
    {
      "from": "reverse-engineer",
      "to": "external-observer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "reverse-engineer",
      "to": "security-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "security-reviewer",
      "to": "code-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "security-reviewer",
      "to": "security-guidance",
      "type": "USES_SKILL"
    },
    {
      "from": "test-writer",
      "to": "validator",
      "type": "CONNECTS_TO"
    },
    {
      "from": "tracker",
      "to": "external-observer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "tracker",
      "to": "security-reviewer",
      "type": "CONNECTS_TO"
    },
    {
      "from": "tracker",
      "to": "validator",
      "type": "CONNECTS_TO"
    },
    {
      "from": "validator",
      "to": "test-writer",
      "type": "CONNECTS_TO"
    }
  ]
};
