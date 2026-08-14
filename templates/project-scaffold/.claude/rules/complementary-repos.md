# Repositórios complementares — referência read-only (postura, opt-in)

> **Regra condicional.** Outros repositórios do próprio usuário, registrados em
> `.claude/complementary-repos.psd1`, podem ser consultados como **referência read-only** — nunca
> vendorizados, nunca escritos. A disciplina completa **não é always-on**: ela vive em
> [`../postures/complementary-repos.md`](../postures/complementary-repos.md) e só é carregada quando
> o predicado abaixo é verdadeiro.

## Predicado observável

**`.claude/complementary-repos.psd1` existe?**

| Resposta | O que fazer |
|----------|-------------|
| **Não** (default de todo projeto novo) | **Nada.** Não há registro, não há o que consultar, a postura fica em **silêncio total**. Não crie o arquivo sozinho — ele só nasce de `/complementary-repos add`. **Pare aqui.** |
| **Sim** | Antes de consultar qualquer repo do registro, **leia** `.claude/postures/complementary-repos.md` (ferramenta `Read`) — ciclo CONSULTAR→RESOLVER→LER→ADAPTAR, boundary read-only e red flags. |

## O mínimo que vale mesmo sem ler a postura

Se você encostar num repo complementar, estas três valem sempre — o resto está na postura:

- **Read-only absoluto.** Nunca editar/criar/apagar dentro de um `Path` registrado ou do cache de
  clone. Backstop determinístico: hook `complementary-repo-guard` (`PreToolUse`, `Write|Edit`) pede
  confirmação. Escrita via `Bash` bruto **não** é interceptada — a disciplina cobre esse caso.
- **Nunca vendorizar.** Adaptar não é copiar: reimplemente no contexto local, jamais copie
  arquivo/módulo inteiro.
- **Cite a origem** (repo + caminho) no código/commit do que você adaptou.

> **Por que esta rule é curta:** ela custava ~2 400 tokens em **toda** sessão para, na maioria delas,
> concluir "não há registro, silêncio total". O custo agora acompanha a capacidade real do projeto —
> a disciplina não foi removida, foi movida para onde é lida por quem vai usá-la.
