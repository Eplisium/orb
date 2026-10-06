# Changelog

All notable changes to ORB are listed here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/). The marketing version lives in [`VERSION`](VERSION). The bundle build number is the git commit count.

## [Unreleased] — 1.1.0

### Repository and packaging
- GitHub Actions CI on macOS: build, unique-warning count in the job summary, test, ad-hoc packaged `ORB.app` artifact, and uploaded logs.
- `build_app.sh` hardening: strict mode, `swift build --show-bin-path` instead of searching `.build`, and `--release`, `--build`, `--adhoc` (automatic under `CI`), and `--output` options.
- Version now comes from `VERSION` (`CFBundleShortVersionString`), and `CFBundleVersion` is the commit count.
- The app icon is now committed as `Resources/AppIcon.icns`. The generator moved to `scripts/make_icon.swift`.
- `orb://` URL scheme registered in the bundle's Info.plist.
- Swift strict concurrency checking enabled as warnings.
- Opt-in integration and snapshot tests now report as **skipped** rather than silently passing.
- Expanded `.gitignore` coverage for signing material, env files, local databases, and agent workspaces.
- New README, architecture notes, contributing and security guides, and issue/PR templates.

### Agent
- OP Mode setting (off by default) skips the approval prompt for risky tools without granting extra capabilities.
- Real approval prompt for terminal, computer-control, and MCP tools, approve-for-run, and stopping a run denies pending approvals.

### Interface
- Unified app shell: regrouped sidebar (Browse / Create / Evaluate), command palette, tabbed Settings scene, first-run onboarding, and empty states for a missing key.
- Model browser: filters, side-by-side compare, redesigned rows and detail view, offline and empty states.
- Chat and Agent chrome: session search, date groups, pinning, context gauge, slash commands, presets, run strip, jump-to-unread, message actions, rename, duplicate/branch, undoable delete, inspector, and drop target.
- Shared Library: grid and list views, search, type filters, bulk export, Quick Look, and delete with undo.
- Studio presets for Images, Speech, and Embeddings, spend-ceiling progress, and honest job states in the Video studio.
- Accessibility and polish: 11 pt minimum text size, labelled icon buttons, Reduce Motion and Increase Contrast support, working text-size setting, app toasts, job notification sound, and an About window.
- Sortable Test Suite results with a verdict legend.
- Design tokens, accent color choice, and shared components.

### Fixes
- Inspector attached to the pane root, sidebar header truncation, uniform Library grid, and no stray focus ring.

## [1.0.0] — 2026-10-01

First public release under the MIT license.

### Model browser
- Public OpenRouter catalog with search, modality and capability filters, sorting, per-provider endpoint details, favorites, and notes.
- Model picker recents and sorting. Separate Chat and Agent default models.

### Chat
- Streaming chat completions with full generation settings, multimodal attachments, Markdown rendering (incremental block parsing, tables, nested and task lists), cost and token tracking.
- Inline reasoning disclosures, grouped tool rows, and a persisted transcript order.
- Multi-select bulk session deletion, conversation export, and recovery of interrupted streams after relaunch.

### Agent
- Native function-calling agent: files, shell (process-group cancellation), AppleScript, screen capture, input events, memory, and planning.
- Deny-by-default tool policy, workspace path guard, and turn-budget final summary.
- Recovery from phantom or malformed tool calls, reasoning-only turns, TLS and 5xx retries, and 400 responses caused by reasoning payloads.

### MCP
- Stdio MCP servers with namespaced tools, resources, and prompts bridged as synthetic tools. Configuration import, probing, and migration of secret environment variables to the Keychain.

### Generate
- Unified studio for Images (multi-image, editing, reference images, full-screen viewer, prompt enhance), Video (durable resumable jobs), Speech and transcription, Files, and Embeddings and rerank.
- Saved creations, a content-addressed asset store, and a permanent usage and cost ledger with a Settings Usage tab.
- Studio work keeps running across navigation.

### Account and security
- Separate inference and management key roles in the Keychain. Credits and activity use the management key only.
- Touch ID / password lock screen with auto-lock. Keychain storage restricted to ORB, with a one-time migration of legacy items.
- PKCE sign-in coordinator.
- Responses, Messages, and Batch API adapters plus read-only management inventory (contract-tested).

### Test Suite
- Built-in project scenarios and text probes. Deterministic verdicts separate project builds from unverified text answers. Dollar spend ceiling for comparison batches. Optional user input added to scenarios.

### Platform
- SQLite persistence with graceful recovery, configurable network timeouts, and a stable self-signed code-signing identity for local builds.

## Pre-1.0 (2026-08)

- Initial SwiftUI model browser ("OpenRouterBrowser"), renamed to ORB.
- API key management, credits and activity, chat playground.
- First native function-calling agent, MCP support, conversation store, streaming and Markdown rendering, and the `StreamPublishCoalescer`.
