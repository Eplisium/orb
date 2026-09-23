<p align="center">
  <img src="https://img.shields.io/badge/macOS-Sonoma_14.0+-purple?style=for-the-badge&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange?style=for-the-badge&logo=swift" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/SwiftUI-native-blue?style=for-the-badge&logo=swift" alt="SwiftUI">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT License">
</p>

<h1 align="center">ORB</h1>

<p align="center">
  <strong>OpenRouter Browser</strong> — a native macOS workstation for discovering, comparing, chatting with, and building workflows around models available through <a href="https://openrouter.ai">OpenRouter</a>.
</p>

<p align="center">
  Built with <strong>SwiftUI</strong> and <strong>Swift Package Manager</strong>. No Xcode project is required.
</p>

---

## What is ORB?

ORB started as a model browser and has grown into a complete native OpenRouter client. It combines a searchable model catalog, provider comparison, direct streaming chat, a local function-calling agent, media generation tools, MCP extensions, account analytics, and a model evaluation suite in one macOS application.

ORB is designed for people who want to:

- Find the right model by capability, modality, pricing, context length, or benchmark data.
- Compare the providers serving a model and inspect latency, throughput, uptime, and pricing.
- Chat directly with any compatible OpenRouter model.
- Give an agent controlled access to files, shell commands, web resources, and Mac automation.
- Generate images, video, speech, embeddings, and reranking results through dedicated OpenRouter APIs.
- Run repeatable development and creative tests against different models.

## Features

### Model browser

- Browse the public OpenRouter model catalog without an API key.
- Search by model name, ID, provider, or description.
- Filter by text, image, audio, video, file, tools, reasoning, embeddings, or free availability.
- Sort by name, provider, context length, creation date, pricing, or Design Arena Elo.
- Inspect model architecture, modalities, supported parameters, reasoning support, pricing, benchmarks, knowledge cutoff, and expiration state.
- Inspect per-provider endpoints with context limits, pricing, latency, throughput, uptime, quantization, and availability.
- Favorite models and keep durable model notes in SQLite.
- Use the same live catalog and favorites in the Chat and Agent model pickers.

### Direct Chat playground

- Stream conversations directly through OpenRouter's OpenAI-compatible chat completions endpoint.
- Use separate persistent Chat sessions and model defaults.
- Configure temperature, maximum tokens, reasoning, routing, provider preferences, response formats, service tiers, and other generation parameters.
- Attach multimodal content where supported.
- Display Markdown, reasoning content, streamed images, tool-related metadata, cost, token counts, and tokens per second.
- Read Chat and Agent as one inline transcript: reasoning disclosures, assistant commentary, tool activity, and answers stay in arrival order. New transcript chronology persists across relaunches; older sessions retain their content using a grouped fallback because their original interleaving was not recorded.
- Regenerate the last response, cancel an active run, delete messages, delete sessions, or export a conversation as Markdown.
- Recover interrupted streaming records after relaunch.

### Native Agent playground

- Run ORB's own native function-calling loop directly against OpenRouter.
- Select tool-capable models and maintain a separate Agent session history.
- Choose a workspace folder and attach files to a task.
- Use web fetching and web search.
- Read, list, search, and write local files.
- Run cancellable zsh commands with bounded output.
- Launch applications, open URLs, run AppleScript, capture the screen, inspect images, and perform controlled mouse/keyboard actions.
- Store and recall durable agent memories.
- Maintain explicit task plans for multi-step work.
- Generate images or speech from the agent when requested; these operations use OpenRouter credits.
- Tool access is governed by a deny-by-default capability policy: with Computer Access off, the agent gets web tools only — no local filesystem, shell, computer control, or MCP tools. Unknown tool names are always refused at execution time.
- Toggle Computer Access explicitly. When it is enabled, native tools run with your macOS permissions and can access files, execute shell commands, and automate applications. MCP servers are gated separately: their tools are only exposed for servers you have explicitly approved.
- See live per-tool activity, tool-call cards, results, errors, cancellation state, and final summaries.

### MCP extensions

- Connect enabled Model Context Protocol servers as local subprocesses.
- Import standard `mcpServers` configuration JSON, including command, arguments, and environment variables.
- Probe servers from the settings UI.
- Expose MCP tools to the native Agent with namespaced tool names.
- Surface MCP resources and prompt templates through synthetic model-callable tools.
- Keep one failing server from disabling the rest of the Agent.
- MCP tools are hidden from sessions without the MCP capability, and executed only for explicitly approved servers; a denied approval surfaces to the model as a tool error.

### Media and data tools

The Generate section contains dedicated clients for OpenRouter's specialized APIs:

