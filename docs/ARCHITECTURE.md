# ORB architecture

A short map of how ORB is put together. It describes responsibilities, not every type. File names refer to `Sources/ORB/` unless noted.

## Package layout

| Target | Path | Kind |
|---|---|---|
| `ORB` | `Sources/ORB` | SwiftPM executable (SwiftUI app, macOS 14+) |
| `ORBTests` | `Tests/ORBTests` | Swift Testing suite plus JSON/SSE/MCP fixtures |

There are no third-party dependencies. The app uses only Apple frameworks: SwiftUI, AppKit, Foundation, Security, LocalAuthentication, SQLite3, and QuickLook. `build_app.sh` wraps the built binary in an `.app` bundle. The icon is pre-rendered by `scripts/make_icon.swift` into `Resources/AppIcon.icns`.

## Layers

```text
┌──────────────── App shell ────────────────┐
│ ORBApp, ContentView, App/ (router, shell,  │
│ command palette, onboarding, lock, settings│
│ scene), DesignSystem/                      │
├──────────────── Feature views ────────────┤
│ Browser · Chat · Agent · Generate studio ·│
│ Library · Test Suite · Settings           │
├──────────────── Services (@MainActor) ────┤
│ APIService · ChatService · AccountService │
│ MediaServices · StudioStore · TestRunner  │
├──────────────── Core ─────────────────────┤
│ OpenRouterClient/Stream · NativeAgent*    │
│ MCPConnection/Registry (actors)           │
│ Core/{API,Auth,Security,Jobs,Assets,      │
│       Management} · Experiments/          │
├──────────────── Persistence ──────────────┤
│ DatabaseManager (SQLite, WAL) ·           │
│ ConversationStore · AssetStore ·          │
│ SavedCreations · UsageLedger · Keychain   │
└───────────────────────────────────────────┘
```

### App shell

- `ORBApp.swift` is the `@main` entry point. It creates the window and command menus.
- `App/` holds the shell model, `AppRouter` (route identity and transitions), `CommandPalette`, `OnboardingView` (key entry or PKCE sign-in), `AppLock`/`LockScreenView` (Touch ID or password via `LAContext`), and `SettingsScene`.
- `DesignSystem/` holds color, typography, metric, and motion tokens plus shared components (`ORBCard`, `ORBChip`, `ORBToast`, …).

### OpenRouter networking

- `APIService` reads the public catalog (`/models`, `/models/{id}/endpoints`) and keeps a disk cache. If the network fails, it uses the cache no matter how old it is. Endpoint identities reserve all literal base IDs before allocating duplicate suffixes.
- `OpenRouterClient` sends authenticated requests with retries (backoff, jitter, `Retry-After`), idle and finish-grace timeouts, and key redaction in errors.
- `OpenRouterStream` is an incremental SSE decoder. It emits reasoning, content, tool-call, usage, and finish events. When one frame holds both reasoning and content, reasoning is emitted first.
- The streaming transport is a `URLSessionDataDelegate` that yields each network chunk into an `AsyncThrowingStream`. It deliberately avoids `URLSession.AsyncBytes`.
- `Core/API/` holds the Responses, Messages, and Batch adapters and the `ReasoningDetail` model. `ReasoningDetail` round-trips unknown provider fields without loss.
- `Core/Management/` is a read-only (GET-only) management inventory client.

### Chat and Agent

- `ChatService` coordinates Chat and Agent sessions, run state, publish coalescing (`StreamPublishCoalescer`), reasoning timing, and persistence.
- `NativeAgentRunner` runs the function-calling loop: it streams a turn, normalizes and validates tool calls (`ToolArgumentNormalizer`), checks the policy, asks for approval, executes, and feeds results back. When the turn budget runs out, it makes one final tool-free summary turn rather than discarding the run.
- `NativeAgentTools` implements the native tools: files, cancellable process-group shell commands, AppleScript, screen capture, input events, memory, and planning.
- `Core/Security/ToolPolicy` is the single deny-by-default capability policy. It controls both which tools are offered and which calls execute. `WorkspacePathGuard` confines ORB's own file tools, not shell commands. A missing `ApprovalCoordinator` denies gated calls unless the Agent caller explicitly selects OP Mode auto-approval. Test Suite uses a fresh approval coordinator for each model run and denies calls when its UI is unavailable.
- `MCPConnection` (actor) is a JSON-RPC client for a stdio subprocess. An ordered nonblocking writer keeps cancellation/deadlines independent of a stalled reader; interrupted partial frames close the transport rather than corrupting later messages. `MCPRegistry` reconciles complete launch configurations and rejects obsolete startup/RPC results. Bounded collision-resistant server/tool keys fit provider naming limits; actual RPC names are recovered from advertised descriptors. Legacy Keychain secret references are unchanged. Cancellation during optional resource/prompt discovery propagates to startup cleanup rather than publishing a partial connection; ordinary discovery errors remain optional. Startup also checks that its original process is still running/current after each await, rejecting transport loss before publishing descriptors. Registry lifecycle waiters unregister on cancellation without cancelling the owner; cancelled initial startup remains retryable and does not publish a server error.
- `MessageTranscript` stores the presentation-only order of reasoning, text, and tool segments. It is kept separate from the wire `content` and `reasoning_details`.

