# @repo/dxcore-coordinator-oss

## 0.5.11

### Patch Changes

- Updated dependencies [8c1239d]
  - @repo/dxcore-core@0.7.4

## 0.5.10

### Patch Changes

- e895b50: Remove the observability stack from the OSS coordinator.

  `dxcore-coordinator-oss` depended on the internal `jw_observability` package
  (Grafana Cloud + Sentry + OpenTelemetry) via `{:jw_observability, path:
"../../packages/jw-observability"}`. The public `join-with/dxcore` mirror does
  not sync that package, so every release build in the public repo failed with
  `** (Mix) Can't continue due to errors on dependencies`.

  The open-source coordinator should not require the proprietary telemetry
  plumbing, so this removes it entirely: the `jw_observability` dep (Elixir and
  JS workspace), the `DxCore.Agents.PromEx` module and its supervision child, the
  `JwObservability.setup/1` boot call, the `Sentry.PlugCapture`/`Sentry.PlugContext`
  endpoint plugs, the OpenTelemetry runtime config, and the now-unused transitive
  deps in `mix.lock`. The SaaS coordinator keeps its observability and is
  unaffected.

## 0.5.9

### Patch Changes

- Updated dependencies [e5cbe6e]
  - @repo/repo-cli@0.11.2
  - @repo/dxcore-core@0.7.3
  - @repo/jw-observability@0.3.5

## 0.5.8

### Patch Changes

- Updated dependencies [d40fd1a]
  - @repo/jw-observability@0.3.5

## 0.5.7

### Patch Changes

