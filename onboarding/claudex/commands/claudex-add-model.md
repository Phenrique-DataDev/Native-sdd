---
description: Adiciona e configura um modelo novo no claudex — provider, credencial, motor tradutor e tuning por especialidade do modelo.
---

# /claudex-add-model — adicionar um modelo ao claudex

Você vai acrescentar um modelo ao `~/.claude/claudex/profiles.psd1`. **Conduza, não interrogue:**
descubra o que der sozinho e pergunte só o que não dá para descobrir.

**Na dúvida, a resposta certa é acrescentar uma entrada ao `Catalog` do perfil default** — não
criar perfil novo. Modelos no mesmo perfil convivem numa sessão; perfis diferentes exigem
relançar o `claude`. Só crie perfil novo se o usuário quiser explicitamente isolar algo.

## Passo 0 — leia o estado real (2 comandos)

```powershell
claudex -List      # perfis, qual é o (default), modelos de cada
claudex -Check     # motores instalados, segredos que resolvem, login OAuth presente
```

Sem `claudex` no PATH: oriente `.\onboarding\install.ps1 -WithClaudex` e pare.

Leia o `.psd1` real antes de editar — ele é **do usuário**. Nunca reescreva o arquivo inteiro:
**acrescente** preservando o resto, comentários inclusive.

## O FORMATO (a referência — não escreva de memória)

Uma entrada do `Catalog` aceita exatamente estes campos:

| Campo | Obrigatório | O que é |
|---|---|---|
| `Name` | sim | como o usuário chama: `/model <Name>`. É a chave única do catálogo |
| `Provider` | sim | como o motor roteia. Ver a tabela de providers abaixo |
| `Model` | não | ID no provider, se diferente do `Name`. Vazio = usa o `Name` |
| `SecretRef` | depende | `cred:<nome>` · `env:<VAR>` · `file:<nome>`. **Proibido** com `Provider='oauth'` |
| `BaseUrl` | depende | endpoint do provider. Obrigatório em modelo local |
| `Notes` | não | vira a descrição no `/models`. Sem isto a coluna fica vazia |
| `Tuning` | não | vai para `litellm_params` (ver Passo 4) |

No nível do **perfil**:

| Campo | O que é |
|---|---|
| `Name` / `Backend` / `Engine` | identidade e motor (`none` · `direct` · `proxy`; litellm · cliproxy) |
| `Default = $true` | este perfil é o que o `claudex` **sem flag** lança. Só um pode ter |
| `DefaultModel` | em qual modelo do catálogo a sessão **abre** (vira `ANTHROPIC_MODEL`) |
| `Slots` | atalhos do picker: `Opus` · `Sonnet` · `Haiku` · `Fable` — são **quatro** |
| `Port` / `SidecarPort` | portas dos motores (default 4000 / 8317) |
| `PromptCaching` | `$true` só em tier pago — ver a armadilha no fim |

Providers válidos e quando usar cada um:

| `Provider` | Caso | Precisa |
|---|---|---|
| `oauth` | **assinatura** do usuário (Claude/Codex/Gemini/Kimi/xAI), sem chave de API | `Engine='litellm'` + login feito |
| `gemini` · `openai` · `anthropic` · … | chave de API própria | `SecretRef` |
| `ollama_chat` | modelo local | `BaseUrl` |
| — (nível do perfil) | gateway que **já fala Anthropic** (Bedrock/Vertex/Foundry) | `Backend='direct'`, sem motor |

**`ollama_chat`, NUNCA `ollama`** — é o erro de config que mais custa tempo. Medido: com
`ollama` o LiteLLM usa a API legada e força `format: json`; o `gpt-oss:20b` devolvia **vazio** e
o `mistral-small3.1:24b` devolvia **uma definição de tool em JSON** no lugar da resposta. Só o
prefixo mudou e a mesma requisição respondeu `OK`.

## As REGRAS que o `-Check` cobra (viole e o perfil não sobe)

1. **`Provider='oauth'` não aceita `SecretRef`** — a credencial vem do login, guardada no
   auth-dir. Uma chave ali seria uma chave que ninguém lê.
2. **`Provider='oauth'` exige `Engine='litellm'`** — o litellm é o front e encadeia o cliproxy
   como sidecar. Com `Engine='cliproxy'` o motor encadearia a si mesmo.
3. **`Slots` e `DefaultModel` só apontam para nome que EXISTE no catálogo** — apontar para fora
   vira `400 Invalid model name`, e no caso do `DefaultModel` isso mata a **primeira** mensagem.
4. **`SidecarPort` ≠ `Port`** — dois motores na mesma porta.
5. **Só um perfil com `Default = $true`**.
6. **Cloaking é proibido** — `Cloak`/`CloakMode`/`IdentityConfuse`/`DisableClaudeCloakMode` num
   perfil reprovam. Ver o fim deste arquivo.

