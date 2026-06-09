# @repo/dxcore-agents-cli

## 0.8.6

### Patch Changes

- dc88f44: Disable Brainstretch Mobile dev release publishing until Play Store automation exists.
  - Remove the unimplemented Brainstretch Mobile `release-dev` publish script.
  - Filter Turbo dry-run tasks with `<NONEXISTENT>` commands from DxCore dispatch.

## 0.8.5

### Patch Changes

- Updated dependencies [e5cbe6e]
  - @repo/repo-cli@0.11.2

## 0.8.4

### Patch Changes

- 6f9708b: Fix WsClient crashing when slipstream's transport process exits between an alive check and a `GenServer.call` (the race seen during a coordinator rolling redeploy). `handle_cast({:push, ...})` and `handle_call({:push_and_wait, ...})` now wrap the call in `try/catch :exit` and surface `{:error, {:transport_down, reason}}` instead of taking the agent down. Reconnects continue to be driven by `handle_disconnect`. Closes #2357.
- Updated dependencies [4836457]
  - @repo/repo-cli@0.11.1

## 0.8.3

### Patch Changes

- ac6793b: Add `repo-cli deps sync` and `repo-cli deps lint` for keeping `package.json`
  workspace deps in sync with Elixir `mix.exs` path deps. Bootstrap migration
  mirrors path deps across every Mix consumer — Turbo's hash graph now sees
  library changes that previously slipped past release-bump (#2101).

  The patch bump on every Mix consumer reflects the package.json content
  churn from the bootstrap migration; it has no functional behavior change.

- Updated dependencies [ac6793b]
  - @repo/repo-cli@0.11.0

## 0.8.2

### Patch Changes

- Updated dependencies [3ae837b]
  - @repo/repo-cli@0.10.0

## 0.8.1

### Patch Changes

- Updated dependencies [a16fda9]
  - @repo/repo-cli@0.9.1

## 0.8.0

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

## 0.7.10

### Patch Changes

- Updated dependencies [d2ac461]
- Updated dependencies [e184a5e]
  - @repo/repo-cli@0.9.0

## 0.7.9

### Patch Changes

- Updated dependencies [88674d9]
  - @repo/repo-cli@0.8.1

## 0.7.8

### Patch Changes

- Updated dependencies [373a652]
- Updated dependencies [8f3ac5a]
  - @repo/repo-cli@0.8.0

## 0.7.7

### Patch Changes

- Updated dependencies [92f6c1e]
  - @repo/repo-cli@0.7.0

## 0.7.6

### Patch Changes

- Updated dependencies [448f6dc]
  - @repo/repo-cli@0.6.2

## 0.7.5

### Patch Changes

- Updated dependencies [0bdf827]
- Updated dependencies [62b343a]
  - @repo/repo-cli@0.6.1

## 0.7.4

### Patch Changes

- 9c977ba: CI/CD workflow tuning: bump runner sizes, drop universal github-release tag, remove dead linux-builder-image script.
  - Bump CI Agent and Release Agent runners to `ubicloud-standard-4`
  - Remove `github-release` from `dxcore.requirements` in agents-cli and all dxcore action packages
  - Remove entire `dxcore` block from dxcore-coordinator-oss and dxcore action packages (metadata cleanup)
  - Delete dead `apps/linux-builder-image/scripts/build-app.sh` script
  - Refactor cd-deploy.yml to drop detect job and reconcile dev+prod in parallel

- 5db4f07: Fix Logger.Formatter crash on OTP SSL alert messages in Burrito binary.
  - Add primary Logger filter that wraps SSL `report_cb` callbacks in try/catch
  - Prevents `:undef` crash on `ssl_alert:own_alert_format/4` (elixir-lang/elixir#14020)
  - Add `:ssl` to `extra_applications` for explicit dependency

- Updated dependencies [37d1de4]
- Updated dependencies [8ba6bbe]
- Updated dependencies [e71c7e1]
  - @repo/repo-cli@0.6.0

## 0.7.3

### Patch Changes

- b22fcd7: DxCore distributed CI reliability improvements: log agent tags on connect, handle dispatcher session_finished, remove idle timeout, narrow zig requirements, topology-aware unassignable task detection
- Updated dependencies [ee4ac1c]
  - @repo/repo-cli@0.5.3

## 0.7.2

### Patch Changes

- e2c111f: Align dxcore CLI binary asset naming: Burrito target includes arch suffix, upload uses filename directly, consumer actions match.
- 5762010: Fix run summary table column alignment by computing widths dynamically instead of using hardcoded padding values.
- Updated dependencies [e2c111f]
  - @repo/repo-cli@0.5.2

## 0.7.1

### Patch Changes

- Updated dependencies [a482526]
- Updated dependencies [74cb6a2]
  - @repo/repo-cli@0.5.1

## 0.7.0

### Minor Changes

- 6f70df3: Org-slug channel topic isolation and binary release support.
  - dxcore-agents-cli: CLI auto-discovers org slug via /api/whoami for channel isolation (#1667), Burrito binary build (#1669)
  - dxcore-coordinator-oss: topic assigns in channels (#1667), OTP release tarball build (#1669)

## 0.6.0

### Minor Changes

- f94b66c: Add --command-template CLI flag to dxcore agent
  - New CommandTemplate module interpolates {package}, {task}, {hash}, {shard_index}, {shard_count}, {command} placeholders
  - Agent CLI accepts --command-template flag to override coordinator commands
  - Template errors report as task failures (exit_code: -1)
  - Documentation added to generic adapter configuration page

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

## 0.5.3

### Patch Changes

- 4da0b84: Nx adapter reads cacheable from task cache field, fix docs to use correct graph command
  - Read `cache` boolean from Nx task graph JSON and set `cacheable` accordingly
  - Fix all Nx docs to use `nx run-many --graph=stdout` (not `nx graph --file=stdout`)

## 0.5.2

### Patch Changes

- 200da69: Fix generic and Docker adapter agent-side crash by sending command in assign_task payload
  - Include command field in assign_task WebSocket message from coordinator
  - Agent uses command directly when present, falls back to adapter.task_command
  - Fix Make parser script: filter deps to task IDs only, use directory as package

## 0.5.1

### Patch Changes

- d5f3e5f: Add Gradle adapter documentation and update generic JSON docs
  - Add dedicated Gradle docs section (setup, configuration, example workflow) marked as experimental
  - Add Gradle to getting-started adapter table and prose
  - Replace stale Gradle example in generic JSON docs with a Make-based example
  - Add Gradle to generic adapter comparison list
  - Fix inaccurate Gradle adapter moduledoc

## 0.5.0

### Minor Changes

- 40af799: Add Gradle build system adapter and graph contraction
  - Add `cacheable` boolean field to Task struct in dxcore-core (defaults true, backward compatible)
  - Add `TaskGraph.contract/1` — generic graph contraction that absorbs non-cacheable intermediate tasks, keeping cacheable split points and leaf goals
  - NullPlugin now applies contraction via `expand_graph/2`
  - New Gradle adapter implementing BuildSystem behaviour with `parse_graph/1` and `task_command/3`
  - DxCore Gradle plugin (buildSrc) that introspects `@CacheableTask` annotations and exports contracted DAG
  - Example Gradle monorepo with 3 Java modules and CI workflow

## 0.4.0

### Minor Changes

- 355e356: Add configurable CI failure strategy and structured run summary.
  - Scheduler: `:skipped` status, `failure_strategy` option (fail-fast/continue-all), `summary/1` function, extended `TaskState` with `exit_code`/`duration_ms`/`cache_status`/`completed_by`
  - Coordinators: ETS-based task log buffering, summary included in `run_complete` events, failure strategy resolution from payload/org settings/app config
  - SaaS: `organization_settings` table with `failure_strategy`, CI Configuration section in org settings UI
  - CLI: `--failure-strategy` flag, structured summary formatting and printing
  - Dispatch action: `failure-strategy` input

## 0.3.1

### Patch Changes

- 8b29e1d: Set per-app HEX_HOME to eliminate hex cache.ets race condition, enabling parallel `turbo run deps` execution.
  - Changed `deps` script to `HEX_HOME=$PWD/.hex mix deps.get` in all Elixir workspaces
  - Changed `clean-deps` to also remove `.hex` directory
  - Removed `--concurrency=1` from root `deps` task
  - Added `.hex` to turbo.json `deps` outputs and `.gitignore`

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
