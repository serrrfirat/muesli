# Local delivery decisions

## 2026-10-03: user-approved scope

Ship a locally built native macOS binary, not a notarized public release or deployed TEE. `./scripts/e2e.sh` launches the actual binary and exercises feature flows. No unit tests. Every feature and bug has a dedicated GitHub issue. Up to ten failed E2E fix/retest attempts per issue, then report the blocker. Agents use test-only external mocks where credentials are unavailable. No spending, on-chain transactions, or changes to system security settings.

## Implementation judgment calls

1. Full Xcode is absent; Swift 6.3 and the macOS SDK are installed. Use SwiftPM to compile SwiftUI/AppKit and package the executable into a local `.app` with scripts. Do not require XcodeGen or Xcode installation to run locally.
2. Superseded by the Muesli migration (historical Hush #63): build `MuesliNativeApp` from `native/MuesliNative` in the canonical `serrrfirat/muesli` fork, package it as `Hush.app`, and retain the original bundle/data/Keychain identities. There is no second Hush UI/executable implementation or nested Hush-repository dependency.
3. Test mode is enabled only via `--e2e` plus an explicit local mock URL. It displays 'TEST MODE — external services mocked' and never displays 'Verified private'. Real mode fails closed on unverified endpoints. Loopback mocks must not be selectable as a production verification policy.
4. The app E2E command interface invokes the same application model/actions used by SwiftUI, not a separate implementation. It emits JSON snapshots and saves a screenshot. OS audio capture is exercised separately; deterministic audio fixtures cover transcription flow without requiring privileged permission changes. Permission denial is evidence, never silently replaced by a simulated recording.
5. All local feature data is encrypted on disk. No plaintext notes, audio, keys, or wallet secrets in logs. Backup restore validates integrity before replacing data.
6. Mock inference/wallet/staking/attestation exercises external protocol behavior only. Production GPU/TDX evidence, actual model quality, on-chain staking economics, notarization, and deployed proxy isolation require live evidence and stay explicitly unverified locally.
7. Agents own disjoint source files; parent owns Package.swift, the app coordinator/UI, scripts, integration and issue evidence. No mid-flight builds/tests/formatters in children; the integration owner runs verification after integration.

## Shared source contracts (integration owner owns Models.swift)

The historical Hush contracts below remain internal to the native `MuesliNativeApp` module. Prefer Swift concurrency; the UI coordinator is @MainActor. Native adapters reuse these contracts rather than replacing their durability or verification semantics.

- `AudioChannel: String, Codable, Sendable`: `.me`, `.them`.
- `AudioFrame: Sendable`: channel, samples `[Float]`, sampleRate `Double`, timestamp `TimeInterval`.
- `AudioChunk: Codable, Sendable`: id `UUID`, channel, start/end `TimeInterval`, data `Data`, mimeType `String`.
- `TranscriptSegment: Codable, Sendable`: id `UUID`, chunkID `UUID`, channel, start/end `TimeInterval`, text `String`.
- `Meeting: Codable, Sendable, Identifiable`: id `UUID`, title `String`, startedAt `Date`, segments `[TranscriptSegment]`, scratchNotes `String`, summary `String`, embeddings `[[Float]]`.
- `AppSettings: Codable, Sendable`: endpointURL `String`, model `String`, template `String`, customTemplate `String`, backupDirectory `String`.
- `Quota: Codable, Sendable`: stakedYocto `String`, creditsUsd `Double`, usedUsd `Double`.
- `TrustStatus: Codable, Sendable`: state `String` ('unverified', 'verified', 'mock'), detail `String`, verifiedAt `Date?`.

### Audio.swift owner

`@MainActor final class AudioRecorder` with `func authorizeMicrophone() async throws`, `func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws`, `func stop() async throws`, `static func chunkFile(_ url: URL, channel: AudioChannel = .them) throws -> [AudioChunk]`. Consent is requested before meeting reservation, then revalidated at device startup. Production uses real microphone and system capture. Stop is single-flight; delayed failure callbacks are scoped to their recording generation. `lastCapturedDurations` reports PCM seconds actually consumed by each chunker after stop, including legitimate silence; source metadata distinguishes physical capture from the explicitly authorized synthetic microphone below. Expose permission/device errors rather than silently dropping channels.

### Vault.swift owner

`final class Vault` with `init(directory: URL, testMode: Bool = false) throws`, `func meetings() throws -> [Meeting]`, `func save(_ meeting: Meeting) throws`, `func delete(_ id: UUID) throws`, `func exportBackup(to: URL, recoveryPhrase: String) throws`, `func restoreBackup(from: URL, recoveryPhrase: String) throws`, `func search(_ query: String) throws -> [Meeting]`, `func semanticSearch(_ vector: [Float]) throws -> [Meeting]`. Local encryption, Keychain in normal mode; test key isolated to test root. Recovery phrase generated with `static func generateRecoveryPhrase() throws -> String`. Storage decisions documented by owner; no fake SQLCipher.

### Inference.swift + Trust.swift owner

`actor InferenceClient` with `init(baseURL: URL, apiKey: String, testMode: Bool = false)`, `func transcribe(_ chunk: AudioChunk) async throws -> TranscriptSegment`, `func summarize(_ meeting: Meeting, template: String, model: String) async throws -> String`, `func embed(_ texts: [String]) async throws -> [[Float]]`, `func ask(_ question: String, meetings: [Meeting], model: String) async throws -> String`, `func trustStatus() async -> TrustStatus`, `func verify() async throws -> TrustStatus`, `func login(accountID: String) async throws -> String`, `func quota() async throws -> Quota`, `func stake(amount: String) async throws -> Quota`. Live wallet signing requires browser/NEP-413, no server-held signing key; local login/stake uses mock protocol. Real stake method prepares a wallet transaction rather than signing it. Production inference must fail closed if verification cannot be performed; implement actual verification where evidence allows, report missing evidence without fake success.

### proxy/ owner

Python standard-library local proxy/mock service (boring, zero dependency launch), `python3 proxy/server.py --port N --mock` or `--upstream https://cloud-api.near.ai`. Mock mode endpoints: `GET /health`, `GET /v1/model/list`, `GET /attestation`, `GET /quota`, `POST /auth/challenge`, `POST /auth/verify`, `POST /stake`, OpenAI-compatible transcription/chat/embeddings. All mocks visibly identify themselves. Upstream mode requires an API key via environment, authenticated session, allowlisted models, size limit, no content logging. Owner provides protocol details in proxy/README.md and communicates them to inference agent. Include deployment/TEE configuration only if real and clearly unverified, not a dummy attestation quote.

### Parent integration and binary E2E

`--e2e --root <isolated dir> --endpoint <loopback URL> --commands <JSON file> --results <JSON file>` starts SwiftUI, executes commands through application model, emits success/failure JSON and screenshot. Actions: importAudio, record/stop (permission aware), summarize, saveScratchNotes, search, ask, backup, restore, deleteMeeting, login, quota, stake, reopen/read persisted data, rejectedModel, rejectedEndpoint. Exact command schema documented in scripts/README.md by integration owner. UI must expose those feature actions for normal users too.

## Direct inference versus optional billing proxy (#44)

The native app's production default endpoint is `https://cloud-api.near.ai`: direct provider inference, subject to approved provider attestation and fail-closed verification. Core capture, notes, encrypted storage, backups and search do not require an additional TEE proxy.

A proxy is needed only when offering a shared provider credential and wallet-funded billing/quota: keep the provider key server-side, authenticate wallet entitlement, account usage, and map staking entitlement into credit. An attested proxy can protect its own code, secrets and any plaintext it handles from the host operator; it does not supply missing upstream model privacy or replace upstream attestation. This extra trust/availability/measurement boundary is deliberately optional, not a prerequisite to direct use.

The local loopback server remains an explicit deterministic inference/wallet fixture for binary E2E. Running that fixture does not claim production TEE deployment, genuine wallet signatures or staking rewards.


## Capture evidence and local signing (#42, #43, #45)

Conversational authorization is not a macOS TCC grant. A real capture success requires actual microphone PCM, known external `afplay` audio traversing the Core Audio process tap into a `them` transcript, ordered persisted segments, a drained encrypted queue, and restart equality. Test-only external inference remains mocked. Silence on the physical microphone is legitimate and does not establish interleaved audible-channel ordering. The later explicitly authorized synthetic-microphone mode is separate evidence, not a real-microphone success.

Device-failure scenarios remove only the unique newly-created process-private aggregate, verified from its composition, UUID, one tap and absence of physical subdevices. They never alter default/physical devices or global input/output settings. The failed-start case denies writes only on the isolated E2E vault and restores permissions; it proves refusal before capture, not a fabricated device failure.

The local app is ad-hoc signed. `codesign -d -r-` shows its designated requirement is its code hash, so rebuilding changes the permission identity. A prior build's approval is not proof that macOS authorizes the current build. Do not relax signature requirements, modify TCC databases, bypass permission prompts or claim a pending prompt passed.

## Missing input versus permission (#42)

An earlier direct-launched app reported microphone authorization granted, but Core Audio returned an unknown default input and enumerated zero input-capable devices. Opening `AVAudioEngine.inputNode` in that state raised an Objective-C audio exception rather than a catchable Swift error. Check the actual default input before opening the engine or reserving a meeting, report “Connect or select a microphone,” and preserve existing data. A subsequently connected microphone enabled actual two-channel capture and lifecycle proof. Input availability later changed; do not infer why or install a virtual microphone or change global devices to manufacture success.

## Durable capture and quit gates (#43, #45–#50)

Live chunk delivery synchronously appends encrypted audio before returning to the capture worker; UI/upload tasks cannot own that durability boundary. Failed writes remain in a session ledger, stop capture, and prevent normal termination until the ledger is persisted. Transcription and acknowledgment commit together against the latest meeting snapshot. A failed start discards only an untouched provisional meeting; concurrent user edits or saved audio survive.

Recorder failures are scoped to their recording generation, model callbacks to their session identity, and post-await UI updates recheck identity. Shared stop/drain tasks clear their own flight before publishing completion; an older waiter cannot clear a newer operation. During quit preparation, queued chunk callbacks cannot overwrite the delegate's durability refusal.

The quit-tail gate must request real AppKit termination while known external playback is still buffered and no system chunk from that session is persisted or transcribed. Recovery after restart must therefore come from shutdown drain, not the chunker's earlier silence flush. A separate real live-write denial must cause the first AppKit quit to be refused, restore the isolated vault's exact permissions, persist retained audio and allow a later quit. Timing metadata must name monotonic elapsed time at request, not nominal sleeps or final PCM duration.

External playback belongs to the E2E application and its isolated launcher process group. Cleanup must observe bounded exit and reap it, escalating only owned processes if necessary. Launcher cleanup errors must not replace the primary scenario failure. Real-hardware and mixed-source runs are reported separately; a synthetic microphone never proves physical microphone behavior.

## User-authorized synthetic microphone (#55)

The user explicitly authorized faking the microphone for subsequent verification after real-microphone capture had been exercised. `--e2e --synthetic-microphone` replaces only the microphone producer with bounded, preallocated audible PCM delivered through the unchanged capture pipe, chunker, encrypted ledger and application lifecycle. Production defaults to AVAudioEngine; the binary rejects this flag without E2E, and the harness requires `--capture`. No virtual driver, default-device change or permission bypass is involved.

The system channel remains a real Core Audio process tap fed by external `afplay`. UI and result metadata explicitly name the synthetic microphone; mixed-source runs cannot set real-microphone or both-real-channel proof flags. Source selection is fixed for each recorder instance, not a fallback after a hardware failure.

## Reported capture failure consumption (#54)

An automatically reported capture failure must not be reinstalled as a deferred error after its stop task completes. Current shared waiters and the UI receive the failure; only an unreported error still belonging to the original generation may remain deferred. Actual private-aggregate health failure followed by a new recording in the same process passed after this correction.

## Actual AppKit termination from native events (#56)

Calling `NSApplication.terminate` directly inside the E2E MainActor Swift task trapped the task in AppKit's deferred-termination nested run loop; the asynchronous delegate could not finish. An attached debugger observed that stack. E2E now schedules the request through `RunLoop.main.perform` and suspends its task through a continuation, leaving native event processing able to run the delegate. The live-buffer checks and monotonic request marker run inside that native event immediately before termination. A targeted mixed-source recording observed actual `willTerminate`, persisted both channels and reaped playback in 4.16 seconds; this is not a physical-microphone quit claim.


## Hush rebrand (#60)

Historical rebrand: the user selected **Hush**, and that stage used `serrrfirat/hush`. The Muesli strategy below supersedes that repository and UI; ongoing development belongs in `serrrfirat/muesli`. Legacy storage/protocol names remain where compatibility requires them. The proxy's operator secret variable is `HUSH_UPSTREAM_API_KEY`; its explicit mock response header is `X-Hush-Mode`.

Do not cosmetically rename persistent cryptographic identities. Existing Application Support directories, path-derived Keychain accounts, `PrivateGranola.Vault.v1`/`PrivateGranola.Inference` service names, backup authenticated-envelope domain, recovery-phrase format and `ai.privategranola.local` bundle identifier remain stable. Moving a vault or replacing its service/domain would orphan keys or reject existing authenticated backups; retaining these internal identifiers avoids that risk without moving or copying secrets. New product branding does not imply trademark clearance or stronger privacy guarantees.

## Granola desktop visual design (#62)

The UI mirrors Granola 7.595.3 for macOS. Reference sources: the installed app's renderer stylesheet (its "oats" light-theme tokens: surfaces, ink, hairline, olive accent, radii, 36/28/24pt serif display scale), its rendered sign-in screen, and Granola's own help-center/marketing screenshots for the authenticated layout. Granola deliberately strips `--remote-debugging-port`; that guard was not bypassed, and the authenticated renderer was not faked with stubbed IPC or account data.

Tokens live in `Theme.swift` (`Oats`) and resolve per appearance from Granola's `:root` (light) and `html.dark` values. Granola's licensed typefaces (Quadrant Notepad, KMR Melange Grotesk, Radion), logo and artwork are not bundled; the system serif (New York) and SF stand in. Settings › Appearance offers System/Light/Dark, stored in UserDefaults (`appearance`) because it is a non-sensitive UI preference, not vault data; `-appearance Dark` overrides it per launch without persisting.

Layout: collapsible sunken sidebar (titlebar toggle ⌘\ and search ⌘K beside the traffic lights, Home, Chat, the private "My notes" space, import/retry/settings icons, trust capsule, status), "Coming up" calendar landing, Chat page (greeting, composer, recipe chips over the existing `ask` action), note view with floating Notes/Transcript toggle, transcribing bars and ask bar. Granola's demo-meeting slot becomes a consent-reminding private-note entry.

"Coming up" reads the local calendar through EventKit after the user presses Connect calendar and accepts the macOS prompt (`NSCalendarsFullAccessUsageDescription`). Events are read-only, held in memory, never logged, persisted, or sent to inference; only the chosen event title names a recording started from it. Binary E2E (`--e2e`) never constructs calendar access, so evidence screenshots and results cannot contain real events; the connected state therefore has no automated evidence.

`AppModel.screen` (home/chat/meeting) is window navigation only. `selectedID` remains the action target that `refresh()` keeps populated for E2E and menu-bar actions; import and recording open the new meeting, delete and restore return home. E2E `showScreen` sets the same state as the sidebar buttons. Test-mode banner text, `record-button`/`enhance-button` identifiers and `detailTab` values are unchanged.

## Muesli-native strategy (#63)

The user changed strategy: port the required Hush workflow into the Muesli fork, preserve every existing E2E scenario and recently implemented feature, and keep Muesli's UI. The canonical repository is `serrrfirat/muesli`, based directly on upstream `85ed3f891061c5bdeb05f7fed3601bb140450973`, with its existing `native/`, `assets/`, `scripts/` and upstream Git history preserved. Publishing a nested copy to Hush was the wrong repository cutover. The actual product is Muesli's native dashboard, not the former Granola-inspired Hush window. The visual implementation in historical Hush #62 is superseded; its appearance, calendar, chat, recipes, sidebar and navigation behaviors remain through native views/actions. Numbered issue references in these carried-over decisions describe historical Hush work, not the canonical repository.

The original authenticated vault and encrypted audio queue remain authoritative. A UUID-to-native-ID SQLCipher projection drives Muesli's timeline/detail/search; its 32-byte key is HKDF-SHA256 of the original vault key, salt `PrivateGranola.Vault.v1`, info `Hush.Muesli.SQLCipher.v1`. Shared `HushDatabaseEncryption` keeps the original path-hash Keychain account/service and derivation identical for standalone clients. A missing registry uses the original Keychain read noninteractively; missing/locked keys and plaintext SQLite fail closed, without replacement keys or automatic plaintext conversion.

Native edits and summaries commit back to the authenticated source, preserving concurrent-edit checks. Unchanged authenticated refreshes do not rewrite the projection; read-only failed starts must preserve notes and must not misreport filesystem/WAL errors as bad encryption keys (#67). Native Stop bypasses the busy guard, and confirmed discard snapshots the actual recording UUID before stopping, never the currently selected unrelated meeting. Pause gates both PCM producers, flushes pre-pause buffers, and preserves host-clock gaps without replaying paused audio.

Meeting ASR retains the native local selector. Normalized capture/import chunks become 16 kHz floats in RAM and use the real Muesli model adapters; NEAR AI uses the existing verified client before any cloud transcription. Native summaries/templates use the shared verified NEAR generation path or explicitly local loopback providers; unverified hosted choices are disabled and rejected before egress. Private Hush rows are hard-excluded from native CloudKit selectors, even if edited/marked dirty. Telemetry and upstream update feeds are disabled. Hush startup does not run inherited display-name-only global aggregate cleanup (#66); its recorder retains creation-owned teardown.

Calendar events, attendees and occurrence identifiers remain RAM-only; a chosen title may name an encrypted meeting. Encrypted meeting backups cover the original Hush meetings/queued audio, not native dictations, folder context or settings; the UI states that scope.

Every original binary scenario remains. New native scenarios compare authenticated/native content, execute actual native summary/search, verify original-Keychain recovery in a fresh unregistered process, enqueue command events through AppKit's real loop, observe measured sidebar width and actual field-editor focus, and verify effective appearance plus a rendered background sample. The idle native UI keeps the explicit external-mock banner (#65). Bundles are assembled in a fresh staging directory and published only after signing, so read-only binary dependencies cannot break repeated builds.

The source keeps the macOS 14.2 declaration and availability guards; actual local build evidence is Swift 6.3.3/macOS 26.5, including real Whisper `tiny.en` on synthetic speech. Other model quality, production GPU/TDX attestation, live wallet/staking and notarization are not inferred. CI selects macOS 26/Xcode 26.6 per the [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md); local results do not claim a hosted CI run.

The fork preserves its upstream CI/build/test lanes. Native release, test-shard, packaged-CLI and cache-experiment jobs install libsodium/SQLCipher for the new SwiftPM system-library dependencies; the added real-binary E2E workflow uses the same canonical source and asset paths. Dependency build caches are disposable: relocated Clang module caches embed their original absolute path and must be rebuilt, not treated as a source/compiler defect.
