# Running and testing the actual app

Run these commands from the canonical `serrrfirat/muesli` fork. The package is `native/MuesliNative`, assets are under `assets/`, and the retained proxy/E2E harness is part of this repository. No Hush checkout or nested Muesli tree is required. The legacy `Hush.app`/bundle/Keychain names preserve existing encrypted data access; the application UI is Muesli.

Prerequisites: macOS 14.2+ source target, Swift 6.3 Command Line Tools, Homebrew libsodium and SQLCipher (`brew install libsodium sqlcipher`), Python 3. The local artifact was exercised on macOS 26.5; installed Homebrew bottles impose their own minimum OS versions. No full Xcode required. Verification uses real-binary E2E, not unit tests.

```
./scripts/start.sh               # build, package, ad-hoc sign and launch native app
./scripts/start.sh --mock        # interactive demo; owns mock service lifecycle
./scripts/e2e.sh --capture-off   # actual app + explicit external mocks; no recording-success claim
./scripts/e2e.sh --capture       # real mic/system lifecycle; connected mic + OS permission required
./scripts/e2e.sh --capture --synthetic-microphone --playback  # explicit fake mic; real system tap/AppKit/playback
./scripts/e2e.sh --capture-off --playback  # additionally prove real external playback early-stop/reap
```

E2E creates isolated encrypted vaults, commands, results, process logs and screenshots under `.e2e/<timestamp>/`. It starts the mock proxy automatically, starts the actual app, invokes the same AppModel actions that SwiftUI buttons use, then quits and relaunches to verify persistence. It verifies failed backup restore does not destroy existing data and plaintext does not appear in persisted files.

The gate also exercises normal Keychain-backed storage through `--keychain-vault`, preserving mocked external services while using the real local key path. Test keys/fixtures are isolated by root; it never reads or prints unrelated Keychain credentials. It covers a 65-second audio file split at 30/60 seconds, silence rejection, queued audio inside encrypted backups, concurrent edits/restore, credential-sentinel rejection, and real proxy HTTP security boundaries.

The local mock is **not** real NEAR AI, genuine TDX/GPU attestation, a wallet signature, staking yield, or paid infrastructure. The app displays a test-mode banner. Production verification cannot silently switch to mock mode.

The user-authorized `--synthetic-microphone` option replaces only the microphone producer with audible E2E PCM through the shared capture pipe. The harness requires `--capture`; the binary requires `--e2e`. Production defaults to a real microphone. UI, per-scenario source metadata and summary fields distinguish mixed-source proof from real-microphone proof; no virtual driver, default-device change or automatic fallback is involved.

For migration compatibility, add `--compatibility-evidence .e2e/<previous-successful-Hush-run>` to the gate. It opens the previous encrypted mock and Keychain vaults at their original paths and restores the previous authenticated backup into a fresh isolated root, comparing exact snapshots. Evidence from the same binary or another Muesli run is rejected. Every launch records actual AppKit identity and native Muesli presentation beside its screenshot. Existing storage names and cryptographic identities remain stable; no vault or key migration is performed. macOS may require user approval for the previous ad-hoc build's Keychain item; the harness never changes Keychain access controls.

## Feature/bug issue lifecycle

1. Work from a dedicated GitHub issue. Create a new issue before fixing a new bug; include reproduction and expected behavior.
2. Document judgment calls in `docs/DECISIONS.md` or a slice decision document.
3. Implement the actual UI/model path, not a test-only copy.
4. Run `./scripts/e2e.sh`. Exercise the relevant UI button or binary E2E command; add a regression scenario for a consumer-visible bug.
5. Fix and rerun, at most ten failed E2E attempts per issue. Record failures and evidence; if blocked, keep the issue open and proceed with independent issues.
6. Comment with the exact command, exercised scenarios, evidence location, and mock/live limitations. Close only after all in-scope acceptance criteria pass. Missing credentials do not authorize financial transactions or fabricated verification.

## Binary command interface

```
dist/Hush.app/Contents/MacOS/Hush \
  --e2e --root /absolute/isolated/root --endpoint http://127.0.0.1:PORT \
  --commands /absolute/commands.json --results /absolute/results.json
```

Commands are a JSON array. Each has `action`, optional `value`, `path`, `phrase`, `expectError`, `expectContains`, `expectCount`. Every `expectError:true` MUST include a specific `expectContains` reason; an unrelated error must fail the gate. Assertions execute against real persisted app state and action output. Feature actions include `verify`, `configureMock`, `importAudio`, `notes`, `viewNotes`, `summarize`, `search`, `ask`, `backup`, `restore`, `delete`, `snapshot`, `login`, `quota`, `stake`, `rejectedModel`, `rejectedEndpoint`, `retryQueue`, `pendingQueue`, `concurrentSummaryEdit`, and `concurrentRestore`. A visible actual SwiftUI window is required; a screenshot is captured alongside each result file. Nonzero exit means failure.

