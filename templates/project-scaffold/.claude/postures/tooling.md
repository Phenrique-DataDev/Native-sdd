# Tooling — a camada `tools/` em detalhe (sob demanda)

> **Carregada sob demanda**, não always-on. O essencial — a cascata e o snippet — está na rule
> [`../rules/tooling.md`](../rules/tooling.md), que carrega em toda sessão. Leia **este** arquivo
> quando um passo quebrar logo depois de dot-source de `tools/`, quando precisar de escopo limpo, ou
> antes de mexer em como um command resolve a camada.

## Princípio

A camada `tools/` é a metade **determinística** da metodologia (parsing de frontmatter,
inventários, gates) — o oposto de pedir ao modelo para improvisar. Mas no **projeto-alvo** o
`cwd` é o projeto e `tools/` não está presente por path relativo. Em vez de cada command adivinhar
onde estão os scripts, há **uma** cascata de resolução, definida na rule e referenciada por todos.

## O dot-source liga o `Set-StrictMode` no SEU shell — e ele não desliga sozinho

**Todo** script de `tools/` que os commands dot-sourceiam declara `Set-StrictMode -Version Latest`
em escopo de script. Dot-source **roda no escopo do chamador** — então o modo estrito passa a valer
na **sua sessão**, e continua valendo depois que o passo terminou.

**Isto é o comportamento correto, não um bug** — o `Set-StrictMode` está certo para quem executa o
script. O que faz mal é a **surpresa**: depois de um `/check`, ler uma variável nunca atribuída
**lança** em vez de devolver `$null`, inclusive em código que não tem nada a ver com o command.

| O que muda depois do dot-source | Antes | Depois |
|---|---|---|
| `$naoAtribuida` | `$null` | **lança** `RuntimeException` |
| propriedade inexistente / índice fora de faixa | `$null` | **lança** |

**Como conviver — nesta ordem:**

1. **Aceite, que é o normal.** Código bem-comportado não lê variável não atribuída. Se o seu passo
   quebrou logo depois de um dot-source, **suspeite disto antes de suspeitar do script**.
2. **Precisa do escopo limpo?** Rode em **subprocesso** — `pwsh -NoProfile -File "$toolsRoot/x.ps1"`
   ou `pwsh -NoProfile -Command "..."`. O modo morre com o processo. **Custo:** você recebe **texto**,
   não objeto — só serve quando o que interessa é a saída, não o valor de retorno.
3. **Nunca** faça `Set-StrictMode -Off` para "consertar" — isso desliga a checagem para o resto da
   sessão, inclusive para os próprios scripts que dependem dela.

> **Não é motivo para trocar o padrão.** Os commands dot-sourceiam **de propósito**, para chamar as
> funções; o subprocesso é a saída **pontual** de quem precisa do escopo limpo, não a regra geral.

## Como aplicar

1. **Resolva `$toolsRoot`** com o snippet da rule (a cascata, não um path fixo).
2. **Dot-source pela raiz resolvida:** `. "$toolsRoot/<script>.ps1"`. Os scripts ancoram as próprias
   dependências em `$PSScriptRoot` — resolver o entry-point basta; o resto segue junto.
3. **Sem `$toolsRoot`** (degrau 3) → **avise** o usuário ("camada `tools/` indisponível — reinstale o
   onboarding ou use `nsp`") e faça o passo à mão; **não** reimplemente em silêncio nem quebre.
4. **Não hardcode** `$env:SDD_WORKFLOW_HOME/tools` direto — a var pode faltar (onboarding antigo que só a gravava no `$PROFILE`/rc, ou sessão sem nenhum dos dois);
   é por isso que a cascata tenta o relativo primeiro e degrada por último.

## O que NÃO fazer

- Não escrever `. tools/<script>.ps1` **cru** (path relativo fixo) — não resolve no projeto-alvo.
  (Verificado por `tools/command-lint.ps1`: dot-source cru de `tools/` **bloqueia o CI**.)
- Não confundir com a **camada de KB `tools/`** (4ª camada da taxonomia, em `kb-taxonomy.md`) — é
  homônima, mas é conhecimento, não script.
- Não falhar quando a camada não resolve — a degradação consciente é o caminho normal fora do framework.
- Não rodar `Set-StrictMode -Off` depois de um dot-source de `tools/` — o modo estrito passa a valer
  no seu shell **por construção** (seção acima); desligá-lo afeta a sessão inteira, inclusive os
  scripts que contam com ele. Quem precisa de escopo limpo usa **subprocesso**, não `-Off`.
