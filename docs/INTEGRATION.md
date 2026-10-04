# Integration evidence and limitations

## Implementation ownership

- AudioCapture subagent: actual Core Audio process tap + AVAudioEngine, shared live/file chunker, meeting mic-activity hints.
- VaultStorage subagent: authenticated-encrypted local snapshots, Keychain keys, backup/restore, encrypted audio queue, lexical/cosine search.
- InferenceTrust subagent: real multipart inference protocols, XChaCha E2EE, model allowlist, mock-only wallet flows, fail-closed production trust.
- ProxyWallet subagent: explicit external mock, real NEP-413 verification/HTTPS forwarding boundary, mock-only local quota/stake and fault controls.
- Integration owner: native SwiftUI, shared application actions, binary E2E, build/start scripts and issue evidence.

## Decisions superseding initial design

Authenticated AES-GCM JSON snapshots remain authoritative for Hush meetings and queued audio, with private modes, atomic whole-snapshot writes and a 512 MiB limit. The Muesli migration (#63) additionally projects native meeting/search rows into SQLCipher using a domain-separated key derived from the original vault key; there is no plaintext SQLite fallback or automatic plaintext migration. Recovery phrases remain secure 256-bit hex strings, not BIP39 mnemonics. Normal keys use the original Keychain service rather than a claimed Secure Enclave wrapping implementation. See vault-decisions.md and DECISIONS.md.

Native builds use the canonical `serrrfirat/muesli` fork's SwiftPM package under `native/MuesliNative`, not XcodeGen or a nested checkout in Hush. The actual Muesli application delegate, controller and dashboard own the UI; the obsolete Hush package/UI is not included. Verification uses real-binary E2E; upstream unit-test targets remain but were not run. Local binaries are ad-hoc signed and link Homebrew libsodium/SQLCipher; no notarization or public distribution claim.

## Tracked integration bugs

- #17: UI Sales/1:1/custom templates were rejected by inference dispatch. Add corresponding formatting instructions, bounded custom templates; binary E2E exercises each.
- #18: Queue drain held stale meeting values across await and could be entered concurrently. Single-flight draining reloads latest notes before appending and deduplicates by chunk ID; queued chunks stay authenticated-encrypted until results persist.
- #19: macOS 14.0 package declaration contradicted process-tap 14.2 availability; throwing credential fallback lacked outer try. Package minimum corrected to 14.2.

- #20 (historical): Direct binary launch entered an idle AppKit event loop without constructing the SwiftUI WindowGroup. The old explicit delegate fixed that launch. #63 supersedes its MeetingView with the real Muesli AppDelegate and DashboardRootView; the native delegate starts the shared Hush action runner after launch, with visible windows and step progress.

## Explicit unavailable production proof

- No configured approved workload measurement/TCB/provenance policy, GPU evidence verification or same-connection TLS binding. Production inference stays fail-closed. Locally mocked evidence is never genuine attestation.
- Wallet browser signing integration, approved staking contract/network/ABI and per-wallet credit backend require live configuration. Local stakes are simulated balances, not transactions/yield. Real proxy auth verifies NEP-413 and access-key ownership, but local tests do not establish mainnet auth.
- Real system audio proof requires permitted capture and known external playback yielding an audible 'them' chunk. File-fixture ingestion proves chunk/transcription plumbing only.
- No live NEAR AI inference credentials were supplied. Mock fixture validates audio and protocol behavior, not transcription accuracy or LLM quality.
- No deployed confidential VM, notarized release, or signed automatic update evidence. Related production issues remain open.

Each issue must state which acceptance is local/mock and which remains blocked; a passing mock run does not authorize closing a production security requirement.
