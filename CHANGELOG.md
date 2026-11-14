# Changelog

All notable changes to ORB are listed here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/). The marketing version lives in [`VERSION`](VERSION); the bundle build number is the git commit count. Each released version has one **Added**, **Changed**, and **Fixed** list. Pushing a `vX.Y.Z` tag publishes that version's section as the GitHub Release notes (`.github/workflows/release.yml`).

## [1.2.0] — Unreleased

### Added
- **Releases:** tagged builds (`v*`) publish an optimized, ad-hoc signed `ORB.app` zip with a `SHA256SUMS` file on the GitHub Releases page.
- **Storage:** Settings → Advanced → Storage & Diagnostics shows what ORB's data uses on disk, reveals it in Finder, copies a key-free diagnostics summary, and has **Compact Database** (reclaims space left by deleted conversations and images, with before/after sizes).
- **Chat:** syntax highlighting for closed code blocks in common languages, with a scroll hint for long lines; Choose Model (⌘L), Find in Conversation (⇧⌘F), Continue for replies cut off at the length limit, and Up in an empty composer to edit the last message.
- **Chat and Agent:** message delete is undoable, and "Delete with reply" removes a question together with its answer. Session deletes from the sidebar row are undoable too.
- **Agent:** `run_command` shows live output in its card while it runs, takes an optional timeout (default 120 s, max 30 min) and returns partial output on timeout. Quitting ORB stops every command the agent started.
- **Agent:** `write_file` reports created/modified with a line diff, shown in the approval sheet before writing; tool cards show commands, scripts and file contents readably instead of escaped JSON.
- **Agent:** while a tool waits for approval the run strip and sidebar say so, the Agent sidebar item shows a shield badge, and a notification reaches you in another app.
- **MCP:** live server status, Apply for edited servers, an environment and Keychain-secret editor, a working folder setting, stderr in failure messages, and paging through large tool/resource/prompt lists.
- **Model browser:** the whole catalog (image, video, speech and embedding models too) with relevance-ranked search, Batch API variants (hidden by default), p50 latency/throughput with percentiles, Markdown descriptions, and an API tab with curl/Python/TypeScript snippets.
- **Generate:** saved videos play inside the studio with poster thumbnails; an audio player in Speech; an embeddings similarity heat map; estimated pre-run cost; per-studio prompt history and "Open in Studio"; drag and drop into studios; Dismiss for finished jobs and "Show in Library".
- **Test Suite:** text-mode custom tests with an expected output, editing and confirmed delete; time to first token and tokens/second for text probes (stored with results); side-by-side Markdown answers; a response column in CSV export.
- **App:** Check for Updates… plus a quiet daily release check, Lock ORB (⌃⌘L), a complete grouped shortcut sheet, and a Help menu that opens the project README, issues and release notes.

### Changed
- **Packaging:** `build_app.sh` packages the optimized release configuration by default; `--debug` opts in to the unoptimized build. CI compiles and packages the release configuration.
- **Info.plist:** adds an Apple Events usage description (Agent automation, only with Computer Access on), the Developer Tools app category, a copyright line, and the development region.
- **CI:** runs on `main` are no longer cancelled by a newer push (only superseded pull-request runs are). The build fails if unique compiler warnings rise above `scripts/warnings-baseline.txt`.
- **App shell:** ORB has a single main window; menu commands and `orb://` links reuse it (or reopen it after ⌘W). ⌘F searches the current section: the collection on screen in the browser, sessions in Chat and Agent.
- **Defaults:** Chat, Agent, Test Suite and ⌘N pick their default model from the live catalog (pinned, then favourites, then recents, then a current model from a well-known family) instead of a hard-coded ID, and never a batch, image or embedding model.
- **Files:** opens on the local Library, which no longer shows the "add a key" banner; uploading still needs a key.
- **Images:** Enhance with AI works without an Agent-pinned model (it uses the Chat default or a fast text model) and says which model it will use.
- **Agent:** a tool call cut off by the output limit goes back to the model as an error and the run continues; only repeated overflows stop the run. Approve is a click or ⌘Return, never plain Return. File tools ask before writing outside the workspace or touching credential or code-running locations.
- **Settings:** OP Mode and App Lock live in General → Security; Network timeouts moved into Advanced. The text-size control was withdrawn until every view scales.
- **Model menu:** reads "Remove from Compare" for a compared model and disables Chat with Model for models that cannot chat.

