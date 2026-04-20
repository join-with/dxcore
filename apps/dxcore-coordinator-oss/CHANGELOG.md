# @repo/dxcore-coordinator-oss

## 0.4.8

### Patch Changes

- Updated dependencies [92f6c1e]
  - @repo/repo-cli@0.7.0

## 0.4.7

### Patch Changes

- d5e8ba3: Wire prom_ex dashboard auto-upload so default BEAM / Phoenix / Ecto panels reach Grafana on boot.

  Pulumi already injects `GRAFANA_DASHBOARD_URL` and `GRAFANA_DASHBOARD_API_KEY` into Phoenix pods, but nothing read them — so prom_ex never received a `grafana:` config block and the bundled dashboards never uploaded.

  Changes:
  - Add `JwObservability.PromEx.runtime_config/1` reading the two env vars. Returns `[]` when either is missing so dev/test keep working without credentials.
  - Call it from each app's `runtime.exs` to merge a `grafana:` entry into the PromEx config alongside the existing `metrics_server:` set in `config.exs`.
  - Each app uploads to its own Grafana folder (`PromEx / <otp_app>`) to avoid dashboard-title collisions across the six apps sharing one tenant.

- Updated dependencies [448f6dc]
  - @repo/repo-cli@0.6.2

## 0.4.6

### Patch Changes

- ad48b18: Move Prometheus `/metrics` to a dedicated prom_ex HTTP server on port 4021, separate from the main Phoenix endpoint.

  The metrics port is never exposed via ingress, so external clients can't reach it — eliminating the attack surface that the IP-allowlist + X-Forwarded-For workaround was guarding. This also removes the need for per-app force_ssl exclusions.

  Changes:
  - Add `metrics_server: [port: 4021, path: "/metrics", protocol: :http]` to each Phoenix app's PromEx config
  - Remove `plug JwObservability.MetricsPlug` from each app's endpoint.ex
  - Delete `JwObservability.MetricsPlug` module and its test
  - Expose port 4021 as a named container port (`metrics`) in the K8s deployment
  - Point `prometheus.io/port` scrape annotation at 4021
  - Revert the lingo-place `/metrics` force_ssl exclude from #1868 (moot now)

## 0.4.5

### Patch Changes

- 87f5979: Bind Phoenix endpoints to IPv4 `{0, 0, 0, 0}` instead of IPv6 `::` so pod-to-pod Prometheus scrapes from Alloy succeed. Bandit binds `::` IPv6-only by default (not dual-stack), causing `up=0` on all Alloy scrape targets. Styleguide already had the correct binding — this aligns the rest.
- Updated dependencies [0bdf827]
- Updated dependencies [62b343a]
  - @repo/repo-cli@0.6.1

## 0.4.4

### Patch Changes

- 8f3e5b1: Add Grafana Alloy DaemonSet for log collection (Loki) and metrics scraping (Mimir). Add prom_ex Prometheus metrics with BEAM, Phoenix, and Ecto plugins to all Phoenix apps via JwObservability.PromEx macro. Secure /metrics endpoint with IP allowlist plug. Add Prometheus scrape annotations to Phoenix pod templates.
- 9c977ba: CI/CD workflow tuning: bump runner sizes, drop universal github-release tag, remove dead linux-builder-image script.
  - Bump CI Agent and Release Agent runners to `ubicloud-standard-4`
  - Remove `github-release` from `dxcore.requirements` in agents-cli and all dxcore action packages
  - Remove entire `dxcore` block from dxcore-coordinator-oss and dxcore action packages (metadata cleanup)
  - Delete dead `apps/linux-builder-image/scripts/build-app.sh` script
  - Refactor cd-deploy.yml to drop detect job and reconcile dev+prod in parallel

- Updated dependencies [37d1de4]
- Updated dependencies [8ba6bbe]
- Updated dependencies [e71c7e1]
  - @repo/repo-cli@0.6.0

## 0.4.3

### Patch Changes

- cef538c: Add observability stack: jw-observability package with OpenTelemetry (Grafana Cloud), Sentry error tracking, and structured JSON logging integrated into all Phoenix apps.
- Updated dependencies [b22fcd7]
- Updated dependencies [ee4ac1c]
  - @repo/dxcore-core@0.5.0
  - @repo/repo-cli@0.5.3

## 0.4.2

### Patch Changes

- Updated dependencies [e2c111f]
  - @repo/repo-cli@0.5.2

## 0.4.1

### Patch Changes

- Updated dependencies [a482526]
- Updated dependencies [74cb6a2]
  - @repo/repo-cli@0.5.1

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
