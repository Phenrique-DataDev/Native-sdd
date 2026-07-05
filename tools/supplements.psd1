# supplements.psd1 — manifesto (DADOS) do repertório de suplementos opt-in.
# Fonte ÚNICA, lida por tools/supplements.ps1 (Get-SupplementCatalog) e consumida pelo
# onboarding (install-plugins.ps1 / apply.ps1 -ExtraPlugins -Themes) e pelo command /supplements.
# Cada entrada é CURADA (validada à mão) — não é um índice pesquisável.
#
# Schema por entrada (todos obrigatórios, não-vazios):
#   Type    'plugin' | 'skill'    natureza do suplemento (roteia a instalação)
#   Name    id público            'plugin' -> nome após 'claude plugin install <Name>@<Id>'
#                                  'skill'  -> nome da pasta da skill no baseline
#   Source  origem                'plugin' -> marketplace owner/repo (claude plugin marketplace add)
#                                  'skill'  -> caminho/origem no baseline dir (relativo ao baseline)
#   Id      'plugin' -> id do marketplace usado após o '@' (campo 'name' do marketplace.json)
#           'skill'  -> '' (não usado)
#   Theme   tema p/ seleção (-Themes / /supplements <tema>): design | reporting | ...
#   Reason  descrição curta p/ log
#
# Import-PowerShellDataFile lê este arquivo; o topo é um hashtable com a chave Supplements.
@{
    Supplements = @(
        @{
            Type   = 'plugin'
            Name   = 'ui-ux-pro-max'
            Source = 'nextlevelbuilder/ui-ux-pro-max-skill'
            Id     = 'ui-ux-pro-max-skill'
            Theme  = 'design'
            Reason = 'design system / UI (auto-ativa só em pedidos de design)'
        }
        @{
            Type   = 'plugin'
            Name   = 'visual-explainer'
            Source = 'nicobailon/visual-explainer'
            Id     = 'visual-explainer-marketplace'
            Theme  = 'reporting'
            Reason = 'visualização de saída em HTML (diffs, planos, slides, relatórios)'
        }
        @{
            Type   = 'plugin'
            Name   = 'impeccable'
            Source = 'pbakaus/impeccable'
            Id     = 'impeccable'
            Theme  = 'design'
            Reason = 'design fluency / anti-patterns de UI (cache per-projeto em .impeccable/)'
        }
        # --- Discipline-level (marketplace oficial Anthropic) — curados, skill/baixo-risco ---
        @{
            Type   = 'plugin'
            Name   = 'data-agent-kit-starter-pack'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'data'
            Reason = 'eng. de dados GCP: pipelines, dbt, Spark, BigQuery SQL (Google)'
        }
        @{
            Type   = 'plugin'
            Name   = 'security-guidance'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'security'
            Reason = 'review de segurança do código gerado: avisos por padrão + diagnóstico LLM (Anthropic)'
        }
        @{
            Type   = 'plugin'
            Name   = 'skill-creator'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'meta'
            Reason = 'criar/melhorar/medir skills do Claude Code (Anthropic)'
        }
        # --- Criar/buildar IA (marketplace oficial) — toolkits de construção, skill/sem-credencial ---
        @{
            Type   = 'plugin'
            Name   = 'agent-sdk-dev'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'ai'
            Reason = 'kit de desenvolvimento com o Claude Agent SDK (Anthropic)'
        }
        @{
            Type   = 'plugin'
            Name   = 'mcp-server-dev'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'ai'
            Reason = 'projetar/construir MCP servers (Anthropic)'
        }
        @{
            Type   = 'plugin'
            Name   = 'mcp-apps'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'ai'
            Reason = 'criar MCP Apps com o MCP Apps SDK (Anthropic)'
        }
        @{
            Type   = 'plugin'
            Name   = 'plugin-dev'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'ai'
            Reason = 'desenvolver plugins do Claude Code: hooks, commands, agents, skills (Anthropic)'
        }
        @{
            Type   = 'plugin'
            Name   = 'huggingface-skills'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'ai'
            Reason = 'build/train/avaliar modelos open-source, datasets e spaces (Hugging Face)'
        }
        # --- Skill autoral (vendorizada em templates/supplements/skills/, Type=skill) ---
        @{
            Type   = 'skill'
            Name   = 'gerador-de-manuais'
            Source = 'gerador-de-manuais'
            Id     = ''
            Theme  = 'docs'
            Reason = 'gera tutorial/manual de marca/guia de convenções a partir de template — referência do agente documenter'
        }
    )
}
