# DxCore Agents CLI

## Purpose

CLI agent that connects to a DxCore coordinator to execute CI/CD tasks. Supports Turbo, Nx, Gradle, Generic, and Docker build systems.

## Architecture

Key modules in `lib/dx_core/agents/`:

- **CLI** — Main CLI entry point and application
- **CLI.Agent** — Agent process that executes tasks
- **CLI.CI** — CI environment detection and configuration
- **CLI.Dispatcher** — Task dispatch and coordination logic
- **BuildSystem** — Abstraction for monorepo build systems
- **BuildSystem.Nx** — Nx-specific task graph parsing
- **BuildSystem.Gradle** — Gradle-specific task graph parsing
- **BuildSystem.Generic** — dxcore's own task graph, sent as given (`dispatch`'s default; a turbo dry run is converted to it by `packages/dxcore-turbo-graph`, the one converter)
- **BuildSystem.Docker** — Docker buildx task graph parsing
- **WsClient** — WebSocket client for coordinator communication

## Key Patterns

- The build system is chosen with `--build-system` (`generic`, `nx`, `docker`, `gradle`); every adapter writes dxcore's own task format, which the coordinator only validates
- WebSocket-based communication with coordinator
- Task execution with streaming output

## App-Specific Commands

This is an Elixir CLI app, not a Phoenix web app. No `mix phx.server`.

## Security Notes

No app-specific security concerns.