### A armadilha nº 1: slot não declarado sob `proxy` NÃO volta para a Anthropic

MEDIDO. Sob `Backend='proxy'` o `ANTHROPIC_BASE_URL` aponta para o motor **local** — não existe
volta para a `api.anthropic.com`. Slot não declarado faz o Claude Code mandar o ID Anthropic
embutido (ex.: `claude-haiku-4-5-20251001`) ao motor, que responde **400 `Invalid model name`**.

Consequências práticas, e **não** diga o contrário ao usuário:

- Para ter Claude real no catálogo, a entrada precisa do ID **exato** (`Provider='oauth'` pela
  assinatura, ou `Provider='anthropic'` com chave própria). Nome amigável não pega o slot.
- **Declare os quatro slots** (`Opus`/`Sonnet`/`Haiku`/`Fable`) em perfil `proxy`. Deixar um
  vazio é deixar uma linha do picker que só sabe dar erro.
- No `direct` isso não vale: lá o base URL é da própria Anthropic e o passthrough funciona.

## Passo 1 — credencial: diga ONDE pegar, não peça para colar no chat

**Nunca peça a chave no chat** — ficaria no histórico. Diga onde obter; o usuário grava sozinho.
Onde obter (confirme a URL se não tiver certeza — não invente painel): **OpenAI** →
`platform.openai.com/api-keys` · **Gemini** → `aistudio.google.com/apikey` · **Anthropic** →
`console.anthropic.com/settings/keys`.

```powershell
# cred: — cifrado por DPAPI, atrelado a este usuário do Windows (recomendado)
. "$env:SDD_WORKFLOW_HOME\onboarding\claudex\claudex-lib.ps1"
$dir = Join-Path (Get-ClaudexHome) 'secrets'
[System.IO.File]::WriteAllBytes((Join-Path $dir 'openai.dpapi'), (Protect-ClaudexSecret -PlainText (Read-Host 'Chave' -MaskInput)))
# -> SecretRef = 'cred:openai'
```

`file:<nome>` (texto em dir com ACL restrita) e `env:<VAR>` (some ao fechar o terminal, bom p/
CI) são as outras duas fontes. **Uma credencial por modelo**, não por perfil: é isso que faz
providers diferentes conviverem no mesmo catálogo.

### Caminho de ASSINATURA (`Provider = 'oauth'`)

Sem chave de API. A credencial nasce do login e vive no auth-dir; o claudex nunca a lê.

```powershell
.\onboarding\install.ps1 -WithCliProxy     # instala o motor (SHA-256 verificado)
claudex -Login claude                      # abre o browser; o usuário autentica na conta DELE
```

Providers do `-Login`: `claude` · `codex` · `gemini` · `kimi` · `xai`. Flags **verificadas ao
vivo** no binário v7.2.91 — **não existe `-gemini-login`**: o caminho Google é
`-antigravity-login`, e o `claudex -Login gemini` já mapeia para ele. Não invente flag.

A entrada fica assim — note a ausência de `SecretRef`:

```powershell
@{ Name = 'claude-opus-4-8'; Provider = 'oauth'; Notes = 'Opus 4.8 — assinatura' }
```

**Diga isto antes de o usuário decidir, não é detalhe:** usar assinatura por proxy é área cinzenta
de ToS — os termos de assinatura costumam restringir o acesso aos clientes oficiais. **Para
Anthropic especificamente:** o Claude Code já usa a assinatura nativamente no perfil `claude`
(`Backend='none'`); passar por proxy só serve para **misturar no mesmo catálogo** que os outros
providers. Se o objetivo é só "usar meu Claude", a resposta é o perfil `claude`.

## Passo 2 — motor instalado?

`claudex -Check` responde. Faltando: **litellm** → `uv tool install "litellm[proxy]"` ·
**cliproxy** → `.\onboarding\install.ps1 -WithCliProxy`.

## Passo 3 — escrever

Acrescente ao `Catalog` do perfil escolhido, preservando o resto. Se o usuário não souber o ID
exato do provider, **busque na doc oficial** — ID errado só falha na primeira mensagem, com erro
opaco. Para `oauth`, os IDs disponíveis são os que a conta logada expõe; dá para listar de
verdade em vez de chutar (o motor serve `/v1/models`).

**Modelo listado ≠ modelo utilizável (medido):** com uma chave nova do Gemini, `gemini-2.5-flash`
**aparecia na listagem** e respondia **404 `no longer available to new users`**. Free tier também
devolve **429 por modelo**. Confirme com uma requisição real antes de declarar que funciona.

### Contexto dos modelos locais — o claudex já resolve, mas saiba por quê

