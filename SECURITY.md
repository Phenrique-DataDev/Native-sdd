# Política de segurança / Security policy

## Versões com suporte / Supported versions

Só a **última release** recebe correção. O bootstrap sempre instala a versão atual, então
atualizar é o caminho para receber o fix.

*Only the latest release is supported.*

## Como reportar / Reporting a vulnerability

**Não abra issue pública.** Use o reporte privado do GitHub:
[**Report a vulnerability**](https://github.com/Phenrique-DataDev/Native-sdd/security/advisories/new)
(aba *Security* do repositório).

*Do not open a public issue. Use GitHub's private vulnerability reporting (Security tab).*

Inclua a versão (`~/.claude/.native-sdd-version`), o sistema, os passos para reproduzir e o impacto
que você vê.

## O que conta como vulnerabilidade aqui

O framework instala ferramentas e grava hooks que rodam em toda sessão do Claude Code. Por isso,
estes são os casos que importam:

- o bootstrap ou o instalador executando ou baixando algo diferente do que declaram;
- um hook de segurança (`secret-guard`, `destructive-guard`, pre-commit anti-segredo) que pode ser
  contornado sem o usuário saber;
- segredo ou dado pessoal que o framework grava, registra em log ou versiona sem pedir.
