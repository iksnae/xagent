# Contributing to xagent

Thank you for your interest in contributing! This document covers how to set up your environment, build and test the project, navigate the module layout, and submit pull requests.

For a high-level overview of the project, its architecture, and the basic development workflow (`swift build`, `swift test`, `swift run xagentcli`), see the **Development** section of [README.md](README.md). The README also covers the project's vision, core principles, model strategy, and MVP goals.

## Required toolchain

xagent requires **Swift 6.x**. The package manifest declares `// swift-tools-version: 6.0`, so any Swift 6 release (6.0, 6.1, etc.) will work. You can download the latest toolchain from [swift.org](https://www.swift.org/download/) or install it via Xcode.

Verify your toolchain:

```bash
swift --version
```

The first line should report a Swift 6.x version number.

## Build

Build the entire project from the repo root:

```bash
swift build
```

This compiles all targets — the `XAgentCore` and `XAgentHTTP` libraries, plus the `xagentd` daemon, `xagentcli` CLI, and `XAgentApp` executable.

To build a single target (e.g. just the CLI):

```bash
swift build --target XAgentCLI
```

To run the CLI after building:

```bash
swift run xagentcli
```

## Test

Run the full test suite from the repo root:

```bash
swift test
```

This exercises two test bundles:

- **XAgentCoreTests** — tests for the core agent library (`XAgentCore`).
- **XAgentDaemonTests** — tests for the daemon executable (`XAgentDaemon`).

You can also run a single test target:

```bash
swift test --filter XAgentCoreTests
```

The `XAgentHTTP`, `XAgentCLI`, and `XAgentApp` targets do not have dedicated test bundles yet — contributions adding test coverage for them are welcome.

## CI

Every push and pull request to `main` is built and tested automatically via [`.github/workflows/ci.yml`](.github/workflows/ci.yml). The workflow runs `swift build` and `swift test` on the latest macOS runner. If either step fails, the check turns red — so run both locally before opening a PR.

## Module layout

The repository is organized into five top-level targets, each living under `Sources/`:

| Target | Type | Description |
|--------|------|-------------|
| **XAgentCore** | Library | Core agent runtime — agents, tools, memory, models, and policy. Depends on `CSQLite3`. |
| **XAgentDaemon** | Executable (`xagentd`) | User-space daemon that hosts the agent runtime and exposes it over XPC and HTTP. Depends on `XAgentCore` and `XAgentHTTP`. |
| **XAgentHTTP** | Library | HTTP API layer — localhost REST and SSE/WebSocket endpoints for non-Apple clients. |
| **XAgentCLI** | Executable (`xagentcli`) | Command-line interface for interacting with the daemon. Depends on `XAgentCore`. |
| **XAgentApp** | Executable (`XAgentApp`) | Native macOS / iOS app entry point. |

Tests live in `Tests/` and mirror the target structure (`XAgentCoreTests`, `XAgentDaemonTests`). The full package layout is defined in `Package.swift` at the repo root.

## Pull request expectations

- **Tests must accompany behavior changes.** If you add, modify, or fix a feature in `XAgentCore` or `XAgentDaemon`, include or update tests in the corresponding test target. PRs that change logic without test coverage will be asked to add it.
- **Keep PRs focused.** Each pull request should address a single concern — a bug fix, a feature, or a refactor. Avoid bundling unrelated changes; it makes review harder and slows everyone down.
- **Follow Swift conventions.** Use Swift actors for isolation where appropriate, prefer structured concurrency, and write clear, descriptive commit messages.
- **Check the build and tests before opening.** Run `swift build` and `swift test` locally and confirm both pass on your branch.
- **Document public API.** If you add or change a public symbol in `XAgentCore` or `XAgentHTTP`, include a doc comment describing its purpose.

When in doubt, open a draft PR or file an issue to discuss your approach before investing significant time. We value collaboration and are happy to provide early feedback.