MEDIDO (2026-07-20): o Ollama serve com **`context_length: 4096`** por default. O system prompt
+ tools do Claude Code sozinhos estouram isso, então a entrada chega **truncada** — e o sintoma
**não é erro**: o `qwen2.5-coder` alucinou um arquivo inexistente, o `gemma4:26b` "respondeu" que
não tinha acesso ao filesystem, o `gpt-oss` vazou o raciocínio interno. Todos falhas de contexto
cortado, não de capacidade.

O claudex injeta **`num_ctx = 32768`** automaticamente em toda entrada `ollama_chat` (verificado
ao vivo: o `/api/ps` do Ollama passou a reportar `context_length=32768`, e o qwen deixou de
alucinar). Você **não precisa configurar isso** — é o default. O que resta saber:

- **Custa VRAM** — o KV cache cresce com a janela. É por isso que a recomendação é **poucos
  modelos locais, e os mais fortes**: um modelo pequeno com 32k de contexto ainda erra tool use,
  e gasta VRAM à toa.
- **Override por entrada** — para menos VRAM, `Tuning = @{ num_ctx = 8192 }`. Para desligar e
  voltar ao default do Ollama, `Tuning = @{ num_ctx = 0 }`.
- **`num_ctx` só vale para Ollama** — em provider por API a janela é do provider; o claudex não
  injeta nada.

## Passo 4 — Tuning por especialidade do modelo

Aplique o que couber e **explique ao usuário por quê**:

- **`drop_params = $true`** — default, quase nunca deve sair. O Claude Code manda params que nem
  todo provider aceita; sem isso a primeira mensagem morre em 400.
- **Modelos de raciocínio** (o-series, R1) — rejeitam `temperature`/`top_p`. Não force esses
  params; deixe o `drop_params` trabalhar.
- **`max_input_tokens`** — case com a janela real. Janela menor que a assumida trunca ou estoura
  no meio de uma sessão longa: é a causa nº 1 de "funcionou e do nada parou". Em modelo local,
  seja conservador e avise que vai precisar de `/compact` com mais frequência.
- **Tool use fraco** — modelos pequenos erram chamada de ferramenta. Medido aqui: pedir para ler
  um arquivo de 3 linhas e contar devolveu número inventado, sem chamar a tool. **Texto
  funciona; trabalho agentivo não.** Diga isso na cara em vez de deixar o usuário descobrir.

### Se a sessão TRAVAR sem erro na tela: é prompt caching (medido, Gemini)

O motor sobe, o `claude` abre, e nada volta. Sem erro. **Causa:** o Claude Code manda
`cache_control`; o motor traduz para a API de conteúdo cacheado; o Gemini free tier tem
`TotalCachedContentStorageTokensPerModelFreeTier limit=0` → 429 → o motor devolve 500 → o
`claude` **retenta em silêncio**. **Já resolvido no produto:** `DISABLE_PROMPT_CACHING=1` por
default sob `proxy`. Quem tem tier pago liga com `PromptCaching = $true`. **Não mexa sem medir** —
o default é seguro, não ótimo, e o modo de falha é mudo.

## Passo 5 — validar de verdade

```powershell
claudex -Check                                        # config coerente?
claudex -Profile <nome> --model <id-novo> -p "responda apenas OK"
```

`-Check` verde **não** significa que funciona — significa que a config é coerente. Só declare
sucesso depois da ida e volta acima, **testada por entrada nova**, não só o default. Falha em uma
entrada e sucesso em outra aponta credencial, não encanamento. Para `litellm`, o log do motor
traz a razão da recusa.

## Limites que você NÃO contorna em silêncio

- Não peça nem escreva chave no chat, em arquivo versionado, ou na linha de comando.
- Não invente ID de modelo, URL de painel, nem flag de CLI — confirme ou marque como
  não-verificado.
- Não afirme que funciona antes do teste de ida e volta.
- Não prometa entrada nova na **lista visual** do `/model`: ela é built-in e não é extensível. O
  acesso pleno é `/model <nome>`; os slots são 4 atalhos, e `DefaultModel` decide onde a sessão
  abre — é essa combinação que tira o picker do caminho, não uma lista maior.
- **Não religue o cloaking.** O CLIProxyAPI traz `cloak.mode: "auto"` ligado por default —
  disfarça cliente não-Claude-Code como Claude Code, ofusca palavras com caracteres de largura
  zero, remapeia identidade de instalação. A config gerada desliga os três, o schema **reprova**
  quem tentar religar, e o launch **barra** credencial com `cloak_*` no auth-dir (os atributos da
  credencial vencem a config — foi verificado no fonte). Usar a credencial da própria conta é uma
  coisa; disfarçar tráfego para o provider é outra, e o claudex só faz a primeira. Se o usuário
  pedir, explique que a trava é deliberada.
