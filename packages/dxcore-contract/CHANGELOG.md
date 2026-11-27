# @repo/dxcore-contract

## 0.3.1

### Patch Changes

- a2e8098: The repo-cli pin is now a package, `@repo/toolchain` (`packages/toolchain/repo-cli.toml`, which mise reads through the `.config/mise/conf.d/repo-cli.toml` symlink), instead of a file every task names by path (#17873 part 10). Each package with a script that runs repo-cli lists `@repo/toolchain` in devDependencies, and its repo-cli tasks reach the pin through `^toolchain` (or an existing `^build` chain), so the `$TURBO_ROOT$/.config/mise/conf.d/repo-cli.toml` inputs are gone from every turbo.json and from the brainstretch-gen templates. A pin bump still reruns every task that runs repo-cli. The root `toolchain` task now hashes only a package's manifest and reaches only the toolchains a package lists itself, so the contract packages and the Brainstretch self-check helpers drop their own `toolchain` overrides, and the JDK, Ruby and Zig toolchain packages state their inputs in their own turbo.json.

## 0.3.0

### Minor Changes

- 5296cea: The plan step sends dxcore's own task graph, converted once (#19431). The new `@repo/dxcore-turbo-graph` is dxcore's one turbo-to-dxcore converter: from a turbo dry run it writes tasks with only the agent protocol's `taskFields`, each `<NONEXISTENT>` placeholder contracted out of its dependents' `dependencies` (cycle-safe, each id once), the turbo command, `cacheable`, the cache status alone and the package's dxcore requirements. `taskFields` drops `dependents`: `DxCore.Core.TaskGraph.parse/1` derives them from `dependencies`, and now only validates (closed field set, unique non-empty ids, dependencies present and distinct, no cycle, bounded sizes), returning one message per refusal. The DTE and both dispatcher channels read through it (the coordinator's `DteRunner.TurboGraph` is deleted; a refused graph fails the DTE's read, or answers `invalid_graph` to the dispatcher). The agents CLI's turbo adapter, `resolve_requirements/1` and `wire_task/1` are deleted: `dxcore dispatch` defaults to `--build-system=generic`, dxcore's own graph sent as given, and `turbo` is refused with the converter to pipe through. ci.yml's plan job converts the dry run once; the sizer and the dispatch graph read the converted graph. PR #19394's affected graph goes from 8,008,871 bytes to about 1 MB.
  The dispatch action's `build-system` defaults to `generic`, dxcore's own task graph; a turbo dry run is piped through `@repo/dxcore-turbo-graph` first. `TaskGraph.parse/1` also refuses a task without `task`, `package` or `command`.

## 0.2.0

### Minor Changes

- cbcfd90: Three more dxcore values are written once, in `@repo/dxcore-contract` (#19349): the plan request's caps (`limits.json` `plan_request`: tasks, dependency edges, string bytes), an agent failure message's size (`limits.json` `agent_failure.max_message_bytes`), and which closed run states fail its agent jobs (the new `agent-verdict.json`). The coordinator's `PlanController`, `AgentSetup` and `Boxes.Leftovers` read them at compile time (`@external_resource`), and CI's pool sizer, failure and verdict scripts import the same files, so the root checks that regex-read the coordinator's source for these values are gone.

## 0.1.0

### Minor Changes

- 350d0bd: dxcore's product limits are written once, as data in the new `@repo/dxcore-contract` (#18951): the window limits and the planner's agents per run (`limits.json`), the fit report's finding kinds (`fit-report.json`), the runner price table (`prices.json`), and the agent protocol, moved here from dxcore-core, whose `taskFields` are the fields the dispatcher and the DTE's graph keep (`agent-protocol.json`). The coordinator and the agents CLI read them at compile time through their pnpm link (`@external_resource`), CI's dispatch graph imports them, and the agents CLI no longer needs dxcore-core as a test-only Mix dep. repo-cli's CD agent maxima, our organization's policy rather than dxcore's, live in the new `@repo/repo-cli-contract` (`agents.json`), which repo-cli bundles. Each consumer waits for the contract's one task (`^compile-js`, hashing its JSON), so a changed value reruns exactly the consumers, and the root checks import the files instead of regex-reading dxcore and repo-cli source.
