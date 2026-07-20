# profiles.psd1 — perfis do `claudex` (troca fina de modelo/provider Anthropic-compatível).
#
# SEED: este arquivo é COPIADO para ~/.claude/claudex/profiles.psd1 pelo instalador
# (onboarding/install.ps1 -WithClaudex) apenas quando o destino ainda NÃO existe. Uma vez
# copiado, ele é SEU — edite à vontade; reinstalar NÃO sobrescreve (preserva customização).
#
# Cada perfil descreve COMO lançar o `claude`:
#   Backend = 'none'   -> passthrough puro: nenhuma env var é setada (plano normal Claude).
#   Backend = 'direct' -> provider que JÁ fala o protocolo Anthropic: seta ANTHROPIC_BASE_URL /
#                          ANTHROPIC_AUTH_TOKEN (e os *_MODEL) no PROCESSO FILHO. Sem proxy.
#   Backend = 'proxy'  -> provider que NÃO fala Anthropic (OpenAI, Gemini, Ollama...): sobe um
#                          motor tradutor local (Engine), aponta o claude p/ 127.0.0.1:<porta>
#                          e derruba o motor ao sair. A chave do provider vai só p/ o motor.
#
# IMPORTANTE (fato técnico): o Claude Code lê ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN /
# ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL no START do processo. Trocar de PERFIL vale a
# partir da próxima sessão `claude` — não há troca de perfil no meio de uma sessão viva.
#
# COMO A TROCA DE MODELO FUNCIONA (verificado nos docs oficiais E ao vivo):
#   - `/model <nome>` e `claude --model <nome>` aceitam nome ARBITRÁRIO, que chega ao motor
#     verbatim. VERIFICADO ao vivo: `--model qwen2.5-coder:14b` roteou certo. É por aqui que
#     você alcança o catálogo INTEIRO — quantos modelos quiser, de providers diferentes.
#   - A LISTA visual do `/model` é built-in e NÃO é extensível (o pedido existe como feature
#     request no repo do Claude Code, fechado como duplicado). Os 3 nomes dela
#     (Opus/Sonnet/Haiku) são ATALHOS remapeáveis via `Slots` — conveniência, não o mecanismo.
#   - CUIDADO com o slot não declarado no Backend 'proxy' (MEDIDO 2026-07-19, corrige o que
#     este comentário afirmava antes): sob 'proxy' o ANTHROPIC_BASE_URL aponta p/ o motor
#     LOCAL, então NÃO existe passagem de volta p/ a api.anthropic.com. Slot não declarado faz
#     o Claude Code mandar o ID Anthropic embutido (ex.: 'claude-haiku-4-5-20251001') ao motor,
#     que responde 400 'Invalid model name' — verificado nos 3 IDs. Para ter Claude REAL junto
#     dos outros, o catálogo precisa de uma entrada cujo `Name` seja EXATAMENTE esse ID, com
#     Provider = 'anthropic' e chave própria. (No Backend 'direct' o passthrough vale, porque
#     lá o base URL é da própria Anthropic.)
#
# O token NUNCA vai aqui: SecretRef aponta a fonte, resolvida no lançamento (nunca versionada):
#   'cred:<nome>'  -> blob protegido por DPAPI (CurrentUser) em secrets/<nome>.dpapi
#   'env:<VAR>'    -> variável de ambiente já exportada na sessão
#   'file:<nome>'  -> arquivo texto em secrets/<nome> (diretório com ACL restrita ao usuário)
#
# Para adicionar um modelo novo sem editar isto na mão: rode `/claudex-add-model` numa sessão
# do Claude Code — ele pergunta o provider, indica onde pegar a chave/fazer login, escolhe o
# motor e escreve o perfil aqui, já com o Tuning adequado ao modelo.

