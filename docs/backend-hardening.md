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

## Extended Library audit

| ID | Repair | Primary regression suite |
|---|---|---|
| E01 | Store-owned pending removals protect shared bytes across window Undo lifetimes | LibraryExtendedAuditTests |
| E02 | Failed attachment lookup denies asset deletion | LibraryExtendedAuditTests |
| E03 | Stage-and-rename export preserves old destinations and refuses managed files/aliases; Image/Speech recovery bytes use the same checks | LibraryExtendedAuditTests, SavedCreationFileURLTests |
| E04 | Failed/partial SQLite asset reads or undecodable metadata rows stop cleanup before metadata/bytes change | AssetRemovalFailureTests |

Export protection here covers single-item Library/Video/Speech and generated Image/Speech actions, not every app exporter. Bulk export retains no-overwrite naming/copy behavior. Filesystem identities must be readable; unsupported destination filesystems fail closed. The distributed metadata/file deletion sequence is not a cross-store transaction.

## Extended video recovery audit

| ID | Repair | Primary regression suite |
|---|---|---|
| V01 | Commit remote job identity with the Library entry; retry a rejected SQLite link without duplicate download/save, even after reopening | VideoSaveLinkFailureTests, VideoDownloadRecoveryTests |

The identity is optional for legacy compatibility. It protects newly saved videos; historical unlinked entries cannot be associated retroactively. The SQLite link and Library manifest remain separate commits, and link-write errors remain visible through the job controller.

## Extended job persistence audit

| ID | Repair | Primary regression suite |
|---|---|---|
| J01 | Checked complete core/media reads prevent failed lookups from erasing recovery fields or duplicating jobs; invalid optional identities and partial inventories fail closed | JobReadFailureTests |
| J03 | Core and media fields commit atomically, so failed recovery-field writes cannot leave a terminal or partial record | JobWriteFailureTests |
| J04 | Failed parameter binding aborts full/legacy media writes instead of clearing persisted fields | JobWriteFailureTests |

Controller errors remain visible and no mutation follows a failed read. Core/media writes use one upsert; failed initial submissions still do not have a durable retry queue. The Library manifest and job saved-link update remain separate commits.

## Extended MCP audit

| ID | Repair | Primary regression suite |
|---|---|---|
| M01 | Cancelled lifecycle waiters unregister promptly without late side effects; cancelled initial startup stays retryable without a false server failure | MCPHeldResponseTests, MCPDiscoveryCancellationTests |
| M02 | Cancellation during optional resource/prompt discovery escapes startup and prevents partial registry publication; ordinary RPC errors remain optional | MCPDiscoveryCancellationTests |
| M04 | Startup checks original transport identity/liveness after awaits; shutdown and child exit during optional discovery cannot report success | MCPDiscoveryCancellationTests |

The fixtures hold actual discovery, initialize and tool/resource/prompt responses and expose receipt state through an offline RPC. `MCPHeldResponseTests` verifies late initialize success/error and RPC results after config replacement, plus literal impersonation of computed compact names. Direct concurrent `MCPConnection.connect()` behavior remains a separate follow-up audit scope.

## Extended catalog audit

| ID | Repair | Primary regression suite |
|---|---|---|
| C01 | Generated endpoint identity suffixes reserve literal tags/fallback IDs and all assigned identities | EndpointIdentityCollisionTests |
| C02 | Replacement Speech/transcription/embedding/rerank callers await model-owned discovery despite departing-view cancellation | ModalityCatalogLifecycleTests |

Endpoint collision coverage uses decoded payloads and an injected `APIService` response; it does not claim the production catalog currently contains a colliding tag.

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
