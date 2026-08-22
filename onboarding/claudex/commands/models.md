---
description: Mostra os modelos disponíveis no perfil claudex ativo, com nome real e descrição, e monta o /model para você trocar.
---

# /models — catálogo de modelos do perfil ativo

O `/model` (built-in) mostra um número **fixo** de linhas — Default, Opus, Sonnet, Haiku, Fable,
opusplan — mesmo quando esses slots apontam para Gemini ou um modelo local. Este comando mostra
**o que cada um realmente é** e quais outros modelos dá para chamar por nome.

## Passo 1 — UM comando, não seis

Rode exatamente isto. Ele já devolve a tabela pronta:

```powershell
pwsh -NoProfile -Command ". '$env:SDD_WORKFLOW_HOME\onboarding\claudex\claudex-lib.ps1'; Format-ClaudexModelsReport -Profiles (Import-ClaudexProfiles -Path (Join-Path (Get-ClaudexHome) 'profiles.psd1')) -ActiveProfile $env:CLAUDEX_PROFILE -SessionModel $env:ANTHROPIC_MODEL -SlotEnv @{ ANTHROPIC_DEFAULT_OPUS_MODEL = $env:ANTHROPIC_DEFAULT_OPUS_MODEL; ANTHROPIC_DEFAULT_SONNET_MODEL = $env:ANTHROPIC_DEFAULT_SONNET_MODEL; ANTHROPIC_DEFAULT_HAIKU_MODEL = $env:ANTHROPIC_DEFAULT_HAIKU_MODEL; ANTHROPIC_DEFAULT_FABLE_MODEL = $env:ANTHROPIC_DEFAULT_FABLE_MODEL }"
```

**Não decomponha isso em vários comandos.** A versão anterior deste arquivo mandava ler quatro
env vars, dot-sourcear a lib, importar o `.psd1` e chamar duas funções — seis round-trips para
montar uma tabela, e cada agente montava de um jeito. A normalização agora vive na
`Format-ClaudexModelsReport`, que é testada. Você **imprime o que ela devolveu**.

Se o comando falhar (lib ausente, `SDD_WORKFLOW_HOME` vazio), diga o erro real e pare — não
tente reconstruir a tabela na mão a partir de leituras soltas.

## Passo 2 — apresentar

Mostre a tabela como veio. Ela já traz, por modelo: como chamar, a **origem** (assinatura ·
API · local — é o que decide custo), qual atalho do picker aponta para ele, e a descrição do
perfil. O relatório também emite, quando for o caso:

- **Modelo inicial da sessão** — em qual o `claudex` abriu (`DefaultModel`/`ANTHROPIC_MODEL`).
- **Divergência perfil × sessão** — o `.psd1` foi editado depois do lançamento. Envs são lidas no
  **start**; relançar é o que faz valer.
- **Slots sem mapeamento** — sob `Backend='proxy'` isso é **defeito**, não neutralidade: escolher
  esse slot no picker manda o ID Anthropic embutido ao motor local e volta
  `400 Invalid model name`.

Regras de honestidade:

- **Todo** modelo do catálogo é chamável por `/model <nome-exato>` — verificado ao vivo. O
  catálogo não tem teto; o **picker** é que tem, e o teto dele é o número de linhas built-in.
- Sem `Notes` no perfil, a coluna fica **vazia**. Não invente descrição.
- Não prometa entrada nova na lista visual do `/model`: não é extensível (a exceção documentada
  é `availableModels` sob o endpoint Mantle do Bedrock, que não é o nosso caso).

## Passo 3 — a troca é do usuário

**Você NÃO troca o modelo sozinho.** `/model` é comando embutido da CLI, não é invocável por
agente — testado e confirmado. Não tente contornar escrevendo em settings, matando processo ou
reescrevendo perfil.

Use `AskUserQuestion` para ele escolher (dá nome real + descrição numa caixa), e entregue o
comando exato para ele digitar:

```
/model claude-sonnet-5
```

Se o modelo desejado já é o inicial da sessão, diga isso em vez de mandar trocar.

## Se o usuário quiser trocar de PERFIL (não de modelo)

Na maioria dos casos **ele não quer**: o perfil default já traz assinatura + chave de API +
modelos locais no mesmo catálogo. Confirme que o modelo não está no catálogo atual antes de
mandar alguém sair da sessão.

Se for mesmo o caso, não é `/model` — é relançar, porque as envs são lidas no **start**:

```powershell
exit
claudex                        # perfil default (catálogo completo)
claudex -Profile <outro>       # um perfil específico
```

`claudex -List` mostra o que existe · `claudex -Check` diagnostica (motor ausente, chave que não
resolve, login OAuth que nunca foi feito) · `/claudex-add-model` adiciona provider/modelo novo.
