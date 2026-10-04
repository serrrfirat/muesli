# Inference, trust and wallet-client decisions

Issues: #5 (inference), #8 (attestation), #11 (ask/search), #12 (wallet client), #15 (private routing). This slice owns `Inference.swift` and `Trust.swift`; the integration owner owns model/UI/dependency changes and binary-driven E2E evidence. No unit tests are introduced.

## Scope and preflight

This is feature implementation with a fail-closed security boundary, explicitly authorized in the assignment. The shared contracts in `DECISIONS.md` and `Models.swift` were read before implementation. The repository had no inference/trust implementation to extend. Affected flows are audio transcription, meeting summaries, embeddings, cited meeting questions, endpoint trust, and mock wallet quota. The invariants are: never label mock as verified, never send private content to a production endpoint before acceptance, no plaintext fallback for encrypted chat, no wallet signing keys on a server, no on-chain spending, and no content/credential logging. Project verification is intentionally deferred to the parent until disjoint-source integration is complete.

## Real wire protocols

- Audio uses multipart `POST /v1/audio/transcriptions`, with `file` bytes and canonical model `openai/whisper-large-v3`. The MIME-to-extension mapping is explicit and uploads over 25 MB are rejected. Returned segments retain chunk identity, channel and timestamps. WAV fixtures are consumed through the same action as recording output.
- Embeddings use `POST /v1/embeddings` with `Qwen/Qwen3-Embedding-0.6B`. Batch indices must form a complete unique permutation of the inputs, all dimensions must agree, and all values must be finite representable floats. The client never substitutes locally invented vectors.
- Chat allowlist is deliberately small: `z-ai/glm-5.3-flash`, `Qwen/Qwen3.8-27B`. Remote discovery cannot expand this policy. `x-no-aliasing: true` is sent so a canonical ID is not silently redirected to a different model. Catalog membership is not proof of hardware verification.
- Chat uses the published NEAR **v2** protocol, not an application-specific encryption envelope: Ed25519 identity keys are converted to X25519; per-field ephemeral X25519 ECDH feeds HKDF-SHA256 with info `ed25519_encryption`; XChaCha20-Poly1305 uses no additional authenticated data. Each hex field encodes `ephemeral_public_key(32) || nonce(24) || ciphertext_and_tag`. Request headers are `X-Signing-Algo: ed25519`, `X-Client-Pub-Key`, `X-Model-Pub-Key`, `X-Encryption-Version: 2`, and `x-no-aliasing: true`. Each request generates a fresh client identity and each encrypted field gets a fresh ephemeral key/nonce. Response content and any reasoning fields are authenticated/decrypted; malformed ciphertext fails, with no plaintext fallback.
- libsodium provides conversion, X25519 and XChaCha operations (`CSodium` system-library dependency owned by integration). Apple CryptoKit provides HKDF; Apple Security provides secure randomness and RSA JWT verification. Secret byte arrays are wiped with `sodium_memzero` when no longer needed. This is not a claim that all transient Swift/CryptoKit/string copies can be guaranteed erased from a running process.
- Ask passes only supplied meetings, with speaker labels, scratch notes and summaries. It requires `[meeting:UUID]` citations and rejects missing or unknown references. The UUID check establishes reference integrity, **not** semantic correctness of an LLM statement. Source text is explicitly identified to the model as untrusted data. General, Standup and Interview summary templates are supported.

## Trust boundary and genuine prerequisites

The initializer does not grant trust. Production requests allow only `https://cloud-api.near.ai` (default HTTPS port), with no userinfo/query/fragment/custom base path. Explicit test mode permits only HTTP loopback origins; all relevant returned objects must carry `mock: true`. The mock attestation additionally requires `mode: MOCK`, and its Ed25519 key is used solely to exercise the same encryption protocol. Trust state stays `mock` and `verifiedAt` stays nil. A downloaded mock key is **not** an attested key.

Production `verify()` inspects the public/non-billable `/v1/attestation/ita-token` route using a fresh client nonce and PS384 token request. Intel JWKS is fetched from the **fixed** `https://portal.trustauthority.intel.com/certs` trust anchor, never from a token's `jku` or the response's `jwks_url`. The verifier allows only PS384 or RS256 RSA keys, requires an unambiguous matching `kid`, verifies the signature with Security.framework, checks fixed issuer and required iat/exp/nbf with a maximum five-minute token age, and checks signed non-debug TDX report-data nonce binding. It accepts documented flat v1 or nested v2 TDX containers; missing/unsupported claim formats fail closed. No JWT parse, HTTP echo, header algorithm, or valid signature alone can mark the endpoint verified.

After authenticated evidence inspection, production **still fails closed**. The repo contains no approved workload measurement/configuration list, advisory/TCB acceptance policy, trusted source/build identity or provenance policy; no validated NVIDIA GPU evidence is integrated; and URLSession does not prove that a peer SPKI and an attestation/inference request use the very same TLS connection. There is no raw Intel DCAP quote verifier linked in this native build. Pretending to check `intel_quote` with a JSON flag or accepting whatever measurements arrive would violate the documented policy. These are prerequisites for #8/#15 production acceptance, not mockable production success. Production Whisper and embedding content are also blocked; their route guides use TLS multipart/JSON, not the chat E2EE field format.

