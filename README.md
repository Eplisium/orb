<p align="center">
  <img src="https://img.shields.io/badge/macOS-Sonoma_14.0+-purple?style=for-the-badge&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange?style=for-the-badge&logo=swift" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT License">
  <img src="https://img.shields.io/badge/Platform-macOS-lightgrey?style=for-the-badge&logo=apple" alt="macOS">
</p>

<h1 align="center">
  <br>
  ORB
  <br>
</h1>

<p align="center">
  <strong>OpenRouter Browser</strong> — A native macOS app for exploring, comparing, and chatting with 300+ AI models via the <a href="https://openrouter.ai">OpenRouter</a> API.
</p>

<p align="center">
  Built entirely with <strong>SwiftUI</strong> and <strong>Swift Package Manager</strong> — no Xcode required.
</p>

---

## Features

<table>
<tr>
<td width="50%">

### Model Browser
- Browse the full OpenRouter model catalog
- Search by name, ID, or provider
- Filter by modality (text, vision, audio)
- Sort by context, pricing, or creation date
- Favorites with persistent notes (SQLite)

</td>
<td width="50%">

### Agent Playground
- Native function-calling agent loop
- File read/write, web fetch, shell commands
- AppleScript & computer automation
- Screen capture & mouse/keyboard control
- Workspace folder & file attachments

</td>
</tr>
<tr>
<td>

### Chat Playground
- Direct streaming conversations with any model
- Temperature & max-tokens controls
- Live cost and token tracking
- Conversation sidebar with history

</td>
<td>

### Account Dashboard
- API key management (Keychain-secured)
- Credits balance & usage breakdown
- Activity history by model & date
- Top models by spend

</td>
</tr>
<tr>
<td>

### Test Suite
- 22 built-in test scenarios across 10 categories
- AI creates real projects using native tools
- Custom test creation & persistence
- Result history with output paths

</td>
<td>

### Architecture
- Three-column `NavigationSplitView`
- `@MainActor` services with async/await
- SSE streaming via `URLSession.bytes`
- SQLite3 via C API (WAL mode)
- Ad-hoc codesign — no developer cert needed

</td>
</tr>
</table>

---

## Quick Start

```bash
# Clone
git clone https://github.com/Eplisium/orb.git
cd orb

# Build
swift build

# Package as .app bundle
bash build_app.sh

# Launch
open ORB.app
```

> No Xcode required. Just Swift 5.9+ and macOS 14 (Sonoma).

---

## Project Structure

```
Sources/ORB/
  ORBApp.swift           App entry point, window config
  Models.swift           Codable data models
  APIService.swift       Public model/endpoint fetching
  AccountService.swift   Authenticated credits & activity
  ChatService.swift      Streaming chat completions
  KeychainManager.swift  macOS Keychain API key storage
  DatabaseManager.swift  SQLite favorites, tests, notes
  ContentView.swift      3-column NavigationSplitView
  Views.swift            Model rows, detail, stats
  SettingsView.swift     API key, credits, activity tabs
  ChatView.swift         Chat playground
  AgentView.swift        Agent playground
  PlaygroundCommon.swift Shared playground components
  NativeAgentTools.swift Native function implementations
  NativeAgentRunner.swift Agent function-calling loop
  NativeAgentModels.swift Agent data models
  TestScenarios.swift    22 test scenarios
  TestSuiteView.swift    Test suite UI & runner

Tests/ORBTests/
  NativeAgentTests.swift Unit & integration tests
```

---

## API Endpoints

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /api/v1/models` | No | Full model catalog |
| `GET /api/v1/models/{id}/endpoints` | No | Per-provider pricing & latency |
| `GET /api/v1/credits` | Yes | Credits balance |
| `GET /api/v1/activity` | Yes | Usage history |
| `POST /api/v1/chat/completions` | Yes | Streaming chat (OpenAI-compatible) |

---

## Tech Stack

- **Swift 5.9+** with strict concurrency
- **SwiftUI** — three-column layout, `.hiddenTitleBar`
- **SQLite3** — C API with WAL journaling
- **macOS Keychain** — secure API key storage
- **URLSession** — SSE streaming for chat
- **Swift Package Manager** — no Xcode project files

---

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/awesome`)
3. Commit your changes (`git commit -m 'Add awesome feature'`)
4. Push to the branch (`git push origin feature/awesome`)
5. Open a Pull Request

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Built with ❤️ using OpenRouter</sub>
</p>