`showScreen` with `value` `home`, `chat` or `meeting` sets the same window navigation as the sidebar, so screenshots can cover each page. Appending `-appearance Dark` or `-appearance Light` to the binary arguments renders that appearance without persisting the preference. E2E launches never read the calendar.

Native Muesli actions include `nativeSearch`, `nativeSummary`, `nativeSyncPrivacy`, `nativeToggleSidebar`, `nativeFocusSearch`, and `setAppearance`. Keyboard scenarios enqueue actual AppKit events and require the rendered 68/240-point sidebar and real search field-editor focus. Appearance scenarios check the preference, effective NSAppearance and sampled window background, not just stored settings. `--e2e-unregistered-store --keychain-vault` additionally requires a fresh native store to recover the original real vault key without an in-process key registration.

`nativeLocalTranscription` takes a speech WAV `path` and an optional local model `value` (default `tiny.en`). It downloads/loads the actual selected native ASR model, converts decrypted audio to memory-only 16 kHz samples and persists the recognized transcript through the authenticated Hush vault. This is distinct from mocked external transcription; model weights are real and the first load can require network access.

`captureAuthorization` reports actual microphone permission and default-input availability. When no input exists, `recordUnavailableInput` invokes the same Record action as the UI and requires an actionable failure, stopped state, unchanged persisted meetings and empty queue. This negative scenario is part of the ordinary gate; it does not establish recording success.

Capture actions (`record`, `recordBusy`, `recordQuit`, `recordQuitWriteFailure`, `recordDeviceFailure`, `recordCleanupFailure`, `recordStartFailure`, `recordOverlappingStop`) require the gate's four-second WAV `path`. External `afplay` and the system tap are always real; microphone capture uses AVAudioEngine unless the explicit synthetic option is selected. Normal system transcript coverage must reach four seconds; partial live-tail coverage must reach two seconds. Coverage is the union of valid chronological chunk intervals, never a gap-spanning envelope or double-counted overlap. Partial scenarios collect 2.5 seconds after playback launch to allow startup latency without extending the waveform or weakening minima.

Busy recording must still stop. Device faults destroy only the verified creation-owned private aggregate and require a new successful recording in the same process. Pre-start write denial restores only isolated-vault permissions and proves no empty meeting remains. `recordOverlappingStop` enters two genuine Stop callers and immediately starts another recording when the first completes. Quit actions must be the final command: `recordQuit` requires an unflushed system tail at actual AppKit termination; `recordQuitWriteFailure` denies live writes, observes the delegate's actual negative termination reply, restores exact permissions and persists the retained ledger before the second quit. E2E schedules `NSApplication.terminate` through a native run-loop event so asynchronous delegate work can progress; it never substitutes direct model shutdown or process exit for that proof.

`recordPause` proves both channels consume no PCM while paused, resume with the host-clock gap intact and drain their encrypted queue. `nativeDiscard` invokes the shared confirmed native discard handler and requires deletion of the capture's exact meeting ID while preserving every unrelated meeting, including a separately selected one.

`playbackLifecycle` also takes the four-second WAV `path` and proves early stop, observed termination and reaping of a real owned `afplay`, without opening a microphone. The optional `--playback` gate requires a working output device; hardware-free CI does not silently acquire this prerequisite. Capture observes playback completion for up to six monotonic seconds instead of guessing exit from a fixed sleep; timeout fails. Each app launch owns a separate process group, with bounded cleanup and orphan detection. Primary timeout/error evidence is written before teardown, and cleanup errors are reported separately rather than masking it. Quit metadata distinguishes monotonic elapsed-at-request from final consumed PCM durations; `shutdownCompleted` and `playbackReaped` must be true before acceptance.

Example:
```json
[
  {"action":"verify","expectContains":"mock"},
  {"action":"importAudio","path":"/absolute/meeting.wav","value":"Design review","expectCount":1},
  {"action":"summarize"},
  {"action":"backup","path":"/absolute/backup.pg","phrase":"your generated recovery phrase"}
]
```

Build output is the actual fork's `MuesliNativeApp`, packaged as `dist/Hush.app`, ad-hoc signed, and linked to local Homebrew libsodium and SQLCipher. Fresh staging allows repeated builds without overwriting signed read-only dependencies. This is a local developer artifact, not a distributable release.