### Fixed
- **Launch speed:** messages, conversations, and interrupted-stream recovery use indexes, so opening ORB with a long chat history no longer scans the whole messages table once per conversation.
- **Database safety:** ORB refuses to open a database written by a newer version (it shows an error and runs with a temporary database instead) and never lowers the stored schema version.
- **Database safety:** a write from one thread can no longer be rolled back by another thread's failed asset or Library transaction.
- **MCP / tool cards:** top-level JSON strings are escaped correctly, and NaN or infinite numbers are written as `null` instead of invalid JSON.
- **Launch speed:** Chat and Agent load every transcript in one query instead of one query per conversation.
- **Chat:** a failed or stopped regeneration restores the original reply; sends and finished replies save only the changed rows; HEIC/BMP/TIFF attachments are re-encoded (long edge 2048 px) off the main thread; text and code files are inlined with an honest size cap; sent messages show image thumbnails and file chips; the context gauge starts from the last reported usage; sessions are ordered by last activity.
- **Agent:** the status reads "Waiting for your approval" instead of "Running tool" while a prompt is open; error hints name only controls that exist in Agent; fetch_url stops at its size cap and skips binary downloads; the system prompt lists only advertised tools.
- **Model browser:** endpoint latency/throughput decode the current API shape; the cached catalog shows at once and refreshes when stale; ⌘F and "reveal model" keep the current collection, filters and search; Agent is disabled for models without tool calling.
- **Generate:** catalogs load without a key; Generate Video frees up once the job is accepted (up to four polling jobs); embedding and rerank runs track progress separately; file reads happen off the main thread; one no-key notice per studio.
- **Test Suite:** comparisons and failed or cancelled runs record partial spend, the spend ceiling is checked after every agent turn (30-turn budget), latency excludes approval waits, exact-output probes can pass, the leaderboard ignores cancelled runs, and custom-test results open.
- **Settings and shell:** the sidebar credit balance refreshes after spending; App Lock prompts once per lock and treats Cancel as cancel; the onboarding sheet never appears over the lock screen; the in-app Reduce Motion setting reaches every animation.

## [1.1.0] — 2026-11-13

Never tagged; this is the version stamped into builds from `main` between 1.0.0 and 1.2.0.

### Added
- **App shell:** regrouped sidebar (Browse / Create / Evaluate), command palette, tabbed Settings scene, first-run onboarding, empty states for a missing key, app toasts, a job notification sound, and an About window.
- **Model browser:** filters, side-by-side compare, redesigned rows and detail view, and offline and empty states.
- **Chat and Agent:** session search, date groups, pinning, a context gauge, slash commands, presets, a run strip, jump-to-unread, message actions, rename, duplicate/branch, undoable delete, an inspector, and a drop target.
- **Agent:** a real approval prompt for terminal, computer-control, and MCP tools, with approve-for-run; stopping a run denies pending approvals. OP Mode (off by default) skips the prompt without granting extra capabilities.
- **Generate:** a shared Library with grid and list views, search, type filters, bulk export, Quick Look, and delete with Undo. Presets for Images, Speech, and Embeddings, spend-ceiling progress, and honest job states in Video.
- **Accessibility:** 11 pt minimum text size, labelled icon buttons, Reduce Motion and Increase Contrast support, a working text-size setting, and accent color choice.
- **Test Suite:** sortable results with a verdict legend.
- **Repository:** GitHub Actions CI (build, warning count, test, ad-hoc `ORB.app` artifact, logs), `VERSION`-driven versioning, a committed app icon (`Resources/AppIcon.icns`, generated by `scripts/make_icon.swift`), the `orb://` URL scheme, strict concurrency checking (`targeted`, as warnings), a README, architecture notes, contributing and security guides, and issue/PR templates.

### Changed
- **Packaging:** `build_app.sh` runs in strict mode, finds the binary with `swift build --show-bin-path`, and gained `--release`, `--build`, `--adhoc` (automatic under `CI`), and `--output`.
- **Storage:** registered Library contents, expiring Undo tokens, and import ownership commit to SQLite first; `creations.json` is a compatibility export written afterwards. New managed Library roots reclaim unowned files once their Undo/import holds expire. Existing (legacy) roots still keep removed files' bytes.
- **Storage:** asset deletion commits metadata removal and a cleanup inventory before unlinking files, and interrupted cleanup resumes on the next open.
- **Corruption recovery:** ORB makes byte-verified copies of the database and its sidecars and never moves or deletes the originals. It stays on a temporary database until the original is repaired.
- **Video:** failed job writes keep complete snapshots in a private local recovery journal. Changed records need an explicit local choice instead of a timestamp overwrite, and records that exist only in memory are labelled as lost on quit.
- **Tests:** opt-in integration and snapshot tests report as skipped instead of silently passing. `.gitignore` covers signing material, env files, local databases, and agent workspaces.

