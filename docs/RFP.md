# Request For Proposal

# xagent

## Executive Summary

xagent seeks to establish a modern Swift-native agent runtime capable of running on Apple devices while supporting local, hybrid, and hosted inference models.

The resulting platform should enable developers to build applications, automations, assistants, and workflows on top of a reusable local service architecture.

## Objectives

1. Create a reusable agent runtime.
2. Support Apple-native AI capabilities.
3. Support MLX local models.
4. Support OpenAI-compatible APIs.
5. Support daemon-based deployment.
6. Support multiple client interfaces.

## Technical Requirements

### Language

- Swift 6+

### Platform

- macOS first
- future iOS and iPadOS support

### AI Integration

- Apple Foundation Models
- MLX
- OpenAI-compatible APIs

### Runtime

- actor-based concurrency
- structured outputs
- streaming responses
- tool execution

### APIs

- XPC
- HTTP
- SSE

## Deliverables

### Phase 1

Architecture and runtime foundation.

### Phase 2

Daemon service and APIs.

### Phase 3

Provider integrations.

### Phase 4

User-facing applications.

## Success Criteria

- local execution works
- hosted execution works
- model routing works
- tools execute safely
- clients share a single runtime

## Evaluation Criteria

- maintainability
- extensibility
- performance
- privacy
- developer experience
- Apple platform integration
