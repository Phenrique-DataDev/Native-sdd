# Contribuindo / Contributing

Obrigado por querer melhorar o Native-SDD. / *Thanks for wanting to improve Native-SDD.*

## Como este repositório funciona

Este repositório é o **espelho de distribuição**: a cada release ele é regerado a partir do
repositório de desenvolvimento, que tem a suíte de testes e o histórico de trabalho. Aqui roda só o
smoke do produto ([`smoke.yml`](https://github.com/Phenrique-DataDev/Native-sdd/actions/workflows/smoke.yml)): cria um projeto nos perfis `mvp` e
`full`, em Windows e Linux, e passa o `/check` e o pre-commit anti-segredo deles. Por isso:

- **Issue é o melhor caminho.** Relato de uso real, com o comando que você rodou e a saída, é o que
  mais muda o produto. Use os templates de [bug](https://github.com/Phenrique-DataDev/Native-sdd/issues/new?template=bug_report.yml) ou de
  [ideia](https://github.com/Phenrique-DataDev/Native-sdd/issues/new?template=feature_request.yml).
- **PR é bem-vindo como proposta.** Ele não entra com merge aqui: a mudança é reaplicada na fonte,
  passa pelos testes de lá e chega na próxima release.
- **Vulnerabilidade não vai em issue.** Veja o [`SECURITY.md`](SECURITY.md).

*This repository is a distribution mirror, regenerated on every release from the development
repository (which holds the test suite); only the product smoke test runs here. Issues with the exact command and output are the most useful
contribution. PRs are welcome as proposals: the change is re-applied at the source, tested there, and
ships in the next release.*

## O que ajuda num relato

1. A versão: `Get-Content ~/.claude/.native-sdd-version` e, num projeto, `.claude/.scaffold-version`.
2. O sistema e o shell (`pwsh 7.x`, Windows PowerShell 5.1, `bash`) e o `claude --version`.
3. O comando exato e a saída inteira, não um resumo dela.
4. O que você esperava, e onde o [`docs/USO.md`](docs/USO.md) diz que seria assim, se disser.

## Convenções

- Documentação em **português**, com termos e nomes de artefato em **inglês**.
- Scripts em **PowerShell 7+**. O `onboarding/bootstrap.ps1` é a exceção: roda também no Windows
  PowerShell 5.1 e só pode ter caracteres ASCII (o motivo está no cabeçalho dele).
- Commits no formato [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
  `docs:`…).

## Código de conduta

Quem participa segue o [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Licença

O projeto é distribuído sob a [licença MIT](LICENSE), e uma contribuição entra sob a mesma licença.
/ *The project is MIT-licensed, and contributions are accepted under the same license.*
