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
#
# ── Critério de admissão (o que "CURADA" quer dizer) ────────────────────────────────────────────
# As entradas abaixo já seguiam estas 4 regras; elas não estavam escritas em lugar nenhum até
# 2026-08-10, quando o SUPPLEMENTS_DATA precisou escolher 2 candidatos entre 25 e teve de inferir
# o critério das entradas existentes. Escrito agora para que a próxima adição não precise inferir.
#
#   1. SEM CREDENCIAL DE FORNECEDOR. O suplemento tem de valer na máquina de quem instalou, sem
#      conta/API key/tenant. Recusados por isto: `clickhouse` (Cloud), `atlan`, `snowflake-cortex-code`.
#      Motivo: o onboarding é portátil/headless e "funciona sem dados pessoais" — um suplemento que
#      pede login quebra a promessa no primeiro uso, e o usuário descobre depois de instalar.
#   2. FOOTPRINT DE SKILL, NÃO DE PLATAFORMA. Skills/prompt são baratos e reversíveis; instalar CLI
#      de terceiro que conecta em produção não é. Recusado por isto: `altimate-code` (o mais forte
#      em dbt do marketplace — e mesmo assim fora).
#   3. AUTORIA IDENTIFICÁVEL. Entrada de marketplace sem campo `author` não entra. Recusados por
#      isto: `data` / `data-engineering` / `astronomer-data-agents` — três nomes do MESMO repo
#      (`astronomer/agents`), sem autor declarado.
#   4. NÃO SOBREPOR O QUE JÁ ESTÁ AQUI. Recusado por isto: `bigquery-data-analytics` (o
#      `data-agent-kit-starter-pack` já cobre BigQuery/dbt no GCP).
#
# Onde procurar candidatos (o catálogo NÃO se descobre sozinho — é curadoria manual, por medição):
#   claude plugin marketplace update claude-plugins-official   # traz o marketplace pro disco (rede)
#   Find-SupplementCandidate -Term 'dbt','warehouse'           # busca offline + classifica
#   (no scaffold, o mesmo por command: /supplements find dbt)
# A busca marca cada hit como candidato / catalogado / recusado / sem-autor: elimina o que ja tem
# veredito e aplica a regra 3 sozinha. As regras 1, 2 e 4 seguem sendo julgamento humano —
# 'candidato' quer dizer "ainda nao decidido", nunca "aprovado".
# Em 2026-08-10 esse marketplace tinha 285 plugins. Ele cresce sozinho: qualquer afirmação de
# "já cobrimos tudo" envelhece sem aviso — reconferir custa 10s, confiar no registro sai caro.
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
            Name   = 'clickhouse-best-practices'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'data'
            Reason = '28 regras de schema/query/ingestão do ClickHouse, priorizadas por impacto (ClickHouse Inc) — skill pura, sem credencial'
        }
        @{
            Type   = 'plugin'
            Name   = 'duckdb-skills'
            Source = 'anthropics/claude-plugins-official'
            Id     = 'claude-plugins-official'
            Theme  = 'data'
            Reason = 'ler qualquer arquivo de dados, consultar DuckDB/DuckLake e buscar a doc (DuckDB Foundation) — local, sem credencial'
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
        @{
            Type   = 'skill'
            Name   = 'orchestrating-agents'
            Source = 'orchestrating-agents'
            Id     = ''
            Theme  = 'orchestration'
            Reason = 'padrões de coordenação de agentes irmãos (rótulo estável, watcher-não-poll, verificação independente) + receitas opcionais com herdr instalado'
        }
    )

    # ── Recusados (curadoria é dizer NÃO) ───────────────────────────────────────────────────────
    # Estes já foram avaliados e REPROVADOS por uma das 4 regras acima. Estavam só em comentário
    # até 2026-08-10 — e comentário não é lido por código: a busca re-sugeria o mesmo
    # `altimate-code` a cada consulta, como se ninguém já tivesse decidido. Agora são DADOS:
    # Find-SupplementCandidate marca o hit como 'recusado' e mostra a regra, em vez de propor de novo.
    #   Name  nome do plugin no marketplace   Rule  1..4 (regra do critério acima)   Reason  o porquê
    Rejected = @(
        @{ Name = 'clickhouse'; Rule = 1; Reason = 'ClickHouse Cloud — exige conta/credencial de fornecedor' }
        @{ Name = 'atlan'; Rule = 1; Reason = 'catálogo Atlan — exige tenant/credencial' }
        @{ Name = 'snowflake-cortex-code'; Rule = 1; Reason = 'Snowflake — exige conta/credencial' }
        @{ Name = 'altimate-code'; Rule = 2; Reason = 'o mais forte em dbt do marketplace, mas instala CLI de terceiro que conecta no warehouse' }
        @{ Name = 'data'; Rule = 3; Reason = 'astronomer/agents sem campo author — mesmo repo de data-engineering/astronomer-data-agents' }
        @{ Name = 'data-engineering'; Rule = 3; Reason = 'mesmo repo (astronomer/agents), sem author' }
        @{ Name = 'astronomer-data-agents'; Rule = 3; Reason = 'mesmo repo (astronomer/agents), sem author' }
        @{ Name = 'bigquery-data-analytics'; Rule = 4; Reason = 'sobrepõe o data-agent-kit-starter-pack já catalogado (BigQuery/dbt no GCP)' }
    )
}
