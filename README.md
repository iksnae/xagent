# xagent

xagent is a native Apple-platform agent runtime designed to run locally on-device as a service while supporting hybrid and hosted model backends. The goal is to provide one reusable agent harness for apps, CLIs, widgets, App Intents, Shortcuts, and other local interfaces.

This repository is intentionally general-purpose and is not tied to any specific product, company, or prior agent system.

## Vision

Build a Swift-native multi-agent harness that can operate in three deployment modes:

- **Local-only**: all inference and tool execution stays on-device.
- **Hybrid**: privacy-sensitive work stays local while selected tasks route to hosted models.
- **Hosted-first**: agents use OpenAI API-compatible services while preserving the same runtime contract.

## Recommended architecture

```text
Clients
  - macOS app
  - CLI
  - menu bar app
  - widgets
  - App Intents / Shortcuts
  - local web UI
        ↓
Local IPC/API Layer
  - XPC for native Apple clients
  - localhost HTTP for CLIs and non-Apple clients
  - SSE/WebSocket for streaming events
        ↓
xagentd
  - Agent runtime
  - Coordinator / planner / worker / critic agents
  - Tool registry
  - Memory store
  - Policy and permissions layer
  - Run/event store
        ↓
Model router
  - Apple Foundation Models
  - MLX local models
  - OpenAI API-compatible hosted services
  - LM Studio / Ollama / local OpenAI-compatible endpoints
```

## Core principles

1. **Provider-neutral runtime**  
   Agents should call a shared `LLMProvider` protocol, not a specific model SDK.

2. **Local-first by default**  
   Prefer on-device inference and local tools when capable enough.

3. **Hosted-compatible when useful**  
   Support OpenAI API-compatible services through a normalized provider adapter.

4. **Swift actors for isolation**  
   Agents, tools, runs, memory, and model sessions should be implemented as actors where appropriate.

5. **Thin clients**  
   Apps, widgets, App Intents, and CLIs should call the daemon rather than embedding the runtime.

6. **Explicit permissions**  
   File, shell, network, automation, and personal-data tools must be permissioned and audited.

7. **Structured outputs over text parsing**  
   Use guided generation / schemas whenever available.

## Initial components

```text
Sources/
  XAgentCore/
    Agent/
    Runtime/
    Tools/
    Memory/
    Models/
    Policy/
  XAgentDaemon/
  XAgentCLI/
  XAgentXPC/
  XAgentHTTP/

Apps/
  XAgentApp/
  XAgentMenuBar/
  XAgentWidgets/
  XAgentIntents/

docs/
  ARCHITECTURE.md
  PRD.md
  RFP.md
```

## Model strategy

### Local Apple system model

Use Apple Foundation Models for Apple-native, on-device language tasks where available:

- summarization
- extraction
- classification
- small planning tasks
- tool calling
- structured generation

Apple documentation: <https://developer.apple.com/documentation/FoundationModels>

### Local open-weight models

Use MLX / MLX Swift for local open-weight models and Apple Silicon-optimized inference:

- Qwen / Llama / Mistral-style models
- embeddings
- multimodal models
- custom local routing
- experimentation with LoRA / adapters

Apple MLX project: <https://opensource.apple.com/projects/mlx>

MLX Swift examples: <https://github.com/ml-explore/mlx-swift-examples>

### Hosted and OpenAI-compatible services

Support OpenAI API-compatible services through a provider adapter:

- OpenAI
- Azure OpenAI-compatible endpoints
- OpenRouter
- Together
- Fireworks
- LM Studio local server
- Ollama OpenAI-compatible server
- custom internal endpoints

## Example provider config

```yaml
providers:
  apple_local:
    type: foundation_models

  mlx_qwen:
    type: mlx
    model: Qwen3-4B-4bit

  openai:
    type: openai_compatible
    base_url: https://api.openai.com/v1
    api_key_env: OPENAI_API_KEY
    default_model: gpt-4.1-mini

  lmstudio:
    type: openai_compatible
    base_url: http://127.0.0.1:1234/v1
    default_model: local-model

routing:
  default: apple_local
  private_data: mlx_qwen
  complex_reasoning: openai
  offline: mlx_qwen
  fallback: openai
```

## MVP goals

1. Create Swift package structure.
2. Implement `LLMProvider` with a mock provider.
3. Implement `Agent`, `AgentRuntime`, and `ToolRegistry`.
4. Add `xagentd` as a user-space LaunchAgent-capable daemon.
5. Expose HTTP/SSE API for CLI and generic clients.
6. Add native XPC API for Apple clients.
7. Add OpenAI-compatible provider.
8. Add Foundation Models provider.
9. Add MLX provider.
10. Add basic SwiftUI control app and CLI.

## Non-goals for v0

- Full autonomous OS control.
- Privileged system daemon behavior.
- Cloud-hosted orchestration service.
- Complex multi-user permissions.
- Production-grade plugin marketplace.
- Direct Metal kernel work unless MLX cannot meet a specific need.

## Docs

- [Architecture Recommendations](docs/ARCHITECTURE.md)
- [Product Requirements Document](docs/PRD.md)
- [Request for Proposal](docs/RFP.md)

## Development

Build the project:

```bash
swift build
```

Run the test suite:

```bash
swift test
```