@{
    Profiles = @(
        @{
            Name    = 'claude'
            Backend = 'none'
            Note    = 'plano normal — nenhum env setado, passthrough puro para o claude'
        }

        @{
            Name      = 'anthropic-key'
            Backend   = 'direct'
            BaseUrl   = ''                 # vazio = usa o endpoint padrão da Anthropic
            SecretRef = 'file:anthropic'   # ~/.claude/claudex/secrets/anthropic (texto, ACL restrita)
            Models    = @{}                # ex.: @{ Opus = 'claude-...'; Sonnet = '...'; Haiku = '...' }
        }

        # --- CASO A: gateway que JÁ fala o protocolo Anthropic (sem proxy) --------------------
        # Bedrock, Vertex, Foundry ou qualquer gateway corporativo Anthropic-compatível.
        # NADA é instalado por isto — é só configuração de para onde o claude fala.
        #
        # @{
        #     Name      = 'meu-gateway'
        #     Backend   = 'direct'
        #     BaseUrl   = 'https://gateway.interno.exemplo/anthropic'
        #     SecretRef = 'cred:meu-gateway'   # blob DPAPI em secrets/meu-gateway.dpapi
        #     Models    = @{ Opus = 'modelo-grande'; Sonnet = 'modelo-medio'; Haiku = 'modelo-rapido' }
        # }
        #
        # --- O PERFIL QUE PROVAVELMENTE VOCÊ QUER: catálogo multi-provider --------------------
        # Claude REAL + GPT + Gemini + local, tudo junto, cada um com a sua credencial.
        # Você NÃO perde a Anthropic ao entrar aqui — é o ponto todo do formato `Catalog`.
        #
        # @{
        #     Name    = 'mix'
        #     Backend = 'proxy'
        #     Engine  = 'litellm'
        #     Catalog = @(
        #         # Anthropic de verdade, pela sua chave — continua disponível dentro do perfil.
        #         @{ Name = 'claude-sonnet-4-6'; Provider = 'anthropic'; SecretRef = 'cred:anthropic'
        #            Notes = 'Sonnet real — trabalho agentivo pesado' }
        #         @{ Name = 'gpt-5'; Provider = 'openai'; SecretRef = 'cred:openai'
        #            Notes = 'segunda opinião, estilo diferente' }
        #         @{ Name = 'gemini-3-pro'; Provider = 'gemini'; SecretRef = 'cred:gemini'
        #            Notes = 'contexto muito longo' }
        #         @{ Name = 'qwen2.5-coder:14b'; Provider = 'ollama_chat'
        #            BaseUrl = 'http://127.0.0.1:11434'; Notes = 'local, offline, sem custo' }
        #     )
        #     # Atalhos do picker — OPCIONAIS. O que não declarar continua Anthropic original.
        #     Slots   = @{ Sonnet = 'gpt-5'; Haiku = 'qwen2.5-coder:14b' }
        # }
        #
        # No uso: /model gpt-5 · /model gemini-3-pro · /model claude-sonnet-4-6 · /model qwen2.5-coder:14b
        # E `/models` lista tudo isso com o nome real e a Notes de cada um.
        #
        # --- CASO B (forma simples): um provider só ------------------------------------------
        # Exige o motor instalado (`claudex -Check` diz se está). Dois motores suportados:
        #
        #   Engine = 'litellm'   -> cobertura ampla (100+ providers) por API key.
        #                           Instale com: uv tool install "litellm[proxy]"
        #                           Porta default 4000. A chave upstream NUNCA é escrita em
        #                           arquivo — viaja por env var só do processo do motor.
        #
        #   Engine = 'cliproxy'  -> permite LOGIN OAuth (usar assinatura ChatGPT/Gemini sem
        #                           chave de API). Binário Go, porta default 8317.
        #                           Baixe em: github.com/router-for-me/CLIProxyAPI/releases
        #                           ⚠ o schema de config gerado p/ este motor ainda NÃO foi
        #                           validado contra o binário real — `-Check` avisa.
        #
        # @{
        #     Name      = 'gpt'
        #     Backend   = 'proxy'
        #     Engine    = 'litellm'
        #     Provider  = 'openai'             # como o motor roteia: <provider>/<modelo>
        #     SecretRef = 'cred:openai'        # chave do PROVIDER (vai só p/ o motor)
        #     Models    = @{
        #         # Estes 3 viram os slots do picker: escolher "Sonnet" no /model roteia p/ cá.
        #         Opus   = 'gpt-5'
        #         Sonnet = 'gpt-5-mini'
        #         Haiku  = 'gpt-5-nano'
        #         # Estes NÃO aparecem no picker, mas funcionam com `/model o3`.
        #         Extra  = @('o3')
        #     }
        #     # Tuning: ajuste por especialidade do modelo. Entra em litellm_params.
        #     # drop_params já vem ligado (o Claude Code manda params que nem todo provider
        #     # aceita — sem isso, erro 400 na primeira mensagem).
        #     Tuning    = @{ max_input_tokens = 200000 }
        # }
        #
        # @{
        #     Name     = 'codex'               # assinatura ChatGPT via OAuth, SEM chave de API
        #     Backend  = 'proxy'
        #     Engine   = 'cliproxy'
        #     Provider = 'openai'
        #     # Sem SecretRef de propósito: o login vive no auth-dir do motor. Faça o login
        #     # pelo binário do cliproxy uma vez; o claudex reaproveita a credencial.
        #     Models   = @{ Opus = 'gpt-5'; Sonnet = 'gpt-5-mini'; Haiku = 'gpt-5-nano' }
        # }
        #
        # @{
        #     Name     = 'local'               # modelo local via Ollama — offline, sem custo
        #     Backend  = 'proxy'
        #     Engine   = 'litellm'
        #     # 'ollama_chat', NÃO 'ollama' — medido em 2026-07-19: com 'ollama' o LiteLLM usa a
        #     # API legada e força `format: json`, e o modelo passa a cuspir JSON no lugar da
        #     # resposta (o mistral devolvia uma definição de tool; o gpt-oss, nada). Com
        #     # 'ollama_chat' ele usa a API de chat, com tool support nativo — e a resposta volta
        #     # normal. Mesma máquina, mesmo modelo, só o prefixo mudou.
        #     Provider = 'ollama_chat'
        #     BaseUrl  = 'http://127.0.0.1:11434'
        #     # Sem SecretRef: Ollama local não pede chave.
        #     # Slot é OPCIONAL (o que não declarar segue apontando p/ o modelo Anthropic
        #     # original). O que NÃO pode é slot apontar p/ nome fora do catálogo: aí o claude
        #     # pede esse nome ao motor e leva 400 'Invalid model name'. O `-Check` cobra isso.
        #     Models   = @{ Opus = 'qwen2.5-coder:14b'; Sonnet = 'qwen2.5-coder:14b'; Haiku = 'qwen2.5-coder:7b' }
        # }
    )
}