- 73b1fef: Wake idle agents when a task completion grows the scheduler frontier (#3215).

  `tasks_available` previously fired only at graph submission, so an agent that
  drained its queue while later work was still blocked behind another agent's
  long task was never re-woken — newly-unlocked tasks serialized onto the one
  agent still cycling. Both coordinators now re-broadcast `tasks_available` on
  the run-continues branch of the task-result handler, via a shared
  `ChannelHelpers.broadcast_tasks_available/3` helper (also used by the
  disconnect path). The Scheduler core is unchanged. Coordinator-only; no agent
  release required.

- Updated dependencies [73b1fef]
  - @repo/dxcore-core@0.7.3

## 0.5.6

### Patch Changes

- Updated dependencies [4836457]
  - @repo/repo-cli@0.11.1
  - @repo/dxcore-core@0.7.2
  - @repo/jw-observability@0.3.4

## 0.5.5

### Patch Changes

- ac6793b: Add `repo-cli deps sync` and `repo-cli deps lint` for keeping `package.json`
  workspace deps in sync with Elixir `mix.exs` path deps. Bootstrap migration
  mirrors path deps across every Mix consumer — Turbo's hash graph now sees
  library changes that previously slipped past release-bump (#2101).

  The patch bump on every Mix consumer reflects the package.json content
  churn from the bootstrap migration; it has no functional behavior change.

- Updated dependencies [ac6793b]
  - @repo/repo-cli@0.11.0
  - @repo/dxcore-core@0.7.2
  - @repo/jw-observability@0.3.4

## 0.5.4

### Patch Changes

- Updated dependencies [3ae837b]
  - @repo/repo-cli@0.10.0

## 0.5.3

### Patch Changes

- Updated dependencies [a16fda9]
  - @repo/repo-cli@0.9.1

## 0.5.2

### Patch Changes

- a45dab6: Fix cross-pod race where agents miss the initial `tasks_available` broadcast on the multi-pod SaaS coordinator (#2143). The dispatcher's `submit_graph` now carries the freshly-spawned scheduler's pid + run_id in the `tasks_available` PubSub payload; agent channels read those directly and call `Scheduler.request_task/3` without going through `Horde.Registry`, which on a remote pod can lag the broadcast by up to one CRDT sync interval (~100 ms). The agent-side `try_assign_task/2` helper falls back to the legacy `Horde.Registry` lookup whenever the payload lacks a pid (covering reconnect/rehydration and any in-flight pre-upgrade broadcasts). Adds a `safe_request_task` wrapper so a stale-pid `:exit` doesn't crash the channel. OSS coordinator gets the same broadcast shape for symmetry even though it's single-node and not subject to the race.
- Updated dependencies [4446689]
- Updated dependencies [35dda4a]
- Updated dependencies [a45dab6]
  - @repo/dxcore-core@0.7.1

## 0.5.1

### Patch Changes

- 8f88bc9: Phase 2 of coordinator durability (#2026): cluster-aware scheduler placement. Schedulers can now be discovered across coordinator pods via `Horde.Registry`, and `Horde.DynamicSupervisor` redistributes them on node loss. Foundation for zero-downtime rolling deploys (Phase 3).

  **`@repo/dxcore-core`**
  - `Scheduler.start_link/1` accepts new options `:org_id` (required by SaaS, `nil` for OSS) and `:via_module` (defaults to a module read from `:dxcore_core, :scheduler_via_module` config; `Registry` for OSS, `Horde.Registry` for SaaS).
  - Registry key is now `{org_id, session_id, run_id}` instead of `{session_id, run_id}` so cross-tenant collisions are impossible at the Horde-CRDT level.
  - `Scheduler.whereis/3` and `Scheduler.list_for_session/2` now take `org_id` as the first argument. The 2-arg / 1-arg backward-compat wrappers were dropped — there is one obvious form, OSS callers pass `nil` explicitly.
  - `ChannelHelpers` macro reads `socket.assigns[:org_id]` so SaaS sockets scope lookups to the connected org and OSS sockets keep using the `nil` bucket.

  **`@repo/dxcore-coordinator-saas`**
  - New dependency: `:horde` (~> 0.9). Brings `:delta_crdt`, `:libring`, `:merkle_map` (already locked transitively).
  - `DxCore.SaaS.Application` swaps the local `Registry` (SchedulerRegistry) for `Horde.Registry` with `members: :auto` and a 100ms CRDT sync interval, and the local `DynamicSupervisor` (SchedulerSupervisor) for `Horde.DynamicSupervisor` with `Horde.UniformDistribution` and `process_redistribution: :active`. `AgentRegistry` stays a local Registry — per-pod presence is correct.
  - `DNSCluster` added to the supervision tree, queries the headless K8s Service via the `DNS_CLUSTER_QUERY` env var. Defaults to `:ignore` when unset (dev / single-pod CI).
  - New `rel/env.sh.eex` sets `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=dxcore@${POD_IP:-127.0.0.1}` for cross-pod connectivity. `POD_IP` is injected by the K8s Downward API in production.
  - All `DynamicSupervisor.{start_child,terminate_child,which_children}` call-sites in `agent_channel`, `dispatcher_channel`, `admin`, and `sessions` updated to `Horde.DynamicSupervisor`.
  - `Admin.kill_run/4`, `Admin.terminate_session/3`, `Admin.count_active_schedulers/2`, and `Sessions.terminate_schedulers/3` take `org_id` as the first argument; LiveView callers updated.
  - Sockets set `socket.assigns.org_id = organization.id` on join so the registry lookup is org-scoped end-to-end.

  **`@repo/dxcore-coordinator-oss`**
  - OSS coordinator stays single-pod by design and is unchanged in supervision shape, but call-sites updated to the new `Scheduler.whereis/3` and `list_for_session/2` signatures (passing `nil` for `org_id`).
  - `DxCore.Agents.Scheduler.whereis` defdelegate updated to `whereis/3`.

  **Out of scope (Phase 3)**
  - `replicas: 2`, `maxSurge`, `maxUnavailable`, PDB, `terminationGracePeriodSeconds`, `preStop` hook
  - `Release.drain/0` for graceful Horde handoff
  - `infra-dxcore` deploy strategy

  **Test coverage**
  - New cross-org isolation test in `dxcore-core` — schedulers in different orgs do not collide on the same `{session_id, run_id}`
  - All existing 728 SaaS tests, 84 dxcore-core tests, and 116 OSS tests pass
  - True multi-node `:peer.start_link` integration test deferred to #2035 (needs Ecto sandbox-across-nodes design work)

- Updated dependencies [8f88bc9]
  - @repo/dxcore-core@0.7.0

## 0.5.0

### Minor Changes

- 4ff4dd4: Phase 1 of coordinator durability (#2019): rehydrate scheduler state from Postgres so an agent's `task_result` is processed even after the live scheduler PID is lost (channel reconnect, supervisor restart, pod replacement).

  **`@repo/dxcore-core`**
  - `Scheduler.start_link/1` accepts new options `:skip_expand?` (default `false`) and `:rehydrate_from` (default `[]`).
  - `Scheduler.report_result/4` now requires `agent_id` and enforces a strict ACK rule — only the lease holder (assigned agent on a `:running` task) can acknowledge. Returns `{:error, :not_assigned}` or `{:error, :unknown_task}` on rejection. Fires `[:dxcore, :scheduler, :ack_rejected]` telemetry on rejections.
  - `TaskGraph.serialize/1` paired with the existing `parse/1` — round-trippable wire format used to persist post-expansion graphs.
  - Channel helpers' `task_started` broadcast targets the run-scoped dispatcher topic via `Scheduler.dispatcher_topic/1`.

  **`@repo/dxcore-coordinator-saas`**
  - New columns on `runs`: `graph_json` (jsonb), `failure_strategy` (string), `topology_check` (string), `topology` (jsonb). Migration is additive — all nullable.
  - New unique index on `task_results(run_id, task_id)`. SmartPlugin task-result inserts use `on_conflict: :nothing` for idempotent rehydration.
  - `submit_graph` now persists the post-expansion graph + run config so rehydration can reconstruct the same DAG the original scheduler ran with.
  - `task_result` channel handler rewritten to authorize the run via `RunAuthorization.authorize_run/3` (cross-org / cross-session protection), look up the scheduler via Registry, and rehydrate from Postgres on demand.
  - Dispatcher channel topic switched from session-scoped to run-scoped (`dispatcher:<org>:<run_id>`). Agents stay session-scoped (warm pool preserved). Joining a terminal run replies with status + summary in the join ack.
  - Two new JwAudit security events: `security.coordinator.unauthorized_run` and `security.coordinator.task_ack_rejected`.

  **`@repo/dxcore-coordinator-oss`**
  - Updated `Scheduler.report_result` defdelegate to the new 4-arg signature; `agent_channel` passes `agent_id` through.

  **`@repo/dxcore-agents-cli`**
  - Agent stores `current_run_id` from `assign_task` and echoes it in `task_result`, making the message self-describing for routing after channel reconnect.
  - Dispatcher CLI generates `run_id` before connecting and joins the run-scoped topic. `submit_graph` payload now carries `session_id`.

  Phases 2 (Horde clustering) and 3 (rolling-deploy strategy) follow in subsequent PRs.

### Patch Changes

- Updated dependencies [4ff4dd4]
  - @repo/dxcore-core@0.6.0

## 0.4.11

### Patch Changes

- Updated dependencies [d2ac461]
- Updated dependencies [e184a5e]
  - @repo/repo-cli@0.9.0

## 0.4.10

### Patch Changes

- Updated dependencies [88674d9]
  - @repo/repo-cli@0.8.1

## 0.4.9

### Patch Changes

- Updated dependencies [373a652]
- Updated dependencies [8f3ac5a]
  - @repo/repo-cli@0.8.0

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