The authoritative policy also warns that model instances share a signing key, including across differently measured configurations. Pinning one downloaded key therefore does not prove a later request ran on the accepted measured instance. Any production completion implementation must verify every returned model candidate and establish an appropriate routing/measurement policy rather than arbitrarily accepting the first candidate.

## Wallet client

Mock login performs `/auth/challenge` with `account_id`, validates a 32-byte challenge nonce, and calls `/auth/verify` with the explicit test-only `signature: MOCK`. Returned bearer token and expiry exist only in memory. `/quota` and `/stake` require that token; `/stake` accepts a positive canonical **yoctoNEAR integer**, not a decimal amount. Responses must identify as mocked. Production login rejects the account-ID-only contract with a clear NEP-413/browser-signing requirement.

A production `stake(amount) -> Quota` result cannot honestly describe an unsigned wallet transaction. Real support needs an approved network/contract/ABI, an unsigned transaction plan, parent UI review/browser signing, submission controlled by the user, and authenticated quota refresh after confirmation. The current official House of Stake configuration route alone supplies neither a stable transaction ABI nor an approved contract policy in this repo. The client does not invent `deposit_and_stake`, invoke a server-held key, move funds, or return fake quota. Production quota likewise reports its live-auth/current-farm-API prerequisite rather than sending mock `/quota` semantics to the real gateway. These production wallet limitations remain open under #12; parent UI must show the signing prerequisite rather than claim login/stake success.

## Errors and retries

The ephemeral HTTP session disables caches, cookies and stored credentials. Redirects are rejected rather than forwarding credentials/content. Response bodies are capped at 8 MB after download. Service response bodies are never incorporated into UI errors or logs (they could echo private content). Retries are bounded to three attempts: explicit 429 rejection on any route, or GET transport errors/502/503/504; `Retry-After` seconds are capped at five. Inference/wallet POST timeouts and 5xx responses are **not** blindly retried, since they can duplicate billable work or consume a signing challenge. Cancellation propagates. No background retries persist private data.

## Binary E2E scenarios for integration

Run these only through the actual app binary/coordinator and explicit localhost mock. No scenarios in this section are claimed executed by this slice.

1. Import a valid WAV, then verify returned transcript preserves channel/timestamps, summarize with every supported template, embed inputs and observe valid vector-index ordering through saved meeting/search flow.
2. Ask across saved meetings; verify answer contains known meeting UUID citations. Mock missing/unknown citations must cause an explicit failure, not accepted answers.
3. Inspect proxy request audit/traffic without logging plaintext content: chat messages on the wire must be hex ciphertext, and the Python mock must successfully authenticate/decrypt Swift ciphertext and encrypt a response that Swift authenticates. No prompt/summary/question/scratch-note text may appear on the chat wire. Tampered/unencrypted ciphertext must fail.
4. Disallowed chat models fail before inference requests. Production HTTP, non-loopback test endpoints, endpoint credentials/redirects and unmarked mock responses are rejected. Mock trust must never display Verified private.
5. A deterministic mock 429 followed by success exercises bounded retry. 401/403 and exhausted 429 must surface failure. POST 5xx/timeouts must not silently retry accepted work.
6. Before mock login, quota/stake fail. Login challenge/verify then quota, positive yocto stake and refreshed quota succeed. Zero/negative/decimal stake and expired sessions fail. Mock output states no signing/on-chain transaction happened.
7. Production mode must fail closed without sending audio/prompts/text to inference endpoints, even if an HTTP attestation object says valid or the ITA JWT signature is authentic. Real authenticated evidence, approved measured policy and same-connection binding require a separate live verification run.

## Primary sources consulted

- [NEAR v2 encrypted chat guide](https://docs.near.ai/cloud/guides/e2ee-chat-completions.md)
- [Canonical specialized routes/models](https://docs.near.ai/cloud/guides/specialized-endpoints.md)
- [NEAR model attestation and key scope](https://docs.near.ai/cloud/verification/cloud-api/model-attestations.md)
- [Gateway quote verification](https://docs.near.ai/cloud/verification/cloud-api/gateway-attestation.md)
- [Nonce, signer, configuration, event-log and GPU checks](https://docs.near.ai/cloud/verification/reference/quote-nonce-signer.md)
- [Required measured acceptance policy](https://docs.near.ai/cloud/verification/reference/verification-policy.md)
- [Same-connection TLS/SPKI binding](https://docs.near.ai/cloud/verification/cloud-api/tls.md)
- [ITA route schema](https://docs.near.ai/api-reference/attestation/get-intel-trust-authority-attestation-token.md)
- [Intel token algorithms and claims](https://docs.trustauthority.intel.com/main/articles/articles/ita/concept-attestation-tokens.html)
- [Intel authoritative OpenID/JWKS configuration](https://portal.trustauthority.intel.com/.well-known/openid-configuration)
- [Intel EAT profile and v1/v2 TDX claims](https://portal.trustauthority.intel.com/eat_profile.html)
- [Current staking overview](https://docs.near.ai/cloud/staking-for-inference/overview.md)
- [House of Stake farm configuration API](https://docs.near.ai/api-reference/staking-farm/get-staking-farm-configuration.md)
