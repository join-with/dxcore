# DxCore Agents CLI

## Purpose

CLI agent that connects to a DxCore coordinator to execute CI/CD tasks. Supports Turbo and Nx monorepo build systems.

## Architecture

Key modules in `lib/dx_core/agents/`:

- **CLI** — Main CLI entry point and application
- **CLI.Agent** — Agent process that executes tasks
- **CLI.CI** — CI environment detection and configuration
- **CLI.Dispatcher** — Task dispatch and coordination logic
- **BuildSystem** — Abstraction for monorepo build systems
- **BuildSystem.Turbo** — Turborepo-specific task graph parsing
- **BuildSystem.Nx** — Nx-specific task graph parsing
- **WsClient** — WebSocket client for coordinator communication

## Key Patterns

- Build system auto-detection (Turbo vs Nx) based on project files
- WebSocket-based communication with coordinator
- Task execution with streaming output

## App-Specific Commands

This is an Elixir CLI app, not a Phoenix web app. No `mix phx.server`.

## Security Notes

No app-specific security concerns.