### Generate studio and media

- `MediaServices` has clients for images, video, audio, files, and embeddings/rerank. Image/Video services and Speech/transcription/embedding/rerank `ModalityModelChoices` own shared discovery tasks; departing view cancellation does not strand replacement callers. `MediaEndpointURL` validates every polling URL against `https://openrouter.ai/api/…` before attaching credentials.
- `Core/Jobs/JobController` keeps a durable record of each video job before polling starts, so jobs can resume after relaunch without being submitted (and paid for) again. Controller queries use checked single-statement reads of core and media fields; failed preparation/iteration or invalid persisted identities block mutations and surface `lastPersistenceError`, rather than treating partial data as empty fields or a missing job. Core and media fields commit together in one checked upsert, including checked parameter bindings; this is not a durable retry queue for failed submissions.
- `Core/Assets/AssetStore` provides content-addressed (SHA-256) atomic writes. `SavedCreations` indexes outputs for the Library. Streamed input files are consumed only after both metadata and Library index commits; failures retain the service-owned download for retry/export. Video polling validates the expected job ID before updating state and merges absent cost from the previous/durable job. New saved videos commit an optional remote job identity with the Library entry; download retries recover that entry and retry a failed separate SQLite link, including after reopening. Older manifests remain readable, but their missing identity cannot be reconstructed automatically.
- Library pending removals are store-owned so separate windows cannot purge each other's Undo bytes. Attachment/inventory SQLite-read failures (including partial iteration or undecodable rows) stop deletion. Single-item Library/Video/Speech and generated Image/Speech exports share managed-destination validation (including filesystem aliases and SQLite sidecars), stage beside the destination, and atomically rename only after a successful copy/write. Bulk export retains its separate no-overwrite behavior.

### Credentials

- `Core/Auth/CredentialStore` separates the inference and management roles into different Keychain accounts.
- `KeychainOpenAccess` holds the current Keychain service. Legacy migration runs only after a confirmed missing current item; denied, unavailable, or malformed reads cannot replace current credentials or tombstones. Migration mirrors with add-only semantics. Opaque per-reference revisions invalidate account data and late responses across service instances without exposing credentials.
- `PKCECoordinator` handles browser sign-in with S256 PKCE over a loopback callback. It fails closed on replay or on an origin, path, or state mismatch.

### Persistence

`DatabaseManager` owns `~/Library/Application Support/ORB/favorites.sqlite3` (WAL mode). Migrations are idempotent (`CREATE TABLE IF NOT EXISTS` plus `addColumnIfMissing`) and versioned through `PRAGMA user_version`. If a database file fails to open, it is moved aside and the app continues with a temporary database. Under tests the manager isolates itself to a temporary database on its own.

Conversation loads use checked SQLite reads: preparation and mid-iteration failures cannot masquerade as empty transcripts. Edit truncation publishes memory only after a transactional replacement save. SQLite text is bound/read with explicit UTF-8 lengths, including embedded NULs.

`AgentUsageAccumulator` adds model-turn usage and keeps missing cost sticky across turns. Paid web-search helpers create separate `Agent Web Search` ledger events, avoiding double counting in the model-run event. `UsageLedger` retains rejected writes in a visible in-memory retry queue with stable event IDs; this is not a durable outbox.

### Experiments

`TestScenarios`, `TestRunner`, and `Experiments/ExperimentEvaluation` keep two things apart. *Completion status* says whether the run finished. The *verdict* says whether deterministic artifact checks passed. A text answer alone is never marked as passed, and spend ceilings check reported model-plus-helper dollars between model runs. They are not hard provider budgets. Model usage and task-local helper accounting remain separate ledger charges; any unknown component stops a budgeted batch while known subtotals are preserved.

## Testing approach

- Swift Testing (`@Test`, `#expect`) only. Network, Keychain, and persistence are injected, so the suite runs fully offline.
- MCP live tests start a local Node mock server (`Tests/ORBTests/Fixtures/mock-mcp-server.mjs`). The streaming latency tests start a local socket server.
- Snapshot rendering and live OpenRouter calls only run when their environment variables are set (see the README's Development section). Otherwise they are reported as skipped.
