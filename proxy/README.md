# Hush local protocol service

Issues #10 and #13. Python 3.9+ standard library; no pip packages. `--mock` is an explicit external-service fixture, **not** production inference, a TEE quote, wallet authorization, staking, or yield.

## Start

```sh
python3 proxy/server.py --mock --host 127.0.0.1 --port 8787
python3 proxy/server.py --mock --port 8788 --fail attestation
python3 proxy/server.py --mock --port 8789 --fail model
python3 proxy/server.py --mock --port 8790 --fail quota
```

Failure flags are repeatable: `attestation`, `model`, `quota`, `transcription`, `chat`, `embeddings`. They are prohibited in forwarding mode. Mock binding rejects any resolved non-loopback address, including `0.0.0.0`; `::1` works. `--port 0` selects a free port, reported in the one startup JSON line. Stop with Ctrl-C. Startup reports E2EE availability without logging keys.

Loopback mock-only `POST /mock/control` with JSON `{"fail":["transcription"]}` atomically replaces active injections; `{"fail":[]}` clears them. It has no production counterpart and rejects unknown fields/failures. This lets binary E2E queue audio during a transient 503 and then exercise recovery without restarting the service.

`--delay-ms 0..1000` adds bounded mock inference latency for binary concurrency regressions. `--forbid-credential <synthetic-sentinel>` rejects that sentinel if received in Authorization. Both options are test-only; real forwarding rejects them. Malformed encrypted client keys reject before fixed-width native conversion, including whitespace-containing input.

Real forwarding:

```sh
# Inject the actual provider secret through your process environment/secret manager.
# HUSH_UPSTREAM_API_KEY must already be set; never pass it in argv.
python3 proxy/server.py --upstream https://cloud-api.near.ai --port 8787
```

The forwarding API key is **not** a client bearer/session token. Production inference requests require a server-issued wallet-authenticated bearer session. All upstream traffic uses HTTPS, certificate validation and a 30-second timeout. Redirects are refused, so the API key cannot follow a redirect to another host. API-key account billing is shared by this proxy; this is not a deployed per-wallet staking/quota service. Keep the local listener on loopback; deployment beyond loopback requires an authenticated TLS reverse proxy and a real operator-reviewed infrastructure configuration. No Docker/dstack deployment or fabricated measurements are supplied.

## Routes

All successful mock responses carry `mock:true`; all mock replies (including errors) have `X-Hush-Mode: MOCK`. Errors use `{"error":{"message":"safe message"},"mock":true|false}`. Payloads, bearer tokens, account identifiers, upstream errors and environment values are not logged. There are no CORS privileges or browser-cookie credentials.

- `GET /health`: `status`, `mode` (`MOCK`/`FORWARDING`), `mock`, `e2ee_supported`.
- `GET /attestation`: mock has `mode:"MOCK"`, `mock:true`, `validQuote:false`, `quote:null`, `detail`, `signing_algo:"ed25519"`, `signing_public_key` (hex Ed25519 public key if sodium exists), `e2ee_supported`. The signing key enables encryption **only**, never a verified-private badge. Forwarding returns actual upstream evidence unchanged; clients must verify it independently. Injected attestation failure returns 403.
- `GET /v1/model/list`: OpenAI-style `data` rows with `id`, `object`, `owned_by`. Mock rows also have `mock:true`, `verifiable:true` solely to exercise allowlist handling; `--fail model` sets `verifiable:false` and rejects inference with 403. Real rows are filtered to the operator's allowlist without upgrading upstream verification claims.
- `POST /auth/challenge`: JSON `{"account_id":"alice.near"}` → `challenge_id`, `account_id`, `nonce` (base64 32 random bytes), `message`, `recipient`, `expires_at` (Unix seconds), `mock`. Challenge TTL is 120 seconds.
- `POST /auth/verify`: JSON `{"challenge_id":"...","account_id":"alice.near","signature":"MOCK"}` in mock. Only literal `MOCK` is accepted; missing/unsigned authentication is rejected even locally. Returns `token`, `token_type:"Bearer"`, `expires_in:3600`, `mock`. Every attempted verification consumes the nonce, including failed attempts. Replays return 401. Session storage retains token hashes, not bearer plaintext; server restart invalidates sessions.
- `GET /quota`: `Authorization: Bearer <session>` required. Mock returns `stakedYocto` (decimal string), `creditsUsd:5.0`, `usedUsd:0.0`, `mock:true`. Credits are fixed fixtures, not yield. `--fail quota` returns 402 for quota, stake and inference. Real mode returns 501 because a shared provider API-key quota cannot truthfully represent a wallet's stake.
- `POST /stake`: bearer required, JSON `{"amount":"1000000000000000000000000"}` (positive yocto integer, maximum 30 digits). Mock adds to the mock balance and returns quota fields plus `simulated:true`, with **no transaction and no additional credits/yield**. Real mode returns 501, never signs, spends, or fakes a transaction. Live staking requires a known contract, network, transaction schema and browser-wallet approval; these are not available in this local service.
- `POST /v1/audio/transcriptions`: multipart `model`, `file`, optional OpenAI form fields. Only `openai/whisper-large-v3`. Mock validates PCM WAV, 1–2 channels, 8–192kHz, 8/16/24/32-bit samples, nonempty, complete, at most 10 minutes, non-silent audio. It returns `text`, `duration`, `audio_sha256`, `mock:true`. The default semantic fixture is “We discussed the launch plan. Alice will finish the design by Friday.”, explicitly prefixed MOCK, followed by the actual audio digest and metadata. The words are test fixture data, **not** recognized from the audio; different audio changes the metadata/digest. Optional test-only `X-Mock-Transcript` supplies another known fixture phrase **after audio validation**; it does not let invalid audio succeed. The app harness does not need that header. Silence returns 422; corrupt/unsupported WAV returns 400. Real mode forwards accepted multipart data for provider-supported audio formats without forcing WAV.
- `POST /v1/chat/completions`: OpenAI JSON `model`, nonempty `messages:[{role,content}]`, optional `stream:false`. Only `z-ai/glm-5.3-flash` and `Qwen/Qwen3.8-27B`. Mock text explicitly identifies itself and depends on request context; it is not claimed to be model reasoning. Response is OpenAI-compatible `choices[0].message.content`. Streaming is explicitly unsupported, not silently buffered.
- `POST /v1/embeddings`: JSON `model:"Qwen/Qwen3-Embedding-0.6B"`, `input` string or 1–128 strings. Mock returns deterministic normalized 32-dimensional hashed-token fixtures in OpenAI `data` format, labelled mock. They are not real model vectors. Real mode forwards actual embeddings.

