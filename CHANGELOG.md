# Changelog

All notable changes to ORB are listed here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/). The marketing version lives in [`VERSION`](VERSION). The bundle build number is the git commit count.

## [Unreleased] — 1.1.0

### Backend reliability and safety
- Fail-closed missing approvals, explicit Agent OP Mode opt-in, and per-run Test Suite command approvals with safe cancellation/navigation handling.
- Checked conversation reads, transactional edit truncation, and lossless SQLite text/streaming Unicode handling.
- Credential migration preserves unavailable current items and deletion tombstones; account services invalidate stale data and late responses across key changes.
- Missing model-turn prices remain unknown; web-search helper usage is recorded separately. Failed ledger writes expose an in-memory retry queue in Usage Settings.
- Checked integer conversions and file offsets prevent malformed-input crashes; advanced adapters honor terminal events before residual framing validation.

- Collision-resistant bounded MCP names preserve routing/approval separation without exceeding provider limits. Nonblocking ordered stdin writes honor cancellation and deadlines; changed live configurations restart safely and obsolete results are rejected.
- Failed asset/Library saves preserve retry inputs; remote file deletion requires confirmation for the requested file. Shared Image/Video catalog refreshes survive departing callers.
- Video polls validate job identity before state changes and preserve known costs through sparse/resumed responses, including explicit zero.

### Repository and packaging
- GitHub Actions CI on macOS: build, unique-warning count in the job summary, test, ad-hoc packaged `ORB.app` artifact, and uploaded logs.
- `build_app.sh` hardening: strict mode, `swift build --show-bin-path` instead of searching `.build`, and `--release`, `--build`, `--adhoc` (automatic under `CI`), and `--output` options.
- Version now comes from `VERSION` (`CFBundleShortVersionString`), and `CFBundleVersion` is the commit count.
- The app icon is now committed as `Resources/AppIcon.icns`. The generator moved to `scripts/make_icon.swift`.
- `orb://` URL scheme registered in the bundle's Info.plist.
- Swift strict concurrency checking (`targeted`) enabled as warnings.
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

### Fixed (bug audit and UI review, 2026-11-12)
- **Chat and Agent:** Shift-Return inserts a new line (it used to do nothing and leave the draft selected, so the next key replaced it). A restored draft keeps the caret at its end. Editing a message no longer deletes the rest of the conversation until the edit is sent, and it can be cancelled at any time. Sessions open at the latest message. Chat sampling settings persist. Stop is recorded as interrupted, not as a finished answer. A missing API key is no longer reported as a rejected key. First-run Chat defaults to a well-known model.
- **Agent and MCP:** startup race that orphaned server processes, crashed servers still being advertised, enabling a server not connecting it, arguments with spaces being split, tool results capped at 100 KB, tool-call ids reused across turns, and four crash paths.
- **Generate:** a video job that was polling when ORB quit can be resumed, a rejected submission is recorded as failed rather than unconfirmed, a remote failure is no longer shown as a network error, split image requests get distinct seeds, Generate waits for the model's options, and `.mov` and `.gif` creations keep their extension.
- **Model browser:** compare selections are pruned against the catalog, the detail pane refreshes with the catalog, loading state renders during a refresh, free endpoints rank first, uptime is rounded, and notes are flushed on quit.
- **Settings and shell:** JSON Schema fields are saved, `orb://` links arriving while locked run after unlock, Open Compare moved to ⌃⌘C (⌥⌘C is Copy Last Reply), usage totals match the chart, and removing the inference key leaves management-key data alone.
- **Core:** thread-safe database access, streamed events up to 32 MB (images), `Retry-After` honoured only up to the retry ceiling, string error codes in streams, and offline sends fail fast.
- **Interface:** the Chat and Agent welcome fits above the composer, Generate is pinned in Images, the lock screen is readable in light mode, and Appearance controls are aligned.

### Fixed (hands-on UI audit, 2026-10-07)
- Theme: switching Light → System no longer leaves black text and light controls on dark Settings surfaces. Appearance is applied once at the app level (`NSApp.appearance`) instead of per-window `preferredColorScheme`.
- Favorites: the sidebar badge and the list header now count the same resolved favorites. Favorites missing from the current catalog show as "N unavailable" with an explanation; they are kept, not deleted.
- Model browser: switching between All Models, Favorites and New This Week no longer leaves a model from another collection in detail. A selection hidden by a search or filter is labelled "Not in the current list".
- Accounts & Keys: the first section is now "Inference Key" and describes Chat, Agent and Generate. Credits and activity are only described under the management key.
- MCP settings: copy now matches the real policy (offered to the Agent only with Computer Access, each call needs approval) and each server shows its availability. README limitations updated.
- Accessibility: model rows and sidebar destinations expose a name, provider, favorite/compare state and counts; model-detail actions name their model.
- Usage chart: dated x-axis with readable "Oct 7" labels at most weekly, hover readout of each day's spend, and a title that states the real 30-day window under All Time.
- Images: result cards no longer show a duplicate Save button next to Export. Saved results offer "View in Library". In chat, the image button is now "Export…".
- Library: list rows show thumbnails, a short title from the prompt and a content tag (`#a1b2c3`) shared by list and grid, with the full prompt in the tooltip.
- Sidebar copy: the account chip says "Management key needed" with the full hint in its tooltip; Chat/Agent subtitles fit; session rows show their full title on hover.

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
