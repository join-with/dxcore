# @repo/dxcore-core

## 0.10.0

### Minor Changes

- 9b36bc5: The scheduler can be restarted mid-run without losing the run (#11951). It loads the run's finished tasks and in-flight leases every time it starts, from the `:state_loader` start option or, when a child spec has none, from the `:dxcore_core, :scheduler_state_loader` app env. So a scheduler that Horde restarts from its original options (when a deploy drains a pod) keeps finished tasks finished and in-flight tasks on the agent running them. The load runs in `handle_continue`, not in `init`. A failed load is retried with backoff (`:state_load_backoff_ms`, 3.1 s in total by default); if it still fails the scheduler stops with `{:shutdown, {:state_load_failed, reason}}` instead of starting from the bare graph, and the scheduler is now `restart: :transient`, so that stop is not restarted into a crash loop. A rehydrated result's `exit_code` is kept. A restored lease whose agent does not come back is released after `:lease_grace_ms`. An agent that reports a result no longer keeps a task that was pushed to it while it was busy. A released task is skipped instead of re-run once a `fail_fast` run has failed. An agent whose connection drops can keep its tasks for the same window (`Scheduler.hold_agent/2`, used by `ChannelHelpers` for agents that say in `agent_ready` what they run), so a pod drain that closes a busy agent's socket no longer hands its task to a second agent; other agents still release at once, and a disconnect from a scheduler that has stopped no longer skips the rest of the disconnect handling. Each held-lease check emits `[:dxcore, :scheduler, :held_leases_checked]` with the leases it released, kept and left waiting. New: `Scheduler.hold_agent/2`, `Scheduler.release_agent/3` (`reassign_task/2` now releases every task of the agent), the optional `on_task_assigned/3` and `on_task_released/2` plugin callbacks, and `Scheduler.offline_summary/4`.

## 0.9.0

### Minor Changes

- b091dee: The coordinator stops holding every streamed CI log line in memory, and caps what it accepts inbound (#11028).
  - `TaskLogBuffer` keys lines by `{session_id, run_id, task_id}`: `buffer/5`, `get_output/4` and the new `delete_task/4` take the run, and `cleanup/3` drops one run instead of the whole session, so runs sharing a session (the dispatch jobs of one CI workflow run) no longer read or delete each other's lines. A line with no known run (after a reconnect) is kept under a nil run and still read with the run's output. `ChannelHelpers.try_assign_task` records the assignment on the socket (`current_assignment`), and `ChannelHelpers.log_run_id/2` reads it back. It also gains `memory_bytes/1` and a hard `:max_bytes` cap (default 128 MiB) on the table's real memory: ETS plus the off-heap bytes of the lines it holds. Lines are stored as copies, so a line no longer keeps its whole WebSocket frame alive. At the cap, new lines are dropped, the task's output ends with `[dxcore: N log lines dropped, buffer full]`, and the next sweep logs and reports how many (`dropped` and `memory_bytes` in the `[:dxcore, :task_log_buffer, :sweep]` measurements). On the night of the kills a line cost about 278 bytes with its frame, and CI streamed 3.6 to 3.9 million lines inside the buffer's 2-hour TTL, up to 1 GB across the two pods.
  - The SaaS agent channel drops a task's lines once the scheduler accepts its exit 0 (a rejected report deletes nothing), since only a failed task's output is read, and cuts any line over 16 KiB at a UTF-8 boundary. A malformed `task_log` or `task_result`, including a non-object payload, is logged and dropped.
  - `runs.graph_json` is no longer decoded by every run query (`load_in_query: false`; 1.8 MB a run for the full-repo graph, so 184 MB for a dashboard showing 100 running runs). Rehydration reads it explicitly through `Runs.load_graph_json/1`.
  - Socket frames are capped: 8 MiB on `/dispatcher` (the full-repo graph is 0.85 MB), 1 MiB on `/agent` and `/live`. An over-cap frame closes the socket with 1009 instead of being read.
  - Any inbound socket message or HTTP body of 256 KiB or more is logged with its size and source and emitted as `[:dxcore, :inbound, :large_message]`.
  - The OSS agent channel files task-log lines per run and cleans up per run on completion, through the same `TaskLogBuffer` API.

### Patch Changes

- 888d150: The `deps` script now empties its own `deps` (and `.hex`, or the Playwright browsers folder) before fetching, so a cache restore that fails partway can no longer leave a half-restored dependency that the fetch takes as installed and that is then uploaded to the shared build cache (#11002).

## 0.8.0

### Minor Changes

- c544d37: Add a periodic TTL sweep to `TaskLogBuffer` so log lines from runs that never reach a terminal status are reclaimed instead of accumulating in ETS forever.
  - New `start_link/1` opts `:ttl_ms` (default 2h) and `:sweep_interval_ms` (default 5m); existing callers are unaffected (defaults apply).
  - The owning GenServer deletes ETS rows older than the TTL on each tick and emits `[:dxcore, :task_log_buffer, :sweep]` / `:sweep_error` telemetry for observability.
  - Fixes the dxcore.dev production OOM/503 cycle where orphaned-run log buffers grew unbounded until both replicas OOMKilled (#4382, SP1).

## 0.7.4

### Patch Changes

- 8c1239d: Fix CI runs hanging when a task depends on a filtered no-op (`<NONEXISTENT>`) task.

  The Turbo adapter drops `<NONEXISTENT>` (scriptless) tasks before dispatch, but
  left dangling references to them in surviving tasks' dependency lists. The
  coordinator's `compute_frontier` then treated a dependency on a task absent from
  the graph as permanently unsatisfiable, so the dependent task never became
  assignable — agents connected, requested work, and got nothing, hanging the run
  with no error (confirmed live: `@repo/github-workflows#lint` blocked forever on
  the dropped `@repo/github-workflows#deps`). See #4154.

  Defense in depth:
  - `@repo/dxcore-agents-cli`: when dropping `<NONEXISTENT>` tasks, prune their
    ids from surviving tasks' `dependencies` (a dropped no-op is logically done).
  - `@repo/dxcore-core`: treat a dependency on a task absent from the graph as
    already-satisfied instead of blocking the dependent forever.

## 0.7.3

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

## 0.7.2

### Patch Changes

- ac6793b: Add `repo-cli deps sync` and `repo-cli deps lint` for keeping `package.json`
  workspace deps in sync with Elixir `mix.exs` path deps. Bootstrap migration
  mirrors path deps across every Mix consumer — Turbo's hash graph now sees
  library changes that previously slipped past release-bump (#2101).

  The patch bump on every Mix consumer reflects the package.json content
  churn from the bootstrap migration; it has no functional behavior change.

## 0.7.1

### Patch Changes

- 4446689: Add `@derive Jason.Encoder` to `DxCore.Core.AgentInfo`. After #2110 the SaaS coordinator's `agent_channel` puts `%AgentInfo{}` into Phoenix.Presence metadata; the WebSocket serializer JSON-encodes every `presence_diff` it forwards to subscribers, and without `@derive` the encoder protocol raised, crashing `Phoenix.Tracker`'s shard GenServer on every agent join. Adds a regression test in `dxcore-core/test/dx_core/core/agent_info_test.exs`.
- 35dda4a: Fix cross-pod scheduler/agent invisibility on the multi-pod SaaS coordinator (#2110). The topology evaluator in `dxcore-core` now reads connected agents through a pluggable `agent_lister` function in scheduler context instead of a hard-coded local Registry. The SaaS coordinator injects a `Phoenix.Presence`-backed lister (`DxCore.SaaS.Scheduler.AgentDiscovery`) so a scheduler placed on Pod B sees agents whose WebSockets landed on Pod A. The previously vestigial `DxCore.SaaS.AgentRegistry` is removed. Validates with a `:peer`-based cluster regression test that exercises the full Scheduler + TopologyEvaluator + AgentDiscovery + cross-node Presence pipeline.
- a45dab6: Fix cross-pod race where agents miss the initial `tasks_available` broadcast on the multi-pod SaaS coordinator (#2143). The dispatcher's `submit_graph` now carries the freshly-spawned scheduler's pid + run_id in the `tasks_available` PubSub payload; agent channels read those directly and call `Scheduler.request_task/3` without going through `Horde.Registry`, which on a remote pod can lag the broadcast by up to one CRDT sync interval (~100 ms). The agent-side `try_assign_task/2` helper falls back to the legacy `Horde.Registry` lookup whenever the payload lacks a pid (covering reconnect/rehydration and any in-flight pre-upgrade broadcasts). Adds a `safe_request_task` wrapper so a stale-pid `:exit` doesn't crash the channel. OSS coordinator gets the same broadcast shape for symmetry even though it's single-node and not subject to the race.

## 0.7.0

### Minor Changes

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
