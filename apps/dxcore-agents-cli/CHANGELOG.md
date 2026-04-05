# @repo/dxcore-agents-cli

## 0.3.0

### Minor Changes

- 1f6f9d9: Add --help/-h flag support and rename binary from dxcore-agents to dxcore.
  - Add Help module with top-level and per-subcommand help output
  - Extract Config subcommand into its own module
  - Add @help/@shortdoc module attributes with Command behaviour for compile-time enforcement
  - Rename escript binary from dxcore-agents to dxcore (#1412)
  - Update all CLI documentation references to use new binary name

### Patch Changes

- 4e425fd: Revamp Claude Code instruction files: replace AGENTS.md with per-app CLAUDE.md, add branch protection hook, add PR workflow and Phoenix conventions skills, rewrite root CLAUDE.md from 740 to 118 lines.

## 0.2.1

### Patch Changes

- 46e470f: Fix flaky await_exit test race condition by using Process.info(:monitored_by) to deterministically verify monitor establishment instead of timing-based sleep

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
