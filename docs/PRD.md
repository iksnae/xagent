# Product Requirements Document

# xagent

## Problem

Modern agent frameworks are typically:

- cloud-first
- Python-centric
- difficult to integrate deeply into Apple platforms
- tightly coupled to specific model vendors

Developers need a native Apple runtime that can operate locally, hybrid, or fully hosted while exposing a stable interface to applications.

## Product Goal

Create a reusable Swift-native agent runtime for Apple platforms.

## Target Users

- Apple platform developers
- AI application developers
- local-first software builders
- automation enthusiasts

## Core Requirements

### Agent Runtime

Must support:

- multiple concurrent agents
- actor isolation
- streaming execution
- structured outputs
- tool calling

### Model Layer

Must support:

- Foundation Models
- MLX
- OpenAI-compatible APIs

### Service Layer

Must support:

- daemon operation
- XPC
- HTTP
- SSE

### Client Layer

Must support:

- SwiftUI
- CLI
- widgets
- App Intents
- Shortcuts

## Functional Requirements

FR-1: Submit tasks.

FR-2: Stream task execution.

FR-3: Execute tools.

FR-4: Route requests to model providers.

FR-5: Persist run history.

FR-6: Enforce permissions.

FR-7: Expose local APIs.

## Non-Functional Requirements

- Swift 6+
- Apple Silicon optimized
- local-first
- offline capable
- extensible provider architecture

## MVP

### Milestone 1

- runtime
- provider abstraction
- mock provider
- CLI

### Milestone 2

- daemon
- HTTP API
- event streaming

### Milestone 3

- OpenAI-compatible provider
- Foundation Models provider

### Milestone 4

- MLX provider
- memory subsystem

### Milestone 5

- SwiftUI control application
