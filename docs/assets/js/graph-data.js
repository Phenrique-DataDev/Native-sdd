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
  "generatedAt": "2026-08-31",
  "source": "templates/project-scaffold/.claude/agents/graph.json + agents/*.md (frontmatter) + skills/<nome>/SKILL.md + tools/supplements.psd1",
  "nodes": [
    {
      "id": "code-reviewer",
      "type": "Agent",
      "role": "review",
      "description": "Revisor sênior de diff/PR. Prioriza por risco (correção, concorrência, recursos, contrato/retrocompat, performance), lê o contexto e os chamadores além do diff, revisa o que ficou de fora e casa a linguagem com a severidade — sinal alto, sem nit-bombing. Delega estilo aos linters de CI e profundidade de segurança ao security-reviewer. Read-only.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash"
      ],
      "model": "inherit"
    },
    {
      "id": "debugger",
      "type": "Agent",
      "role": "debug",
      "description": "Vai da falha à causa-raiz pelo método científico (hipótese→predição→experimento→observação), não ao sintoma. Reproduz primeiro, checa ambiente antes da lógica, reduz o reprodutor (delta debugging), instrumenta com logs/traces, usa debugger e git bisect para regressão, e trata heisenbug/flaky/concorrência. Use quando algo quebra ou um teste falha sem causa óbvia.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash"
      ],
      "model": "inherit"
    },
    {
      "id": "designer",
      "type": "Agent",
      "role": "design",
      "description": "Expert em UI/frontend que conduz shape→craft→audit — contraste WCAG/APCA, design tokens (primitivo×semântico), tipografia/espaço fluido, ARIA APG, Core Web Vitals (CLS/LCP/INP), motion com prefers-reduced-motion, anti-slop, static-first. Use ao criar/revisar/refinar interface. Pedido de mockup/wireframe/landing para ajustar no olho é canvas — que roda na sessão principal, não aqui: devolva o briefing em vez do diff. Aponta para a skill `impeccable` quando instalada (`/supplements design`); sem ela, aplica a mesma disciplina diretamente. Não carrega paleta/referências fixas de nenhum projeto.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash",
        "Skill"
      ],
      "model": "inherit"
    },
    {
      "id": "documenter",
      "type": "Agent",
      "role": "documentation",
      "description": "Expert em escrita técnica humano×LLM (fora da KB) — organiza `docs/` por Diátaxis (tutorial/how-to/reference/explanation), lavra ADR (Nygard/MADR), changelog Keep a Changelog derivado de Conventional Commits, runbook/onboarding e diagramas Mermaid. Registros append-only datados, derivados do git/código; nunca inventa. Use ao registrar o que mudou/aconteceu ou documentar como algo funciona.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash"
      ],
      "model": "inherit"
    },
    {
      "id": "explorer",
      "type": "Agent",
      "role": "search",
      "description": "Explora uma codebase desconhecida e devolve um mapa conciso (pontos de entrada, como conecta, onde a mudança entra) sem despejar arquivos. Segue o call graph (definição→usos→testes), não só hits de grep; domina ripgrep avançado (tipos, contexto, -w, globs), ast-grep (busca por AST) e tags/LSP. Use para \"onde fica X\" antes de implementar. Read-only.",
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
      "description": "Observador de caixa-preta — valida ou mapeia um alvo externo/opaco (site, API, app rodando) por observação read-only (rede/HAR, headers de cache/CDN, contrato/OpenAPI), separando fato de hipótese com evidência real e respeitando autorização (CFAA/ToS/robots). Confronta com uma referência; nunca replica, burla nem aplica. Saída: relatório.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash",
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
      "description": "Expert em higiene de repositório e no fluxo que cerca o PR — Conventional Commits, commits atômicos/bisect-friendly, rebase × merge (regra de ouro do histórico compartilhado), .gitignore preciso, PRs pequenos, Git-Worktree (isolar branches/sessões paralelas, base do /peers), leitura de CI vermelho (localiza job/step que falhou; a causa-raiz é do debugger) e board de trabalho (GitHub Projects: item, campo, status, ligação issue↔PR). Lê workflows e board do projeto em runtime — não carrega nome de job, número de projeto nem campo fixo. Use ao preparar commits/PRs, destravar CI, revisar histórico, organizar o repo ou paralelizar trabalho. Roda git/gh.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash"
      ],
      "model": "inherit"
    },
    {
      "id": "security-reviewer",
      "type": "Agent",
      "role": "security",
      "description": "Revisão de segurança em profundidade (AppSec) guiada por fronteira de confiança — OWASP Top 10 (2021/2025) e ASVS, injeção/SSRF/desserialização/IDOR, authn/authz, cripto, supply-chain (SLSA, lockfiles/pinning), segredos no working-tree e no histórico git (pickaxe, gitleaks/trufflehog) e audit de deps (osv-scanner/pip-audit/npm audit). Read-only.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash"
      ],
      "model": "inherit"
    },
    {
      "id": "test-writer",
      "type": "Agent",
      "role": "testing",
      "description": "Escreve/completa testes na stack do projeto cobrindo caminho feliz, bordas, falhas e os Acceptance Tests do DEFINE. Domina pirâmide×troféu, AAA, testar contrato (não implementação), determinismo anti-flaky (relógio/RNG/ordem/estado/async), property-based (Hypothesis/fast-check), mutation testing (mutmut/Stryker) para provar que os testes matam bugs, e mock sem sobre-mock. Lê o setup do projeto — não inventa framework. Cria/edita testes e roda.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash"
      ],
      "model": "inherit"
    },
    {
      "id": "tracker",
      "type": "Agent",
      "role": "tracking",
      "description": "Expert em tráfego/traqueamento server-side. Domina sGTM (web→tag mãe→servidor first-party→GA4/Meta CAPI/Google Ads), dedup client×server por `event_id`/`transaction_id`, click-ids (fbclid→fbc, gclid/gbraid/wbraid) com fallback e ITP, PII normalizada+SHA-256 hex, Enhanced Conversions, atribuição cross-domain, Consent Mode v2 (EEA) e QA de runtime (DebugView/Tag Assistant/Test Events/EMQ). Lê o setup do projeto — não carrega IDs/eventos fixos.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Edit",
        "Write",
        "Bash"
      ],
      "model": "inherit"
    },
    {
      "id": "validator",
      "type": "Agent",
      "role": "validation",
      "description": "Verifica se o resultado entregue cumpre a spec e os Acceptance Tests do DEFINE — executa e observa o comportamento real, checa exit code (não só stdout), cobre o caso negativo e a fronteira, e isola o veredito em ambiente reprodutível (worktree limpo, deps do zero). Distingue cumpre/parcial/não-cumpre com evidência. Não conserta — só verifica. Read-only.",
      "tools": [
        "Read",
        "Grep",
        "Glob",
        "Bash"
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
      "status": "valid"
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
      "status": "valid"
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
      "status": "valid"
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
      "reason": "review de segurança do código gerado: avisos por padrão + diagnóstico LLM (Anthropic)",
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
