# @repo/dxcore-core

## 0.6.0

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

## 0.5.0

### Minor Changes

- b22fcd7: DxCore distributed CI reliability improvements: log agent tags on connect, handle dispatcher session_finished, remove idle timeout, narrow zig requirements, topology-aware unassignable task detection

## 0.4.0

### Minor Changes

- 40af799: Add Gradle build system adapter and graph contraction
  - Add `cacheable` boolean field to Task struct in dxcore-core (defaults true, backward compatible)
  - Add `TaskGraph.contract/1` — generic graph contraction that absorbs non-cacheable intermediate tasks, keeping cacheable split points and leaf goals
  - NullPlugin now applies contraction via `expand_graph/2`
  - New Gradle adapter implementing BuildSystem behaviour with `parse_graph/1` and `task_command/3`
  - DxCore Gradle plugin (buildSrc) that introspects `@CacheableTask` annotations and exports contracted DAG
  - Example Gradle monorepo with 3 Java modules and CI workflow

## 0.3.0

### Minor Changes

- 355e356: Add configurable CI failure strategy and structured run summary.
  - Scheduler: `:skipped` status, `failure_strategy` option (fail-fast/continue-all), `summary/1` function, extended `TaskState` with `exit_code`/`duration_ms`/`cache_status`/`completed_by`
  - Coordinators: ETS-based task log buffering, summary included in `run_complete` events, failure strategy resolution from payload/org settings/app config
  - SaaS: `organization_settings` table with `failure_strategy`, CI Configuration section in org settings UI
  - CLI: `--failure-strategy` flag, structured summary formatting and printing
  - Dispatch action: `failure-strategy` input

## 0.2.1

### Patch Changes

- 8b29e1d: Set per-app HEX_HOME to eliminate hex cache.ets race condition, enabling parallel `turbo run deps` execution.
  - Changed `deps` script to `HEX_HOME=$PWD/.hex mix deps.get` in all Elixir workspaces
  - Changed `clean-deps` to also remove `.hex` directory
  - Removed `--concurrency=1` from root `deps` task
  - Added `.hex` to turbo.json `deps` outputs and `.gitignore`

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
