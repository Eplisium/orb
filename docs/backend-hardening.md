# Backend hardening regression map

The backend audit identified 21 defects. This map connects each repair to its regression coverage; test names are in `Tests/ORBTests/`. All tests use mock transports/credential stores, disposable storage, or a bounded local MCP fixture. No paid OpenRouter requests are needed.

| ID | Repair | Primary regression suite |
|---|---|---|
| B01 | Missing approval coordinator denies gated tools; Test Suite uses a fresh supervised approval scope | AgentBackendFixTests, AgentAccountingFixTests, TestSuiteApprovalFixTests |
| B02 | Failed/partial SQLite reads throw instead of producing editable empty transcripts | StorageBackendFixTests |
| B03 | Distinct MCP servers have distinct routing and authorization identities | MCPBackendFixTests |
| B04 | Unavailable current credentials cannot trigger destructive legacy migration | CredentialBackendFixTests |
| B05 | Edit truncation commits transactionally before publishing the replacement transcript | ChatBackendFixTests |
| B06 | Asset and Library save failures preserve the downloaded input for retry/export | MediaBackendFixTests |
| B07 | File offsets are checked before arithmetic and slicing | AgentBackendFixTests |
| B08 | Extreme Retry-After values cannot trap during error formatting | ChatBackendFixTests |
| B09 | Preserve model known subtotals and unknown pricing; account for independently billed helpers without double counting | AgentAccountingFixTests and helper accounting regressions |
| B10 | Rejected ledger events remain visible and retryable with their original identities | StorageBackendFixTests |
| B11 | Streamed combining characters/emoji/CRLF survive transcript publication | ChatBackendFixTests |
| B12 | SQLite strings retain embedded NULs and exact UTF-8 payloads | StorageBackendFixTests |
| B13 | Credential changes invalidate other account-service instances and late responses | CredentialBackendFixTests, AccountServiceCredentialLifecycleTests |
| B14 | Remote file deletion requires affirmative confirmation for the requested ID | MediaBackendFixTests |
| B15 | Replacement Image/Video callers await a service-owned catalog refresh | MediaBackendFixTests |
| B16 | A terminal adapter event is not overturned by residual framing validation | ChatBackendFixTests |
| B17 | MCP stdin queueing/writes are bounded, cancellable and ordered | MCPBackendFixTests |
| B18 | Live MCP processes reconcile changed configuration rather than only their display names | MCPBackendFixTests |
| B19 | Video polls validate job identity before publishing, persisting, or accounting | MediaBackendFixTests |
| B20 | Sparse/resumed video responses retain known cost, including explicit zero | MediaBackendFixTests |
| B21 | Advanced adapter index conversion rejects nonrepresentable integers | ChatBackendFixTests |

Approval lifetime coverage additionally delays a UI handler until after cancellation and checks that it cannot enqueue a stale prompt. Test Suite presentation hosts have stable identities: removing a non-owning window must not deny the active window's request.

## Verification commands

```bash
# Node is optional for most unit tests but required to exercise MCP process I/O.
NODE_BINARY="$(command -v node)" swift test --no-parallel
swift build
bash build_app.sh
codesign --verify --deep --strict ORB.app
```

Use the host's resource limits where required. Live paid integration tests and visual rendering snapshots remain opt-in; a green offline suite does not claim those were exercised.

## Important boundaries

- Approval is not sandboxing. Approved shell commands and trusted MCP processes still run with the user's macOS permissions. OP Mode explicitly bypasses prompts only in Agent runs.
- A comparison ceiling is checked between model runs, not inside every provider request. It cannot guarantee a hard dollar cap.
- Failed ledger writes are retained **in memory**, with a visible warning/retry action. Quitting before a successful retry can lose those pending events; this is not a durable outbox.
- Remote video polling can be stopped locally without cancelling or refunding the remote generation.
- Asset-store metadata and the Library manifest are separate persistence layers. Retry inputs survive a failed outer commit; an orphaned content-addressed asset may remain and be deduplicated on retry.
- Public MCP tool namespaces and legacy Keychain secret references are separate identities. Changing RPC naming must not rename or discard existing credential references.
