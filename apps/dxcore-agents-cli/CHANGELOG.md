# @repo/dxcore-agents-cli

## 0.2.0

### Minor Changes

- 08d78da: Integrate DxCore distributed task execution system into joinwith monorepo
  - Add dxcore-core shared library (scheduler, task graph, plugin behaviour)
  - Add dxcore-coordinator-oss Phoenix app (API-only, WebSocket channels)
  - Add dxcore-agents-cli Elixir CLI (agent, dispatch, ci subcommands)
  - Add dxcore-coordinator-saas Phoenix app (Ecto/Postgres, smart scheduling, tenant management)
  - Add 4 GitHub Action composite action packages (coordinator, agent, dispatch, shutdown)
  - Add infra-dxcore Pulumi stack for DigitalOcean Kubernetes deployment
  - Add OSS sync workflow for one-directional sync to public repos
