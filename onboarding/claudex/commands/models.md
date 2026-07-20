---
description: Mostra os modelos disponíveis no perfil claudex ativo, com nome real e descrição, e monta o /model para você trocar.
---

# /models — catálogo de modelos do perfil ativo

O `/model` (built-in) mostra sempre "Opus / Sonnet / Haiku", mesmo quando esses slots apontam
para GPT, Gemini ou modelos locais. Este comando mostra **o que cada slot realmente é** e quais
outros modelos dá para chamar por nome.

## Limite que você precisa deixar claro (não contorne, não prometa)

**Você NÃO consegue trocar o modelo sozinho.** `/model` é comando embutido da CLI, não é
invocável por agente — isto foi testado e confirmado. O que este comando faz é **descobrir e
apresentar**; a troca final é o usuário quem dá, com um comando pronto que você entrega.

Não tente contornar isso escrevendo em settings, matando processo, ou reescrevendo perfil para
"forçar" a troca. Apresente e devolva o comando.

## Passo 1 — descobrir o perfil ativo

```powershell
$env:CLAUDEX_PROFILE          # nome do perfil (setado pelo claudex ao lançar)
$env:ANTHROPIC_DEFAULT_OPUS_MODEL
$env:ANTHROPIC_DEFAULT_SONNET_MODEL
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL
```

- **`CLAUDEX_PROFILE` vazio** → a sessão não foi lançada pelo claudex, ou está no perfil
  `claude` (passthrough Anthropic puro). Diga isso e pare: não há nada a listar além dos
  modelos normais da Anthropic, que o `/model` já mostra corretamente.
- **`CLAUDEX_PROFILE` preenchido** → leia o perfil em `~/.claude/claudex/profiles.psd1`. Use as
  funções do lib para não reimplementar a normalização:

```powershell
. "$env:SDD_WORKFLOW_HOME\onboarding\claudex\claudex-lib.ps1"
$prof = (Import-PowerShellDataFile "$env:USERPROFILE\.claude\claudex\profiles.psd1").Profiles |
        Where-Object Name -eq $env:CLAUDEX_PROFILE
Get-ClaudexCatalog -ProfileObj $prof   # todos os modelos: Name, Provider, Notes
Get-ClaudexSlots   -ProfileObj $prof   # quais slots do picker estão remapeados
```

## Passo 2 — apresentar

O catálogo é a lista completa. Os slots são só atalhos. Monte assim:

| Como chamar | Modelo | Provider | O que é |
|---|---|---|---|
| `/model claude-sonnet-4-6` **ou** picker "Sonnet" | `claude-sonnet-4-6` | anthropic | Sonnet real |
| `/model gpt-5` | `gpt-5` | openai | segunda opinião |
| `/model qwen2.5-coder:14b` | `qwen2.5-coder:14b` | ollama_chat | local, sem custo |

Regras de honestidade na tabela:

- **Todo** modelo do catálogo é chamável por `/model <nome-exato>` — isso foi verificado ao
  vivo, não é suposição. O catálogo não tem teto de 3.
- Um modelo só ganha atalho no picker se estiver em `Slots`. Marque quais têm.
- **Slot não declarado continua apontando para o modelo Anthropic original** — diga isso, é o
  que garante que o usuário não perdeu o Claude ao entrar no perfil.
- Use o campo `Notes` de cada entrada para a coluna "O que é". Sem nota, **não invente
  descrição** — deixe em branco.

## Passo 3 — oferecer a troca

Use `AskUserQuestion` para o usuário escolher (é o que dá nome real + descrição numa caixa de
seleção). Com a escolha feita, **entregue o comando exato** para ele rodar:

```
/model sonnet
```

Deixe explícito que é ele quem digita — e por quê (comando embutido, não invocável por agente).

## Se o usuário quiser trocar de PERFIL (não de modelo)

Isso não é `/model` — é relançar. As env vars são lidas no **start** do processo `claude`:

```powershell
exit
claudex -Profile <outro-perfil>
```

Para ver o que existe: `claudex -List`. Para adicionar um provider/modelo novo:
`/claudex-add-model`.
