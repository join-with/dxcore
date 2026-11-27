# @repo/dxcore-contract

## 0.1.0

### Minor Changes

- 350d0bd: dxcore's product limits are written once, as data in the new `@repo/dxcore-contract` (#18951): the window limits and the planner's agents per run (`limits.json`), the fit report's finding kinds (`fit-report.json`), the runner price table (`prices.json`), and the agent protocol, moved here from dxcore-core, whose `taskFields` are the fields the dispatcher and the DTE's graph keep (`agent-protocol.json`). The coordinator and the agents CLI read them at compile time through their pnpm link (`@external_resource`), CI's dispatch graph imports them, and the agents CLI no longer needs dxcore-core as a test-only Mix dep. repo-cli's CD agent maxima, our organization's policy rather than dxcore's, live in the new `@repo/repo-cli-contract` (`agents.json`), which repo-cli bundles. Each consumer waits for the contract's one task (`^compile-js`, hashing its JSON), so a changed value reruns exactly the consumers, and the root checks import the files instead of regex-reading dxcore and repo-cli source.