- **Images** — discover image models, generate one or more images, provide reference images, choose aspect ratio/resolution/quality/format, and retain usage metadata; per-model provider endpoint discovery (pricing and capabilities) is available at the service layer.
- **Video** — submit and poll video jobs, use first/last frame images, configure duration/resolution/aspect ratio/audio, and track terminal job state. Submissions are recorded durably before polling relies on them, so a queued job survives navigation or an app restart and can be resumed without submitting (or paying) twice. Stopping local polling never claims the remote job was cancelled; the record stays resumable.
- **Files** — upload, list, download, and delete OpenRouter files. Uploads are validated client-side (empty and over-limit files are rejected before any request) and deletion requires explicit confirmation at the service layer.
- **Speech** — synthesize speech and transcribe audio.
- **Embeddings** — create embeddings and issue reranking requests.
- **Assets** — generated output bytes are stored durably and content-addressed (SHA-256) under Application Support with metadata in SQLite; identical content is deduplicated, and missing or corrupted assets surface recoverable errors.

### Account dashboard

- Credential roles are explicit: the **inference key** powers Chat, Agent, and media generation; account-wide reads (credits, activity, management inventory) require an optional **management key**. Keys live in separate Keychain items and cannot be swapped accidentally. Add or remove the management key in Settings → API Key (removal clears published account data immediately).
- MCP server environment secrets can be migrated to Keychain references from MCP Settings (per-server consent, variable names only are shown); unresolved references fail closed at launch rather than passing the reference string to a subprocess.
- View total credits, usage, remaining balance, and usage charts (management key required; the panel explains how to add one without blocking Chat).
- Review activity by model, date, spend, and request count.
- See top models by spend and daily spend summaries.

### Test Suite

- Run 22 built-in scenarios across 10 categories:
  - Web Development
  - Game Development
  - App Development
  - API Design
  - Database
  - System Design
  - Machine Learning
  - Data Visualization
  - DevOps & Cloud
  - Security
- Evaluate models on prompts with explicit criteria, difficulty, and estimated runtime.
- Run scenarios through the same native Agent loop used for real work, under a workspace-constrained capability policy (no computer control, no MCP).
- Evaluate outcomes deterministically: an empty or refusing response can never pass, created artifacts are checked against the scenario's expectations, and completion status is reported separately from the evaluation verdict.
- Gate paid batches behind an explicit dollar spend ceiling; runs are refused before invocation once known spend reaches the ceiling, and every refusal is recorded.
- Create custom tests and persist them alongside built-in results.
- Review responses, token usage, cost, latency, success state, errors, and output paths; every run is persisted as a structured record (with JSON export) that survives restarts.

---

## Interface

ORB uses a native SwiftUI layout with a hidden title bar and a minimum window size of 1100×700.

The sidebar is organized into:

- **Browse:** All Models, Favorites, New This Week
- **Tools:** Agent, Chat, Test Suite, Account
- **Generate:** Images, Video, Files, Speech, Embeddings

Browse mode uses a three-column `NavigationSplitView` with the sidebar, model list, and model detail view. Agent and Chat each have their own session sidebar, model picker, composer, settings, activity state, and conversation lifecycle.

---

## Architecture

ORB is a single Swift Package Manager executable target with a separate test target. UI-facing services are generally `@MainActor` isolated, while the MCP registry is an actor for safe concurrent connection and tool routing.

### OpenRouter client

The shared streaming client handles:

- OpenAI-compatible chat completion requests.
- Incremental Server-Sent Event decoding at the byte level.
- Text, reasoning, image, tool-call, usage, metadata, finish, and error events.
- Retry policies with exponential backoff, jitter, and retry-after support.
- Idle timeouts, finish grace periods, cancellation, and abrupt EOF detection.
- Redaction of API keys from surfaced error messages.

Streaming uses a `URLSessionDataDelegate` transport that yields whole network chunks through an `AsyncThrowingStream`. This avoids the per-byte suspension and delayed token rendering that can occur when consuming `URLSession.AsyncBytes` and re-buffering it manually.

### Persistence

SQLite runs in WAL mode at:

```text
~/Library/Application Support/ORB/favorites.sqlite3
```

The database stores:

- Favorites and model notes.
- Chat and Agent conversations.
- Messages, tool calls, multimodal parts, generated images, status, finish reasons, and structured reasoning blocks (opaque signature/encrypted payloads preserved byte-exact for tool continuation).
- Agent histories and durable memories.
- Built-in and custom test results plus durable experiment run records.
- Durable media job records (submission/polling state) and asset metadata; asset bytes live content-addressed under `~/Library/Application Support/ORB/Assets`.

Database open and migration failures degrade to a temporary in-memory database rather than preventing launch. When possible, a failed database is moved aside as a timestamped backup before recovery.

### API key security

The OpenRouter API key is stored in the macOS Keychain under:

```text
Service: com.eplisium.orb
Account: openrouter-api-key        (inference — Chat, Agent, media)
Account: openrouter-management-key (optional management — credits, activity, administration)
```

