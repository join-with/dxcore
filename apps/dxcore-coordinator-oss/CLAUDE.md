# DxCore Coordinator OSS

## Purpose

Open-source CI/CD task coordinator. Manages agent sessions, task scheduling, and real-time communication via WebSocket channels.

## Architecture

Key contexts in `lib/dx_core/agents/`:

- **Sessions** — Agent session lifecycle management with GenServer-based session servers
- **Scheduler** — Task scheduling and assignment
- **TaskGraph** — Dependency graph for CI/CD tasks
- **Tenants** — Multi-tenant isolation for agent workloads

Web layer in `lib/dx_core/agents/web/`:
- **AgentChannel / AgentSocket** — WebSocket channel for agent communication
- **DispatcherChannel / DispatcherSocket** — WebSocket channel for dispatcher communication
- **Presence** — Real-time agent presence tracking
- **SessionController** — REST API for session management
- **HealthController** — Health check endpoint
- **ShutdownController** — Graceful shutdown endpoint

## Key Entities

- `Tenant` — isolated workspace for agents (in-memory, ETS-backed)
- `Session` — agent session with state tracking (GenServer)
- `TaskGraph` — DAG of tasks with dependencies

## App-Specific Commands

Standard Phoenix commands. No custom aliases.

## Security Notes

No app-specific security concerns beyond standard Phoenix auth.
