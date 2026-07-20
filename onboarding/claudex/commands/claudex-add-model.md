---
description: Adiciona e configura um modelo novo no claudex — provider, credencial, motor tradutor e tuning por especialidade do modelo.
---

# /claudex-add-model — adicionar um modelo ao claudex

Você vai conduzir o usuário na adição de um modelo/provider novo ao `claudex`, escrevendo o
perfil em `~/.claude/claudex/profiles.psd1`. **Conduza, não interrogue:** descubra o que der
sozinho (rodando comandos) e pergunte só o que não dá para descobrir.

## Antes de qualquer coisa: leia o estado real

```powershell
claudex -List     # perfis que já existem (não duplique nome)
claudex -Check    # motores instalados, segredos que resolvem
```

Se `claudex` não existir no PATH, o addon não está instalado: oriente
`.\onboarding\install.ps1 -WithClaudex` e pare aqui.

Leia também o `profiles.psd1` real antes de editar — ele é **do usuário**, pode ter
customização que o seed não tem. Nunca reescreva o arquivo inteiro: **acrescente** o perfil
novo preservando o resto, comentários inclusive.

## Passo 1 — que provider é

Pergunte qual provider/modelo o usuário quer adicionar. Com a resposta, classifique:

| Situação | Backend | O que precisa |
|---|---|---|
| Já fala protocolo Anthropic (Bedrock, Vertex, Foundry, gateway corporativo) | `direct` | só `BaseUrl` + chave |
| Não fala Anthropic, tem chave de API (OpenAI, Gemini, Groq, DeepSeek…) | `proxy` + `Engine='litellm'` | motor + chave |
| Não fala Anthropic, quer usar **assinatura** sem chave (ChatGPT/Gemini) | `proxy` + `Engine='cliproxy'` | motor + login OAuth |
| Modelo local (Ollama, LM Studio, vLLM) | `proxy` + `Engine='litellm'` | motor, sem chave |

Na dúvida entre `litellm` e `cliproxy`: **litellm** é o default (cobertura maior, config
verificada). Só vá de `cliproxy` se o usuário quer explicitamente login por assinatura em vez
de chave de API — e avise que o schema gerado para esse motor **ainda não foi validado contra
o binário real** (o `-Check` marca como PENDENTE).

**Perfil novo ou entrada nova?** Se já existe um perfil `proxy` com o mesmo motor, prefira
**acrescentar uma entrada ao `Catalog` dele** a criar outro perfil — modelos no mesmo perfil
convivem numa sessão só; perfis diferentes exigem relançar o `claude`.

## Passo 2 — credencial: diga ONDE pegar, não peça para colar no chat

**Nunca peça a chave no chat** — ela ficaria no histórico da conversa. Diga onde obter e como
gravar; o usuário grava sozinho.

Onde obter (confirme a URL se não tiver certeza — não invente painel):

- **OpenAI** → `platform.openai.com/api-keys`
- **Google Gemini** → `aistudio.google.com/apikey`
- **Anthropic** → `console.anthropic.com/settings/keys`
- **Outros** → busque na doc oficial do provider antes de afirmar.

**Uma credencial por modelo, não por perfil.** Cada entrada do `Catalog` tem o seu próprio
`SecretRef`, resolvido para uma env var própria no lançamento — é isso que faz `anthropic` +
`gemini` conviverem no mesmo perfil. Se o usuário vai adicionar um provider a um perfil que já
existe, **não substitua o `SecretRef` do perfil**: acrescente uma entrada nova ao catálogo com
a credencial dela.

Como gravar (ofereça as 3, recomende `cred:` no Windows):

```powershell
# cred: — cifrado por DPAPI, atrelado a este usuário do Windows (recomendado)
. "$env:SDD_WORKFLOW_HOME\onboarding\claudex\claudex-lib.ps1"
$dir = Join-Path (Get-ClaudexHome) 'secrets'
[System.IO.File]::WriteAllBytes((Join-Path $dir 'openai.dpapi'), (Protect-ClaudexSecret -PlainText (Read-Host 'Chave' -MaskInput)))
# -> SecretRef = 'cred:openai'

# file: — texto puro em dir com ACL restrita ao usuário
# -> grave em ~/.claude/claudex/secrets/openai, SecretRef = 'file:openai'

# env: — variável já exportada na sessão (bom p/ CI, some ao fechar o terminal)
# -> SecretRef = 'env:OPENAI_API_KEY'
```

