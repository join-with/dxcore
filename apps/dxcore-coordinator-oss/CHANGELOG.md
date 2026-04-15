# @repo/dxcore-coordinator-oss

## 0.4.0

### Minor Changes

- 6f70df3: Org-slug channel topic isolation and binary release support.
  - dxcore-agents-cli: CLI auto-discovers org slug via /api/whoami for channel isolation (#1667), Burrito binary build (#1669)
  - dxcore-coordinator-oss: topic assigns in channels (#1667), OTP release tarball build (#1669)

## 0.3.3

### Patch Changes

- edf5a3e: State-scanning CD pipeline: replace event-chaining with turbo-task-driven state reconciliation
  - Add `repo-cli hash map` command for content hash generation
  - Add `repo-cli release bump` command for release.json state management
  - Add `repo-cli release publish` command with docker/github-release/npm strategies
  - Add `repo-cli deploy bump` command for Pulumi imageTag reconciliation
  - Add `hash`, `release-bump-dev/prod`, `release-dev/prod`, `deploy-bump-dev/prod`, `deploy-dev/prod` turbo tasks
  - Add `release.json` per releasable package for tracking release state
  - Add cd-release-bump.yml, cd-release.yml, cd-deploy-bump.yml, cd-deploy.yml workflow shells
  - Add cd-auto-merge.yml for auto-approving dev PRs
  - Add synthetic infra→app dependencies for turbo hash propagation
  - Augment version-packages with release-bump-prod for changeset PR integration
  - Seed Pulumi.dev.yaml imageTag fields for deploy-bump compatibility

## 0.3.2

### Patch Changes

- 40af799: Add Gradle build system adapter and graph contraction
  - Add `cacheable` boolean field to Task struct in dxcore-core (defaults true, backward compatible)
  - Add `TaskGraph.contract/1` — generic graph contraction that absorbs non-cacheable intermediate tasks, keeping cacheable split points and leaf goals
  - NullPlugin now applies contraction via `expand_graph/2`
  - New Gradle adapter implementing BuildSystem behaviour with `parse_graph/1` and `task_command/3`
  - DxCore Gradle plugin (buildSrc) that introspects `@CacheableTask` annotations and exports contracted DAG
  - Example Gradle monorepo with 3 Java modules and CI workflow

## 0.3.1

### Patch Changes

- 78e4350: Fix dispatcher timeout when task graph is empty (0 tasks)
  - Broadcast run_complete immediately when submit_graph receives an empty graph
  - Prevents 600s timeout in CI when turbo --affected finds no work

## 0.3.0

### Minor Changes

- 355e356: Add configurable CI failure strategy and structured run summary.
  - Scheduler: `:skipped` status, `failure_strategy` option (fail-fast/continue-all), `summary/1` function, extended `TaskState` with `exit_code`/`duration_ms`/`cache_status`/`completed_by`
  - Coordinators: ETS-based task log buffering, summary included in `run_complete` events, failure strategy resolution from payload/org settings/app config
  - SaaS: `organization_settings` table with `failure_strategy`, CI Configuration section in org settings UI
  - CLI: `--failure-strategy` flag, structured summary formatting and printing
  - Dispatch action: `failure-strategy` input

## 0.2.2

### Patch Changes

- 8b29e1d: Set per-app HEX_HOME to eliminate hex cache.ets race condition, enabling parallel `turbo run deps` execution.
  - Changed `deps` script to `HEX_HOME=$PWD/.hex mix deps.get` in all Elixir workspaces
  - Changed `clean-deps` to also remove `.hex` directory
  - Removed `--concurrency=1` from root `deps` task
  - Added `.hex` to turbo.json `deps` outputs and `.gitignore`

## 0.2.1

### Patch Changes

- 4e425fd: Revamp Claude Code instruction files: replace AGENTS.md with per-app CLAUDE.md, add branch protection hook, add PR workflow and Phoenix conventions skills, rewrite root CLAUDE.md from 740 to 118 lines.

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
