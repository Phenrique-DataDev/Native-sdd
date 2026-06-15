# Mapa de agentes

> ⚠️ **Gerado por /sync-context — não editar à mão.** Rode /sync-context para atualizar.

## Grafo

```mermaid
graph TD
    user([Usuário]) --> lead[Sessão principal / agente líder]

    subgraph CMD["Slash commands"]
        c_adapt["/adapt"]
        c_audit_agents["/audit-agents"]
        c_brainstorm["/brainstorm"]
        c_build["/build"]
        c_define["/define"]
        c_design["/design"]
        c_dev["/dev"]
        c_init["/init"]
        c_orchestrate["/orchestrate"]
        c_review["/review"]
        c_setup["/setup"]
        c_ship["/ship"]
        c_skill_gap["/skill-gap"]
        c_sync_context["/sync-context"]
        c_telemetry["/telemetry"]
        c_train_kb["/train-kb"]
        c_update_skills["/update-skills"]
    end

    subgraph CORE["Subagents genéricos"]
        a_code_reviewer["code-reviewer"]
        a_explorer["explorer"]
        a_test_writer["test-writer"]
    end

    %% Agentes de domínio: nenhum (surgem via /audit-agents)

    lead --> CMD
    lead --> CORE
```