Keys are never stored in the repository or the app's plain-text preferences, never logged, and never attached to requests for a different role. Media and Agent generation operations use the configured inference key and may spend OpenRouter credits.

### Local Agent permissions

Tool access is deny-by-default. A session grants capabilities (web, workspace read/write, approved terminal, computer control, memory, planning, media generation, MCP) and every tool call is checked against the policy twice: once when the toolbox is advertised and again immediately before execution. Unknown tool names, ungranted capabilities, and unapproved MCP servers all fail closed with a tool error the model can act on.

Computer Access is an explicit application-level gate. When enabled, native tools run with the current user's macOS permissions and can access files, execute shell commands, automate applications, capture the screen, and send mouse/keyboard actions. A workspace directory constrains ORB's own file tools (traversal and symlink escapes are rejected) but is **not** a shell sandbox — arbitrary commands can reach outside it. Enable Computer Access only when the requested task requires local computer access.

---

## Quick start

### Requirements

- macOS 14 Sonoma or newer
- Swift 5.9 or newer
- An OpenRouter API key for Chat, Agent, Account, and authenticated generation features
- Xcode is not required for command-line builds

### Build and run

```bash
git clone https://github.com/Eplisium/orb.git
cd orb

swift build
bash build_app.sh
open ORB.app
```

`build_app.sh` packages the SwiftPM binary into a macOS `.app`, creates the OpenRouter-themed icon, writes the bundle metadata, and applies an ad-hoc code signature. No Developer ID certificate is required for local use.

For a fresh packaged application after source changes:

```bash
swift build && bash build_app.sh
```

### Tests

```bash
swift test
```

The test target covers the model catalog, caching, API decoding, streaming transport and SSE parsing, Chat and Agent lifecycle behavior, cancellation, tool execution, database recovery and migrations, multimodal encoding, MCP connections and capabilities, media models, Markdown rendering, generation settings, model defaults, media transport URL/origin policy, video job lifecycle and resume, model selection, agent tool policy and approvals, credential role routing, request validation, structured reasoning round-trips, durable jobs and assets, media workflow contracts, Responses/Messages/batch adapter contracts, management inventory contracts, and experiment evaluation.

```bash
swift test --filter MediaTransportTests   # run one suite
swift test                                # run everything
```

---

## Project structure

```text
ORB/
├── Package.swift
├── build_app.sh
├── README.md
├── Sources/ORB/
│   ├── ORBApp.swift                 App entry point and window commands
│   ├── ContentView.swift             Browser view model and root navigation
│   ├── Models.swift                  OpenRouter and app data models
│   ├── APIService.swift              Public model catalog and endpoint API
│   ├── OpenRouterClient.swift        Authenticated streaming client
│   ├── OpenRouterStream.swift        Incremental SSE decoder and events
│   ├── AccountService.swift          Credits and activity API
│   ├── KeychainManager.swift         macOS Keychain API-key storage
│   ├── DatabaseManager.swift         SQLite schema, migrations, favorites
│   ├── ConversationStore.swift       Conversation persistence abstraction
│   ├── ChatService.swift              Chat and Agent session coordinator
│   ├── ChatView.swift                 Direct Chat playground
│   ├── AgentView.swift                Native Agent playground
│   ├── NativeAgentModels.swift        Agent wire and tool-call models
│   ├── NativeAgentRunner.swift         Native function-calling loop
│   ├── NativeAgentTools.swift          Local tool definitions and execution
│   ├── MCPConnection.swift             MCP JSON-RPC subprocess connection
│   ├── MCPRegistry.swift               MCP lifecycle and tool routing
│   ├── MediaServices.swift             Image/video/audio/data API clients
│   ├── MediaViews.swift                Generate-section interfaces
│   ├── Core/API/                       Responses/Messages/batch adapters, reasoning detail model
│   ├── Core/Auth/                      Credential roles, profiles, secret-store seam
│   ├── Core/Security/                  Agent tool policy, approvals, workspace path guard
│   ├── Core/Jobs/                      Durable job records and controller
│   ├── Core/Assets/                    Content-addressed asset store
│   ├── Core/Management/                Read-only management inventory adapters
│   ├── Experiments/                    Deterministic experiment evaluation + spend ceilings
│   ├── TestScenarios.swift              Built-in and custom test definitions
│   ├── TestRunner.swift                 Test execution and result persistence
│   ├── TestSuiteView.swift              Test Suite interface
│   └── ...                              Shared views, settings, models, helpers
└── Tests/ORBTests/
    ├── Fixtures/                        API, stream, and MCP fixtures
    └── ...                              Swift unit and integration tests
```

---

## OpenRouter endpoints