### Caminho de ASSINATURA (OAuth) — sem chave de API nenhuma

Se o usuário quer usar a **conta** dele (Claude, ChatGPT/Codex, Google, Kimi, Grok) em vez de
comprar chave de API, o caminho é `Backend='proxy'` + `Engine='cliproxy'`. Não há `SecretRef`:
a credencial nasce do login e vive no `auth-dir` (`~/.claude/claudex/auth/cliproxy`).

```powershell
.\onboarding\install.ps1 -WithCliProxy     # instala o motor (SHA-256 verificado)
claudex -Login claude                      # abre o browser; o usuário autentica na conta DELE
```

Providers aceitos no `-Login`: `claude` · `codex` · `gemini` · `kimi` · `xai`. **Flags
verificadas ao vivo** no binário v7.2.91 — **não existe `-gemini-login`**: o caminho Google é o
`-antigravity-login`, e o `claudex -Login gemini` já mapeia para ele. Não invente flag fora
dessa lista.

**Diga isto ao usuário antes de ele decidir — não é detalhe:** usar assinatura por proxy é área
cinzenta de ToS. Os termos de assinatura (ao contrário dos de API) costumam restringir o acesso
aos clientes oficiais, e a conta é dele. **Especificamente para Anthropic:** o Claude Code já usa
a assinatura nativamente pelo perfil `claude` (`Backend='none'`) — passar por proxy **não
destrava nada** além de misturar no catálogo, e adiciona exposição. Se o objetivo é só "usar meu
Claude", a resposta certa é o perfil `claude`, não este caminho.

**O que o claudex NÃO deixa fazer, por construção:** o CLIProxyAPI traz cloaking **ligado por
default** (`cloak.mode: "auto"`) — disfarça cliente não-Claude-Code como Claude Code, ofusca
palavras com caracteres de largura zero, remapeia identidade de instalação. A config que
geramos desliga os três explicitamente, e o `-Check` **reprova** um perfil que tente religá-los.
Usar a credencial da própria conta é uma coisa; disfarçar tráfego para o provider é outra, e o
claudex só faz a primeira. **Se o usuário pedir para religar o cloaking, não faça** — explique
que a trava é deliberada.

## Passo 3 — o motor está instalado?

`claudex -Check` responde. Se faltar:

- **litellm** → `uv tool install "litellm[proxy]"` (o onboarding já garante o `uv`)
- **cliproxy** → binário em `github.com/router-for-me/CLIProxyAPI/releases`

## Passo 4 — montar o CATÁLOGO (a parte que decide a experiência)

O mecanismo é o **catálogo**, não os 3 slots do picker. Explique assim ao usuário:

> `/model <nome>` e `--model <nome>` aceitam **nome arbitrário**, que chega ao motor verbatim
> (verificado ao vivo). Então você pode expor **quantos modelos quiser**, de providers
> diferentes, cada um com a sua chave — e chamar qualquer um digitando `/model <nome>`. A
> **lista visual** do picker é built-in e não é extensível; os 3 nomes dela (Opus/Sonnet/Haiku)
> são **atalhos opcionais** que você pode remapear, não o teto.

Escreva o perfil na forma `Catalog` — é ela que suporta **provider e credencial por modelo**:

```powershell
@{
    Name    = 'mix'
    Backend = 'proxy'
    Engine  = 'litellm'
    Catalog = @(
        @{ Name = '<id-anthropic>'; Provider = 'anthropic'; SecretRef = 'cred:anthropic'
           Notes = 'Claude real — continua disponível dentro do perfil' }
        @{ Name = '<id-gemini>';    Provider = 'gemini';    SecretRef = 'cred:gemini'
           Notes = 'contexto longo' }
    )
    Slots   = @{ Sonnet = '<id-gemini>' }   # OPCIONAL. O que não declarar fica Anthropic original.
}
```

