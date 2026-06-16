# DESIGN: {Nome da Feature}

> Design técnico para implementar {Nome da Feature}.

## Metadados

| Atributo | Valor |
|----------|-------|
| **Feature** | <FEATURE> |
| **Data** | {AAAA-MM-DD} |
| **DEFINE** | [DEFINE_<FEATURE>.md](./DEFINE_<FEATURE>.md) |
| **Status** | Rascunho / Pronto para Build |

---

## Visão de arquitetura

```text
┌────────────────────────────────────────────────┐
│  {diagrama ASCII: componentes e fluxo de dados} │
│  [Entrada] → [Componente A] → [Componente B] → [Saída]
│                   ↓                ↓            │
│              [Storage]       [API externa]      │
└────────────────────────────────────────────────┘
```

## Componentes

| Componente | Responsabilidade | Tecnologia |
|------------|------------------|------------|
| {A} | {o que faz} | {stack} |
| {B} | {…} | {…} |

## Data Flow
{passo a passo de como os dados percorrem o sistema}

## Integration Points
{APIs, serviços, bancos, filas — contratos de entrada/saída}

## Testing Strategy
{quais testes provam cada Acceptance Test do DEFINE: unit, integração, e2e}

## Error Handling
{falhas esperadas, retries, fallback, mensagens}

## Security
{validação de input, segredos, autenticação/autorização, dados sensíveis}

## Observability
{logs, métricas, traços — o que medir e como verificar em produção}

## Localização e infra
- **Onde o código mora:** {caminho}
- **Mudanças de infra/IaC:** {recursos novos/alterados ou N/A}

---

**Próximo passo:** `/build .claude/sdd/features/DESIGN_<FEATURE>.md`