Mock inference does not require login, enabling isolated local onboarding. Real inference always requires the authenticated session. `--models` can restrict the four canonical identifiers; unknown or inappropriate model/route combinations return 403.

## Real wallet authentication (NEP-413)

Real `auth/verify` adds `public_key:"ed25519:<base58>"` and a base64 64-byte signature. The payload is the Borsh encoding of tag `2^31+413`, challenge `message` string, challenge nonce32, challenge `recipient` string, and `callbackUrl=None`. The wallet signs SHA-256(payload). No client-provided recipient, nonce, message, or callback can override the server challenge. The server verifies Ed25519, then queries the final NEAR `view_access_key` via `--near-rpc` (default `https://rpc.mainnet.near.org`). The signing key must be an actual `FullAccess` key for the named account. A valid signature by an unrelated key, limited function-call key, invalid signature, unsigned request or RPC failure cannot create a session. The service stores no wallet secret. Real wallet signing/browser integration is an external prerequisite, not simulated server-side.

Signature validation and optional mock E2EE require existing libsodium. The service discovers its system library (`ctypes.util.find_library`, standard Homebrew paths, or `libsodium.so.23`); it installs nothing. Without it, mock plaintext endpoints remain available, `e2ee_supported:false`, encrypted requests return 503, and real forwarding startup fails closed. The native app should likewise refuse to misrepresent plaintext as verified E2EE.

## NEAR v2 E2EE chat

Headers: `X-Signing-Algo: ed25519`, `X-Client-Pub-Key: <client Ed25519 hex32>`, `X-Model-Pub-Key: <attestation Ed25519 hex32>`, `X-Encryption-Version: 2`, `x-no-aliasing: true`.

Each message content becomes hex of `ephemeral X25519 public32 || nonce24 || XChaCha20-Poly1305 ciphertext-and-tag`. Convert recipient Ed25519 keys to Curve25519. Generate an ephemeral Curve25519 key and compute the X25519 shared secret. HKDF-SHA256: extract `HMAC(zero32, shared)`, expand `HMAC(prk, "ed25519_encryption" || 0x01)` (32 bytes). AEAD uses no additional authenticated data. The mock decrypts using its temporary server Ed25519 secret converted to Curve25519 and encrypts the response in the same format toward `X-Client-Pub-Key`. Keys rotate on restart. Invalid keys, wrong model key and authentication-tag corruption reject rather than falling back to plaintext. Real forwarding passes this protocol through unchanged and never decrypts content.

## Limits and integration E2E coverage

16MiB request/response limit; no chunked input; one Content-Length; JSON duplicate-key rejection; 32 simultaneous requests; socket timeout 15 seconds; 1024 active challenges/sessions/mock accounts; 128 chat messages and embedding inputs. Connection closes after each reply. Only exact documented routes are allowed; URL query parameters and arbitrary forwarding destinations are rejected.

Run verification **after sibling integration**, through the actual macOS app binary and this running service:

1. Start mock, inspect explicit MOCK attestation, model allowlist, and use actual non-silent PCM WAV import/transcribe. Different audio must have different `audio_sha256`; truncated WAV, empty input and silence must reject.
2. Summarize/ask over encrypted chat; observe decryptable, mock-labelled request-dependent results. Tamper ciphertext/key and verify rejection, not plaintext fallback. Run embeddings and search through app actions.
3. Login, query quota, stake a positive amount, verify balance changes but credits/yield do not. Missing bearer, zero/negative amount, expired/replayed challenge and missing `MOCK` signature must reject.
4. Launch separate `--fail attestation`, `--fail model`, `--fail quota` processes; exercise app rejection flows and ensure no verified-private badge or fake success. Toggle `/mock/control` transcription failure while importing audio, then clear it and retry queued audio; verify the app preserves the chunk and reports the transient error.
5. Start with `--mock --host 0.0.0.0` and observe startup rejection. Start forwarding without API-key environment or without libsodium and observe fail-closed startup. With prerequisites, unsigned auth must reject before any inference.
6. Inspect startup/service output for the absence of audio, note text, bearer secrets and wallet identity. Service only emits startup mode/port/crypto-availability JSON.

There are no unit tests. The integration owner owns binary-driven E2E execution and the ten-failed-attempt escalation rule per issue. Live provider inference, live NEP-413 wallet/RPC verification, deployed per-wallet quota, TEE measurements and on-chain economics require live evidence and are not locally attested by this fixture.