| Endpoint | Authentication | Purpose |
|---|---:|---|
| `GET /api/v1/models` | No | Public model catalog |
| `GET /api/v1/models/{id}/endpoints` | No | Provider endpoint details |
| `GET /api/v1/credits` | Yes | Credit balance and usage |
| `GET /api/v1/activity` | Yes | Account activity history |
| `POST /api/v1/chat/completions` | Yes | Streaming Chat and Agent completions |
| `GET /api/v1/images/models` | Yes | Image model catalog |
| `POST /api/v1/images` | Yes | Image generation |
| `GET /api/v1/videos/models` | Yes | Video model catalog |
| `POST /api/v1/videos` | Yes | Video job submission |
| `POST /api/v1/audio/speech` | Yes | Speech synthesis |
| `POST /api/v1/audio/transcriptions` | Yes | Audio transcription |
| `POST /api/v1/embeddings` | Yes | Embedding generation |
| `POST /api/v1/rerank` | Yes | Document reranking |
| `GET /api/v1/generation` | Yes | Per-generation usage/cost metadata |
| `GET /api/v1/images/models/{id}/endpoints` | Yes | Per-model image endpoint discovery |
| `POST /api/v1/responses` | Yes | Responses API (stateless; adapter) |
| `POST /api/v1/messages` | Yes | Anthropic-compatible Messages (adapter) |
| `POST /api/beta/batches` + GET/DELETE | Yes | Beta batch jobs (adapter; no cancel) |
| `GET /api/v1/keys`, `/byok`, `/guardrails`, `/workspaces`, `/organization/members`, `/observability/destinations`, `/benchmarks`, `/datasets/*` | Management key | Read-only management inventory |
| `POST /api/v1/auth/keys` | — | PKCE code exchange (delivers the key to the Keychain) |

Downloads of generated media (`unsigned_urls`) are deliberately credential-free: the bearer token is never sent to a non-API origin.

---

## Continuous integration

GitHub Actions runs on `macos-15` for pushes and pull requests targeting `main`, plus manual workflow dispatches. The workflow selects the latest stable Xcode, runs `swift build`, and runs `swift test`.

---

## Known limitations

Honest state of the implementation (audit baseline commit `5403ea9` → present):

- **Management mutations are not implemented.** The management inventory is strictly read-only (keys, BYOK, guardrails, workspaces, organization members, observability destinations, benchmarks, datasets). Creating or rotating keys, budget changes, and guardrail assignments are deliberately absent. A management-key add/remove section exists in Settings → API Key; deeper management UI (workspace/budget browsers) is not built.
- **Responses/Messages/batch adapters are not wired into the chat UI.** They are contract-tested adapters; the chat playground still speaks chat-completions. The batch envelope has no UI.
- **PKCE connect is service-level.** The coordinator (S256, loopback callback, replay/origin/state rejection, key delivered to the credential store) is implemented and tested; the Settings "connect via browser" button that drives it is not wired yet. Note: OpenRouter's docs don't guarantee that `callback_url` query strings survive redirect — ORB fails closed on a missing state rather than accepting an uncorrelated callback; verify live when wiring the UI.
- **Agent capability modes beyond Web Only / Computer Access are policy-level only.** The workspace read/write/terminal presets and the approval coordinator are implemented and tested; the Agent UI still exposes the single Computer Access toggle, and approvals are not yet surfaced as a prompt sheet.
- **Experiment evaluation is deterministic-only.** Artifact checks and refusal detection never fake a pass; there is no LLM-judge score (by design — it is not proof) and no human-review recording yet. The spend ceiling accrues only *known* costs; runs whose cost is unknown are labelled unknown rather than blocked.
- **Structured reasoning is preserved, not displayed.** Signature/encrypted blocks are kept byte-exact for wire continuity and never rendered as text; the UI shows only text/summary blocks.
- **Attribution is deliberately omitted.** No `HTTP-Referer` is sent (an owner-approved URL is required to restore it); `X-OpenRouter-Title: ORB` identifies the app.
- **The in-app Test Suite is an experiments harness**, not a scored benchmark; scenario results now carry deterministic verdicts, but cross-model league tables are not a claim of model quality.
- **The app shell is unchanged.** Navigation/layout still match the original design; `AppEnvironment`/`AppRouter`/`ORBTheme`/`ORBMetrics` exist and are tested, but the shell redesign (plan W07/W08) has not been executed and needs visual verification with the app running.

---

## Contributing

1. Fork the repository.
2. Create a feature branch:
   ```bash
   git checkout -b feature/your-change
   ```
3. Make the change and run:
   ```bash
   swift build
   swift test
   ```
4. Commit with a descriptive message.
5. Push the branch and open a pull request.

---

## License

MIT License. See `LICENSE` when present in the distribution for the complete license text.

<p align="center">
  <sub>Built with SwiftUI and OpenRouter.</sub>
</p>
