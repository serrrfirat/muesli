# Proxy, wallet and staking boundary decisions

Issues #10 and #13; 2026-10-03. Ownership: `proxy/` and this decision record. Relevant contracts: `docs/DECISIONS.md`, `Models.swift`, and the inference agent's NEAR v2 encryption wire format. This is an approved feature implementation, not a new wallet custody or deployment architecture.

## Explicit mock versus real forwarding

- `--mock` and `--upstream` are mutually exclusive and one is required. Mock mode is loopback-only, marks every successful body and every response header, and never emits a valid attestation quote. Mock model `verifiable:true` is labelled `mock:true` and exercises allowlisting only; it must not grant production trust.
- The local app can use mock inference before login. Mock quota/stake require an explicitly mock-signed challenge and session so wallet onboarding and negative authorization are exercised. Production inference always requires a real authenticated wallet session; trust/model metadata is available before login.
- Upstream API-key authentication comes only from `HUSH_UPSTREAM_API_KEY`. The service does not accept that provider secret as a client login credential. It is never in command arguments, logs, returned errors, or redirect requests. Payload/access/error logging is disabled; only safe startup metadata is printed.
- Forwarding is restricted to exact documented routes, canonical route-specific model IDs, bounded bodies/responses and HTTPS operator-configured destinations. A redirect cannot change the configured destination. Neither mock nor live mode is an arbitrary open proxy.

## Wallet proof

- Challenge nonces are random 32 bytes, expire after 120 seconds, and are consumed on the first verification attempt whether valid or invalid. Challenges bind account ID, fixed server message and fixed recipient. Sessions expire after one hour and only token hashes are stored.
- Mock verification requires literal `signature:"MOCK"`. Real verification never accepts this, missing signatures, unsigned identities, or a valid signature by an unrelated public key.
- Real NEP-413 uses the actual Borsh tagged payload, SHA-256 and Ed25519 verification via installed libsodium. Final NEAR RPC `view_access_key` must also bind the key to the claimed account. Mathematical signature verification without account membership would enable impersonation and is insufficient.
- Only `FullAccess` account keys are accepted. This intentionally rejects function-call-only keys: they do not prove unrestricted wallet account control for this login boundary. `callbackUrl=None` is fixed in the challenge; callback-based wallet flows require a separately specified browser integration, not silently different signed fields.
- Real verification requires installed libsodium and reachable HTTPS NEAR RPC. The service fails closed rather than installing packages, disabling TLS verification or supplying fake proof. Browser wallet signing remains outside the server; no wallet private key is ever stored here.

## Staking and economics

- Mock initial credits (`$5`) are fixture data. Mock stake changes a labelled in-memory yocto balance only. It sends no transaction and increases neither credits nor yield.
- No contract ID, supported network, staking transaction schema or deployed per-wallet quota backend was supplied. Real stake/quota therefore return explicit 501 prerequisites rather than fabricate transactions, guess a contract, use the shared API-key account quota as a user's stake, or imply yield. The app's live wallet transaction preparation needs those actual deployment details; no on-chain writes occur in this implementation.
- No deployment configuration is provided because there is no real TEE image, measurement, attestation policy or operator deployment evidence. Local mock encryption is not TEE evidence.

## Protocol fixtures and fault injection

- Mock transcription parses and validates actual non-silent PCM WAV before returning anything: complete samples, valid channel/rate/width, bounded duration. The default semantic words are an explicitly MOCK launch/Alice/Friday fixture requested for binary E2E; audio digest and metadata vary with request audio. The words are not claimed to be speech recognition of the tone. Invalid, silent or empty audio never succeeds because a fixture phrase exists.
- Mock chat returns a visible mock label with request-derived context, preserving transcript, scratch notes and meeting references for application assertions. Hashed-token embeddings are labelled test vectors, not production model embeddings.
- NEAR v2 E2EE matches the native client: Ed25519-to-Curve25519 conversion, ephemeral X25519, HKDF-SHA256 with `ed25519_encryption`, and XChaCha20-Poly1305. The mock decrypts and encrypts actual bytes through system libsodium. Real mode forwards the encrypted protocol without decrypting. Missing crypto, tampered ciphertext and unknown model keys reject; there is no plaintext fallback for an encrypted request.
- `--fail` flags cover trust, model, quota and inference errors. `/mock/control` exists only in loopback mock mode and atomically replaces injections, enabling transient transcription failure/retry in one binary E2E session. It has no live backend and cannot affect forwarding mode.

## Verification handoff

Per shared-workspace instructions, no mid-flight build, formatter, lint, unit test or runtime check was executed by this slice. The integration owner runs the actual app binary after all agents land. `proxy/README.md` documents start commands, exact schemas, negative protocol scenarios, encrypted roundtrip, quota/stake boundaries and transient queued-audio recovery. Production NEP-413/RPC, live provider inference, TEE evidence and staking economics remain unverified without the actual external prerequisites; local fixture success is not claimed as live proof.