**Cuidado com o slot não declarado sob `proxy` — medido em 2026-07-19:** ali o
`ANTHROPIC_BASE_URL` aponta para o motor **local**, então **não existe volta para a
`api.anthropic.com`**. Slot não declarado faz o Claude Code mandar o ID Anthropic embutido
(ex.: `claude-haiku-4-5-20251001`) ao motor, que responde **400 `Invalid model name`**. Para ter
Claude real convivendo com os outros, o catálogo precisa de uma entrada cujo `Name` seja
**exatamente esse ID**, com `Provider = 'anthropic'` e chave própria — nome amigável não pega o
slot. (No `direct` o passthrough vale, porque lá o base URL é da própria Anthropic.)

Os slots, **se** o usuário quiser atalhos, mapeiam por **papel** de custo/capacidade:
`Opus` = o mais capaz · `Sonnet` = o cavalo de batalha · `Haiku` = o rápido e barato.
Regra que o `-Check` cobra: **slot tem que apontar para um nome que existe no catálogo** (slot
apontando para nome desconhecido vira `400 Invalid model name` na primeira mensagem).

A forma simples (`Models` + `Provider` no nível do perfil) continua válida para **um provider
só** — é normalizada para catálogo por dentro. Use `Catalog` sempre que houver mais de um
provider ou mais de uma credencial.

Se o usuário não souber os IDs exatos do provider, **busque na doc oficial** — ID de modelo
errado só falha na primeira mensagem, e o erro do provider costuma ser opaco. Prefixos de
provider do LiteLLM que já usamos: `openai`, `anthropic`, `gemini` (AI Studio), `ollama_chat`.

## Passo 5 — Tuning por especialidade do modelo

Aqui você agrega valor de verdade: ajuste o `Tuning` do perfil ao que o modelo é. Aplique o que
couber, e **explique ao usuário por que** cada ajuste entrou.

- **`drop_params = $true`** — já é o default e quase nunca deve sair. O Claude Code manda
  parâmetros que nem todo provider aceita; sem isso a primeira mensagem morre em HTTP 400.
- **Modelos de raciocínio** (o-series, DeepSeek-R1, e afins) — costumam **rejeitar
  `temperature`/`top_p`**. Mantenha `drop_params` ligado; não force esses params no Tuning.
- **`max_input_tokens`** — case o valor com a janela real do modelo. Modelo com janela menor que
  a que o Claude Code assume trunca ou estoura no meio de uma sessão longa; é a causa nº 1 de
  "funcionou e do nada parou".
- **Modelo local (Ollama/LM Studio)** — janela costuma ser bem menor que a dos modelos de
  fronteira. Seja conservador no `max_input_tokens` e avise que sessões longas vão precisar de
  `/compact` com mais frequência.
- **Tool use fraco** — modelos pequenos erram chamada de ferramenta com frequência. Se o usuário
  for usar o perfil para trabalho agentivo (não só chat), diga isso na cara: a experiência
  **degrada**, não é equivalente ao Claude. Sugira reservar esse perfil para tarefas simples.

### Se a sessão TRAVAR sem erro na tela: é prompt caching (medido 2026-07-19, Gemini)

**Sintoma:** o motor sobe, anuncia os modelos, o `claude` abre — e nada volta. Sem mensagem de
erro. Só timeout.

**Causa:** o Claude Code manda blocos `cache_control` no system prompt. O motor traduz isso para
a API de conteúdo cacheado do provider, e o **Gemini free tier tem
`TotalCachedContentStorageTokensPerModelFreeTier limit=0`** → 429 → o motor devolve 500 → o
`claude` **retenta em silêncio**. Provado isolado: mesmo payload, mesmo tamanho, só o
`cache_control` mudando — com ele 429, sem ele `OK`/`end_turn`.

**Já está resolvido no produto:** o `claudex` seta `DISABLE_PROMPT_CACHING=1` no filho por
default sob `Backend='proxy'`. Quem tem tier **pago** (onde o caching funciona e economiza de
verdade) liga de volta com `PromptCaching = $true` no perfil. **Não mexa nisso sem medir** — o
default é seguro, não ótimo, e o modo de falha que ele evita é mudo.

### Modelo listado ≠ modelo utilizável (medido 2026-07-19)

