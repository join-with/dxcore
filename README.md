# DxCore Agents

Open-source distributed task execution for monorepo build systems. Build-system-agnostic -- works with Turborepo, Nx, and other monorepo tools. A Phoenix coordinator manages the task graph and dynamically assigns work to agents over WebSocket. Agents execute build commands, sharing results through remote cache.

## Monorepo Structure

```
package.json              # Root -- turbo + pnpm workspaces
turbo.json                # build/test/lint task definitions
pnpm-workspace.yaml       # apps/* + packages/*
apps/
  dxcore-coordinator-oss/  # Coordinator (Phoenix server)
  dxcore-agents-cli/       # CLI (dispatcher, agent, ci commands)
packages/
  dxcore-core/             # Shared library (scheduler, task graph, plugin behaviour)
examples/
  turbo-monorepo/          # Standalone Turborepo example for E2E testing
  nx-monorepo/             # Standalone Nx example for E2E testing
```

Each Elixir app has a thin `package.json` that wraps `mix` commands, allowing Turborepo to orchestrate build/test/lint across all apps. The apps have no Node.js dependencies -- `package.json` is purely a Turbo integration shim.

## Quick Start

```bash
pnpm install              # Install turbo at root
pnpm deps                 # Fetch Elixir dependencies for all apps
```

### Coordinator

```bash
cd apps/dxcore-coordinator-oss
mix phx.server
```

### Agent

```bash
cd apps/dxcore-agents-cli
mix escript.build
./dxcore_agents_cli agent --coordinator=http://localhost:4000 --agent-id=agent-1 --work-dir=../../examples/turbo-monorepo
```

### Dispatcher

The dispatcher reads a task graph from stdin. Pipe your build system's dry-run output:

```bash
cd apps/dxcore-agents-cli
mix escript.build
turbo run build test lint --dry=json --cwd=../../examples/turbo-monorepo \
  | ./dxcore_agents_cli dispatch --coordinator=http://localhost:4000
```

### Nx Example

To test with the Nx adapter instead of Turbo:

```bash
# Agent with Nx
./dxcore_agents_cli agent --coordinator=http://localhost:4000 --agent-id=agent-1 --build-system=nx --work-dir=../../examples/nx-monorepo

# Dispatcher with Nx
nx run-many -t build test lint --graph=stdout --cwd=../../examples/nx-monorepo \
  | ./dxcore_agents_cli dispatch --coordinator=http://localhost:4000 --build-system=nx
```

## Architecture

```
Dispatcher --> Coordinator (Phoenix) <-- Agent 1
               (Scheduler GenServer)  <-- Agent 2
               (Phoenix Channels)     <-- Agent N
                      |
               Remote Cache (Turbo/Nx)
```

1. Dispatcher reads task graph from stdin (piped from build tool dry-run), submits to coordinator
2. Coordinator computes frontier (tasks with all deps met)
3. Agents connect via WebSocket, receive task assignments
4. Agents run build commands per task
5. Results flow back, coordinator unblocks dependents
6. Repeat until all tasks complete

## Usage as GitHub Actions

DxCore provides 4 composite actions for distributed builds in GitHub Actions:

| Action | Purpose | Key Inputs |
|--------|---------|------------|
| `join-with/dxcore-coordinator-action` | Start the DxCore coordinator server | `token` |
| `join-with/dxcore-agent-action` | Connect a build agent to the coordinator | `coordinator-url`, `token`, `build-system` |
| `join-with/dxcore-dispatch-action` | Pipe a task graph to the coordinator | `coordinator-url`, `token`, `command`, `build-system` |
| `join-with/dxcore-shutdown-action` | Gracefully shut down the coordinator | `coordinator-url`, `token` |

All actions accept an optional `version` input (defaults to latest release).

### Quick Example (Turborepo)

```yaml
jobs:
  coordinator:
    runs-on: ubuntu-latest
    steps:
      - uses: tailscale/github-action@v4
        with: { oauth-client-id: "${{ secrets.TS_OAUTH_CLIENT_ID }}", oauth-secret: "${{ secrets.TS_OAUTH_SECRET }}", tags: "tag:ci", hostname: "coord-${{ github.run_id }}" }
      - run: sudo tailscale serve --bg --http 80 http://localhost:4000
      - uses: join-with/dxcore-coordinator-action@v1
        with: { token: "${{ secrets.DXCORE_TOKEN }}" }

  agents:
    strategy: { fail-fast: false, matrix: { agent: [1, 2, 3] } }
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - uses: tailscale/github-action@v4
        with: { oauth-client-id: "${{ secrets.TS_OAUTH_CLIENT_ID }}", oauth-secret: "${{ secrets.TS_OAUTH_SECRET }}", tags: "tag:ci", hostname: "agent-${{ matrix.agent }}-${{ github.run_id }}" }
      - uses: join-with/dxcore-agent-action@v1
        with: { coordinator-url: "http://coord-${{ github.run_id }}", token: "${{ secrets.DXCORE_TOKEN }}" }

  dispatcher:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - uses: tailscale/github-action@v4
        with: { oauth-client-id: "${{ secrets.TS_OAUTH_CLIENT_ID }}", oauth-secret: "${{ secrets.TS_OAUTH_SECRET }}", tags: "tag:ci", hostname: "dispatch-${{ github.run_id }}" }
      - uses: join-with/dxcore-dispatch-action@v1
        with: { coordinator-url: "http://coord-${{ github.run_id }}", command: "npx turbo run build test lint --dry=json", token: "${{ secrets.DXCORE_TOKEN }}" }

  cleanup:
    needs: [dispatcher]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: tailscale/github-action@v4
        with: { oauth-client-id: "${{ secrets.TS_OAUTH_CLIENT_ID }}", oauth-secret: "${{ secrets.TS_OAUTH_SECRET }}", tags: "tag:ci", hostname: "cleanup-${{ github.run_id }}" }
      - uses: join-with/dxcore-shutdown-action@v1
        with: { coordinator-url: "http://coord-${{ github.run_id }}", token: "${{ secrets.DXCORE_TOKEN }}" }
```

### Required Secrets

- **`DXCORE_TOKEN`** -- shared authentication token between coordinator and agents
- **`TS_OAUTH_CLIENT_ID`** / **`TS_OAUTH_SECRET`** -- Tailscale OAuth credentials (if using Tailscale for networking)

### Networking

The coordinator, agents, and dispatcher must be able to reach each other over the network. DxCore does not handle networking itself -- the examples use [Tailscale](https://tailscale.com/kb/1276/github-action) to create a private mesh between runners, but any networking solution that allows runners to communicate works.

### Full Examples

- [Turborepo workflow](examples/workflow-turbo.yml) -- user-facing example for distributed `turbo run build test lint`

## Development

```bash
pnpm turbo run build test lint                    # Run all checks via turbo
cd apps/dxcore-coordinator-oss && mix test        # Run coordinator tests directly
cd apps/dxcore-agents-cli && mix test             # Run CLI tests directly
cd packages/dxcore-core && mix test               # Run core library tests directly
```