### Fixed
- **Chat and Agent:** Shift-Return inserts a new line, and a restored draft keeps the caret at its end. Editing a message no longer deletes the rest of the conversation until the edit is sent. Sessions open at the latest message. Chat sampling settings persist. Stop is recorded as interrupted. A missing API key is no longer reported as a rejected key. First-run Chat defaults to a well-known model.
- **Agent and MCP:** a startup race that orphaned server processes, crashed servers still being advertised, enabling a server not connecting it, arguments with spaces being split, oversized tool results (now capped at 100 KB), tool-call IDs reused across turns, and four crash paths. Concurrent connects share one startup; cancelled startup or discovery never publishes a half-connected server and can be retried. MCP tool names stay unique and within provider length limits.
- **Approvals:** missing approval infrastructure denies the call. Test Suite project commands always ask, even in OP Mode.
- **Generate:** a video job that was polling when ORB quit can be resumed; a rejected submission is recorded as failed; a remote failure is no longer shown as a network error; split image requests get distinct seeds; Generate waits for the model's options; `.mov` and `.gif` creations keep their extension. Video polls check the job ID and keep known costs, including an explicit $0.
- **Generate:** failed saves keep the paid output for retry; a video re-download after a failed link write no longer duplicates the Library entry; shared bytes stay while another window still offers Undo; failed metadata reads stop cleanup instead of orphaning files. Exports refuse managed assets, manifests, and database files (including aliases) and never destroy an existing destination on failure. Assistant image exports report write failures and use a filename matching the JPEG/PNG encoding.
- **Files:** pagination has one owner, so a stale page can't restore a deleted file or overwrite a newer list; uploads and deletes refresh from page one; duplicate rows or repeating cursors stop loading instead of looping. Deleting a remote file requires confirmation.
- **Model browser:** compare selections are pruned against the catalog, the detail pane refreshes with the catalog, loading state renders during a refresh, free endpoints rank first, uptime is rounded, notes are flushed on quit, endpoint rows stay distinct, and switching collections no longer leaves another collection's model in detail. Favorites badge and list agree; favorites missing from the catalog show as "N unavailable" and are kept.
- **Settings and shell:** switching Light → System no longer leaves mismatched text and controls. JSON Schema fields are saved, `orb://` links arriving while locked run after unlock, Open Compare moved to ⌃⌘C, usage totals match the chart (with a dated axis and hover readout), and removing the inference key leaves management-key data alone. Credential migration never overwrites a current key or a deletion; account data refreshes after a key change.
- **Core:** thread-safe database access, checked conversation reads, transactional edit truncation, lossless Unicode in SQLite and streams, streamed events up to 32 MB (images), `Retry-After` honoured only up to the retry ceiling, string error codes in streams, offline sends that fail fast, and checked numeric conversions that prevent malformed-input crashes. Responses/Messages/Batch adapters frame events independent of network chunk boundaries and only count explicit 2xx batch items as successes. Reasoning details keep unexpected field shapes for tool continuation.
- **Usage:** missing prices stay unknown instead of $0, web-search helper costs are recorded separately, and failed ledger writes can be retried from Settings → Usage.
- **Interface:** the Chat and Agent welcome fits above the composer, Generate is pinned in Images, the lock screen is readable in light mode, Appearance controls are aligned, the inspector attaches to the pane root, the Library grid is uniform, and there is no stray focus ring. Accessibility labels name each model row, sidebar destination, and detail action.

## [1.0.0] — 2026-10-01

First public release under the MIT license.

### Added
- **Model browser:** Public OpenRouter catalog with search, modality and capability filters, sorting, per-provider endpoint details, favorites, and notes.
- **Model browser:** Model picker recents and sorting. Separate Chat and Agent default models.
- **Chat:** Streaming chat completions with full generation settings, multimodal attachments, Markdown rendering (incremental block parsing, tables, nested and task lists), cost and token tracking.
- **Chat:** Inline reasoning disclosures, grouped tool rows, and a persisted transcript order.
- **Chat:** Multi-select bulk session deletion, conversation export, and recovery of interrupted streams after relaunch.
- **Agent:** Native function-calling agent: files, shell (process-group cancellation), AppleScript, screen capture, input events, memory, and planning.
- **Agent:** Deny-by-default tool policy, workspace path guard, and turn-budget final summary.
- **Agent:** Recovery from phantom or malformed tool calls, reasoning-only turns, TLS and 5xx retries, and 400 responses caused by reasoning payloads.
- **MCP:** Stdio MCP servers with namespaced tools, resources, and prompts bridged as synthetic tools. Configuration import, probing, and migration of secret environment variables to the Keychain.
- **Generate:** Unified studio for Images (multi-image, editing, reference images, full-screen viewer, prompt enhance), Video (durable resumable jobs), Speech and transcription, Files, and Embeddings and rerank.
- **Generate:** Saved creations, a content-addressed asset store, and a permanent usage and cost ledger with a Settings Usage tab.
- **Generate:** Studio work keeps running across navigation.
- **Account and security:** Separate inference and management key roles in the Keychain. Credits and activity use the management key only.
- **Account and security:** Touch ID / password lock screen with auto-lock. Keychain storage restricted to ORB, with a one-time migration of legacy items.
- **Account and security:** PKCE sign-in coordinator.
- **Account and security:** Responses, Messages, and Batch API adapters plus read-only management inventory (contract-tested).
- **Test Suite:** Built-in project scenarios and text probes. Deterministic verdicts separate project builds from unverified text answers. Dollar spend ceiling for comparison batches. Optional user input added to scenarios.
- **Platform:** SQLite persistence with graceful recovery, configurable network timeouts, and a stable self-signed code-signing identity for local builds.

## Pre-1.0 (2026-08)

- Initial SwiftUI model browser ("OpenRouterBrowser"), renamed to ORB.
- API key management, credits and activity, chat playground.
- First native function-calling agent, MCP support, conversation store, streaming and Markdown rendering, and the `StreamPublishCoalescer`.

[1.2.0]: https://github.com/Eplisium/orb/releases/tag/v1.2.0