Não confie só no `ListModels` do provider. Com uma chave nova do Gemini, `gemini-2.5-flash`
**aparecia na listagem** e respondia **404 `no longer available to new users`** ao ser chamado.
Confirme cada ID com **uma requisição de verdade** antes de escrever no perfil. Free tier também
devolve **429 por modelo** (os `pro` costumam ter quota zero) — 429 num modelo e sucesso em
outro é quota, não config.

### Medido de verdade (2026-07-19), não teórico

Testes reais com **Ollama** via LiteLLM nesta base de código:

- **`ollama_chat`, NÃO `ollama` — é o erro de config que mais custa tempo.** Com
  `Provider = 'ollama'` o LiteLLM usa a API legada e força `format: json`: o `gpt-oss:20b`
  devolvia **vazio** e o `mistral-small3.1:24b` devolvia **uma definição de tool em JSON** no
  lugar da resposta. Trocando só o prefixo para `ollama_chat` (API de chat, tool support
  nativo), a mesma requisição respondeu `OK`. Mesma máquina, mesmo modelo, só o provider mudou.
- **Tool use local continua não confiável**, mesmo com `ollama_chat`: pedir para ler um arquivo
  de 3 linhas e contar devolveu um número inventado — o modelo alucinou em vez de chamar a
  tool. **Texto funciona; trabalho agentivo não.**

**O que isso significa na prática:** se um modelo local voltar vazio ou cuspindo JSON,
**suspeite da config antes do modelo** — `ollama` vs `ollama_chat` explica a maioria dos casos.
Uma vez respondendo texto, a limitação restante é real e é do modelo: recomende perfil local
para chat/tarefa simples, não para trabalho agentivo. Modelos de fronteira por API (GPT,
Gemini) não têm o problema de tool use.

## Passo 6 — escrever o perfil e validar de verdade

Acrescente o perfil ao `profiles.psd1` (preservando o resto) e valide:

```powershell
claudex -List     # o perfil novo aparece?
claudex -Check    # motor presente, segredo resolve?
```

`-Check` verde **não** significa que funciona — significa que a config está coerente. A
validação real é uma mensagem de ida e volta:

```powershell
claudex -Profile <nome> -- -p "responda apenas OK"
```

**Num perfil multi-provider, um teste só não basta:** o comando acima exercita apenas o modelo
default. Teste **cada entrada do catálogo** pelo nome — é o único jeito de provar que a
credencial de cada uma resolve:

```powershell
claudex -Profile <nome> -- --model <id-modelo-1> -p "responda apenas OK"
claudex -Profile <nome> -- --model <id-modelo-2> -p "responda apenas OK"
```

Se todas responderem, está funcionando ponta a ponta. **Só declare sucesso depois desse teste**
— não antes. Se falhar, o erro do motor é a pista: para `litellm`, o processo loga a razão da
recusa do provider (ID de modelo errado, chave inválida, param não aceito). Falha em **uma**
entrada e sucesso em outra aponta credencial, não encanamento.

Por fim, mostre ao usuário como usar no dia a dia:

```powershell
claudex                      # Anthropic normal (default, intocado)
claudex -Profile <nome>      # sob o perfil novo
# lá dentro: /model <nome-do-catalogo> alcança qualquer modelo; /models lista todos com
# nome real e descrição (o picker mostra só Opus/Sonnet/Haiku, que são atalhos)
```

## Limites que você NÃO deve contornar em silêncio

- Não peça nem escreva chave de API no chat, em arquivo versionado, ou na linha de comando.
- Não invente ID de modelo, URL de painel, nem flag de CLI — confirme na doc ou marque como
  não-verificado.
- Não afirme que o perfil funciona antes do teste de ida e volta do Passo 6 — e num catálogo
  multi-provider, testado **por entrada**, não só o default.
- Não prometa entrada nova na **lista visual** do `/model`: isso não existe, e não é o teto. O
  teto é o catálogo inteiro via `/model <nome>`; os 3 slots são atalhos opcionais do picker.
- Não diga ao usuário que ele perde os modelos Anthropic ao usar um perfil `proxy` — não perde,
  se houver entrada `anthropic` no catálogo ou slot não declarado.
