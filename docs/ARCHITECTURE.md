# xagent Architecture Recommendations

## Overview

xagent should be built as a local runtime platform rather than a chatbot application.

The runtime owns:

- agent execution
- tool execution
- model routing
- memory
- permissions
- event streaming
- observability

Everything else should be a client.

## Runtime Layers

```text
Clients
↓
API Layer
↓
Agent Runtime
↓
Tool Runtime
↓
Model Router
↓
Providers
```

## Agent Types

Recommended starting agents:

- CoordinatorAgent
- PlannerAgent
- WorkerAgent
- CriticAgent
- SummarizerAgent

All agents should implement a shared protocol and execute through actor isolation.

## Model Router

Responsibilities:

- provider selection
- cost awareness
- privacy awareness
- capability matching
- failover
- offline support

## Provider Adapters

### Foundation Models

Apple on-device model integration.

### MLX

Local open-weight models.

### OpenAI-Compatible

Any service exposing OpenAI-compatible APIs.

## IPC

### XPC

Primary native communication layer.

### HTTP/SSE

Primary cross-platform communication layer.

## Memory

Phase 1:

- SQLite
- structured run history
- conversation storage

Phase 2:

- embeddings
- retrieval
- semantic memory

## Security

Every tool receives:

- permission scope
- audit metadata
- execution context

All executions should be logged.

## Packaging

### Daemon

xagentd

LaunchAgent-hosted user service.

### Clients

- SwiftUI app
- CLI
- widgets
- App Intents
- menu bar application

## Future

- distributed runtimes
- remote workers
- collaborative agents
- multi-device synchronization
