# Contributing to ORB

Bug reports, fixes, and focused features are welcome.

## Setup

- macOS 14 or newer, Swift 5.9 or newer (Xcode or the Command Line Tools).
- No other dependencies.

```bash
git clone https://github.com/Eplisium/orb.git
cd orb
swift build
swift test
bash build_app.sh --adhoc && open ORB.app   # optional: run the packaged app
```

## Before you open a pull request

1. **Build and test cleanly.**
   ```bash
   set -o pipefail
   swift build --build-tests 2>&1 | tee build.log
   swift test --skip-build
   bash scripts/count_warnings.sh build.log   # please don't increase this
   ```
   Don't pipe test output through `grep` or `tail` without `pipefail`. Otherwise a failing run can look like it passed.
2. **Add tests.** Use Swift Testing (`import Testing`, `@Test`, `#expect`). For bug fixes, write a failing test first where practical.
3. **Keep tests offline and hermetic.** Tests must never read the real Keychain, call OpenRouter with a key, or write the production database (`~/Library/Application Support/ORB`). Inject stores, clients, and transports instead. `DatabaseManager` isolates itself to a temporary database under tests.
4. **Gate opt-in tests with traits**, not early returns, so they show as skipped:
   ```swift
   @Test("…", .enabled(if: ProcessInfo.processInfo.environment["MY_FLAG"] != nil, "why"))
   ```
   Run rendering snapshot tests separately from the full suite (see the README).
5. **Update docs.** Update the README, `docs/ARCHITECTURE.md`, and add an entry under *Unreleased* in `CHANGELOG.md` if behavior changes.

## Conventions

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `feat(agent): …`, `fix(chat): …`, `docs: …`, `ci: …`, `test: …`.
- Keep files focused. Prefer a new small file over making a 1,000-line file longer.
- UI services are `@MainActor`. Strict concurrency checking is on (as warnings), so don't add new data-race warnings.
- Database changes must be idempotent: use `CREATE TABLE IF NOT EXISTS` / `addColumnIfMissing`, and bump `user_version` only for real schema migrations.
- Security-sensitive code (credentials, tool policy, approvals, MCP launch, URL validation) must fail closed. Add tests for the denial paths.

## Never commit

- API keys, `.env` files, or anything in `codesign/` (signing keys and certificates).
- Absolute paths that include a username (`/Users/<name>/…`). Use `NSHomeDirectory()` or relative paths.
- Built bundles (`ORB.app`), local databases, or agent and tool workspaces (`.hermes*`).

`.gitignore` covers these, but check the staged diff anyway (`git diff --cached`).

## Reporting bugs and security issues

Use the issue templates for bugs and feature requests. **Don't** file public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
