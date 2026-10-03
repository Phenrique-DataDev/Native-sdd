# Perfil pessoal (global)

> Config **user-level** (`~/.claude/CLAUDE.md`). Vale para **todos** os projetos.
> Regras de projeto têm precedência sobre estas quando houver conflito.

<!--
**Template** — comentários HTML como este não entram no contexto do Claude. Ajuste ao instalar:
*Identidade* (preencha e tire do comentário), *Preferências de comunicação* se o seu idioma não for
pt-BR, e *Git e autonomia* se quiser liberar o push sem confirmação.

## Identidade

- **Handle GitHub:** `<seu-handle-github>`
- **Email:** `<seu-email>`
- **Papel:** `<seu papel>` — ex.: Dados + Dev (híbrido), engenharia de dados e automação
- **Ambiente:** `<seu ambiente>` — ex.: Windows (PowerShell 7+), VSCode, Claude Code
-->

## Documentação de bibliotecas

- Com o MCP `context7` conectado (o onboarding o registra): dúvida sobre lib, framework, SDK,
  CLI ou serviço cloud → consulte-o **antes de responder**, mesmo se a lib for conhecida e a
  resposta parecer óbvia. O treino pode estar desatualizado.

## Preferências de comunicação

- **Responder sempre em pt-BR** — conciso e direto, sem preâmbulos.
- Ação concreta vale mais que explicação longa; mostrar o resultado, não o caminho.
- Termos técnicos e nomes de artefato em inglês quando for o padrão da ferramenta.
- Regra de projeto sobrepõe esta preferência.

<!--
**pt-BR é o default deste template, não uma imposição.** Se o seu time trabalha em outro idioma,
troque aqui **e** a menção em *Git e autonomia* (mensagens de commit) — são as duas.
-->

## Git e autonomia

- **Branch de trabalho:** pode **commitar** livremente em branches de feature/trabalho; **push**
  pede confirmação antes (push publica).
- **`main` / branch default:** **protegida** — nunca commitar/push direto nem fazer
  merge sem confirmação explícita.
- **Nunca** `push --force`, reset destrutivo ou rewrite de histórico compartilhado sem
  autorização explícita.
- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`…). Mensagens em pt-BR.
- Antes de criar branch, partir da default atualizada.

<!--
Para liberar o push em branch de trabalho, troque o primeiro item por: "pode **commitar e fazer
push** livremente em branches de feature/trabalho, sem pedir confirmação a cada passo".
-->

## Regras invioláveis

- **Nunca inventar dados** — usar apenas o que pode verificar (código, arquivos, saídas).
- **Não tocar `main`/produção** sem aprovação explícita.
- **Não versionar segredos** (tokens, PATs, `.env`) nem conteúdo confidencial de terceiros.
- Respeitar as regras do **projeto atual** (CLAUDE.md do projeto): em conflito, elas vencem este
  arquivo.
