#!/usr/bin/env python3
"""Explicit local mock or authenticated, bounded NEAR inference forwarding proxy."""
import argparse
import base64
import ctypes
import ctypes.util
import email.parser
import email.policy
import hashlib
import hmac
import io
import ipaddress
import json
import math
import os
import re
import secrets
import socket
import struct
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ("z-ai/glm-5.3-flash", "Qwen/Qwen3.8-27B", "openai/whisper-large-v3", "Qwen/Qwen3-Embedding-0.6B")
FAILURES = ("attestation", "model", "quota", "transcription", "chat", "embeddings")
LIMIT = 16 * 1024 * 1024
ACCOUNT = re.compile(r"^(?=.{2,64}$)[a-z0-9]+(?:[._-][a-z0-9]+)*$")
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


class ProtocolError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def require(condition, message, status=400):
    if not condition:
        raise ProtocolError(status, message)


def decode64(value, size=None):
    require(isinstance(value, str), "Expected base64 string")
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ProtocolError(400, "Invalid base64")
    require(size is None or len(result) == size, "Invalid decoded length")
    return result


def unbase58(value):
    require(isinstance(value, str) and 1 <= len(value) <= 100, "Invalid base58")
    number = 0
    for char in value:
        require(char in B58, "Invalid base58")
        number = number * 58 + B58.index(char)
    return b"\0" * (len(value) - len(value.lstrip("1"))) + number.to_bytes((number.bit_length() + 7) // 8, "big")


class Sodium:
    """Runtime-discovered libsodium; no pip or implicit package installation."""
    def __init__(self):
        candidates = [ctypes.util.find_library("sodium"), "/opt/homebrew/lib/libsodium.dylib", "/usr/local/lib/libsodium.dylib", "libsodium.so.23"]
        self.lib = None
        for candidate in candidates:
            if not candidate:
                continue
            try:
                self.lib = ctypes.CDLL(candidate)
                break
            except OSError:
                pass
        if self.lib is None or self.lib.sodium_init() < 0:
            raise RuntimeError("libsodium is unavailable")
        self.public, self.secret = ctypes.create_string_buffer(32), ctypes.create_string_buffer(64)
        require(self.lib.crypto_sign_keypair(self.public, self.secret) == 0, "Crypto initialization failed", 503)
        self.xsecret = ctypes.create_string_buffer(32)
        require(self.lib.crypto_sign_ed25519_sk_to_curve25519(self.xsecret, self.secret) == 0, "Crypto initialization failed", 503)
        # Set 64-bit length arguments explicitly: ctypes otherwise truncates Python ints to C int.
        self.lib.crypto_aead_xchacha20poly1305_ietf_encrypt.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        self.lib.crypto_aead_xchacha20poly1305_ietf_decrypt.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_void_p]
        self.lib.crypto_sign_verify_detached.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p]

    @staticmethod
    def derive(shared):
        prk = hmac.new(b"\0" * 32, shared, hashlib.sha256).digest()
        return hmac.new(prk, b"ed25519_encryption\x01", hashlib.sha256).digest()

    def decrypt(self, encoded):
        require(isinstance(encoded, str) and len(encoded) <= 2 * LIMIT, "Invalid encrypted content")
        try:
            payload = bytes.fromhex(encoded)
        except ValueError:
            raise ProtocolError(400, "Invalid encrypted content")
        require(len(payload) >= 72, "Truncated encrypted content")
        shared = ctypes.create_string_buffer(32)
        require(self.lib.crypto_scalarmult_curve25519(shared, self.xsecret, payload[:32]) == 0, "Invalid encryption key")
        ciphertext = payload[56:]
        output, length = ctypes.create_string_buffer(len(ciphertext)), ctypes.c_ulonglong()
        require(self.lib.crypto_aead_xchacha20poly1305_ietf_decrypt(output, ctypes.byref(length), None, ciphertext, len(ciphertext), None, 0, payload[32:56], self.derive(shared.raw)) == 0, "Encrypted content authentication failed")
        try:
            return output.raw[:length.value].decode("utf-8")
        except UnicodeDecodeError:
            raise ProtocolError(400, "Encrypted content is not UTF-8")

    def encrypt(self, text, ed_public):
        require(isinstance(ed_public, str) and re.fullmatch(r"[0-9a-fA-F]{64}", ed_public) is not None, "Invalid client public key")
        try:
            ed = bytes.fromhex(ed_public)
        except ValueError:
            raise ProtocolError(400, "Invalid client public key")
        require(len(ed) == 32, "Invalid client public key")
        xpublic = ctypes.create_string_buffer(32)
        require(self.lib.crypto_sign_ed25519_pk_to_curve25519(xpublic, ed) == 0, "Invalid client public key")
        ephemeral_public, ephemeral_secret = ctypes.create_string_buffer(32), ctypes.create_string_buffer(32)
        require(self.lib.crypto_box_keypair(ephemeral_public, ephemeral_secret) == 0, "Crypto failed", 503)
        shared = ctypes.create_string_buffer(32)
        require(self.lib.crypto_scalarmult_curve25519(shared, ephemeral_secret, xpublic) == 0, "Invalid client public key")
        nonce, message = secrets.token_bytes(24), text.encode()
        output, length = ctypes.create_string_buffer(len(message) + 16), ctypes.c_ulonglong()
        require(self.lib.crypto_aead_xchacha20poly1305_ietf_encrypt(output, ctypes.byref(length), message, len(message), None, 0, None, nonce, self.derive(shared.raw)) == 0, "Crypto failed", 503)
        return (ephemeral_public.raw + nonce + output.raw[:length.value]).hex()

    def verify(self, signature, digest, public):
        return self.lib.crypto_sign_verify_detached(signature, digest, len(digest), public) == 0


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


class State:
    def __init__(self, args):
        self.args, self.lock = args, threading.Lock()
        self.challenges, self.sessions, self.quotas = {}, {}, {}
        try:
            self.sodium = Sodium()
        except (RuntimeError, AttributeError):
            self.sodium = None
        self.opener = urllib.request.build_opener(NoRedirect())
        self.api_key = os.environ.get("HUSH_UPSTREAM_API_KEY", "")
        if not args.mock:
            require(bool(self.api_key) and "\n" not in self.api_key and "\r" not in self.api_key, "Set HUSH_UPSTREAM_API_KEY", 503)
            require(self.sodium is not None, "Real authentication requires installed libsodium", 503)

    def prune(self):
        now = time.time()
        self.challenges = {key: item for key, item in self.challenges.items() if item["expires_at"] > now}
        self.sessions = {key: item for key, item in self.sessions.items() if item[1] > now}

    def challenge(self, body):
        account = body.get("account_id")
        require(isinstance(account, str) and ACCOUNT.fullmatch(account), "Invalid NEAR account ID")
        with self.lock:
            self.prune()
            require(len(self.challenges) < 1024, "Challenge capacity reached", 429)
            identifier = secrets.token_urlsafe(24)
            result = {"challenge_id": identifier, "account_id": account, "nonce": base64.b64encode(secrets.token_bytes(32)).decode(), "message": "Sign in to Hush", "recipient": self.args.recipient, "expires_at": int(time.time()) + 120, "mock": self.args.mock}
            self.challenges[identifier] = result
            return result.copy()

    def verify_identity(self, body):
        identifier = body.get("challenge_id")
        require(isinstance(identifier, str), "Missing challenge ID")
        with self.lock:
            self.prune()
            challenge = self.challenges.pop(identifier, None)
        require(challenge is not None, "Expired or consumed challenge", 401)
        require(body.get("account_id") == challenge["account_id"], "Challenge identity mismatch", 401)
        if self.args.mock:
            require(body.get("signature") == "MOCK", "Mock requires explicit MOCK signature", 401)
        else:
            public_key = body.get("public_key")
            require(isinstance(public_key, str) and public_key.startswith("ed25519:"), "Ed25519 public key required", 401)
            public = unbase58(public_key[8:])
            require(len(public) == 32, "Invalid public key", 401)
            signature = decode64(body.get("signature"), 64)
            def borsh_string(text):
                encoded = text.encode("utf-8")
                return struct.pack("<I", len(encoded)) + encoded
            # NEP-413 tag 2^31+413, string message, 32-byte nonce, string recipient,
            # Option<String> callbackUrl = None. The challenge fixes every signed field.
            payload = struct.pack("<I", (1 << 31) + 413) + borsh_string(challenge["message"]) + decode64(challenge["nonce"], 32) + borsh_string(challenge["recipient"]) + b"\0"
            require(self.sodium.verify(signature, hashlib.sha256(payload).digest(), public), "Invalid NEP-413 signature", 401)
            # A mathematically valid signature alone does not bind a key to an account.
            rpc = {"jsonrpc": "2.0", "id": "access-key", "method": "query", "params": {"request_type": "view_access_key", "finality": "final", "account_id": challenge["account_id"], "public_key": public_key}}
            _, response = self.fetch(self.args.near_rpc, json.dumps(rpc).encode(), {"Content-Type": "application/json"})
            try:
                access = json.loads(response).get("result", {})
            except (ValueError, AttributeError):
                raise ProtocolError(502, "Invalid NEAR RPC response")
            require(access.get("permission") == "FullAccess", "Key is not an account FullAccess key", 401)
        token = secrets.token_urlsafe(32)
        with self.lock:
            self.prune()
            require(len(self.sessions) < 1024, "Session capacity reached", 429)
            # Test credits are fixture data, never an economic yield estimate.
            if self.args.mock:
                require(challenge["account_id"] in self.quotas or len(self.quotas) < 1024, "Mock account capacity reached", 429)
                self.quotas.setdefault(challenge["account_id"], {"stakedYocto": "0", "creditsUsd": 5.0, "usedUsd": 0.0})
            self.sessions[hashlib.sha256(token.encode()).digest()] = (challenge["account_id"], time.time() + 3600)
        return {"token": token, "token_type": "Bearer", "expires_in": 3600, "mock": self.args.mock}

    def session(self, authorization):
        require(isinstance(authorization, str) and authorization.startswith("Bearer "), "Session required", 401)
        token = authorization[7:]
        require(1 <= len(token) <= 512, "Invalid session", 401)
        with self.lock:
            self.prune()
            session = self.sessions.get(hashlib.sha256(token.encode()).digest())
        require(session is not None, "Invalid or expired session", 401)
        return session[0]

    def fetch(self, url, body=None, headers=None, method=None):
        request = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
        try:
            with self.opener.open(request, timeout=30) as response:
                result = response.read(LIMIT + 1)
                require(len(result) <= LIMIT, "Upstream response exceeds size limit", 502)
                return response.status, result
        except urllib.error.HTTPError as error:
            # Never reflect provider bodies, which can contain sensitive request details.
            raise ProtocolError(error.code if 400 <= error.code <= 599 else 502, "Upstream rejected request")
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ProtocolError(502, "Upstream unavailable")

    def forward(self, path, body=None, content_type="application/json", extra_headers=None):
        headers = {"Authorization": "Bearer " + self.api_key, "Content-Type": content_type}
        headers.update(extra_headers or {})
        return self.fetch(self.args.upstream.rstrip("/") + path, body, headers)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, state):
        self.state, self.slots = state, threading.BoundedSemaphore(32)
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, request, address):
        # No payloads, credentials, exception representations, or request URLs in logs.
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "HushProxy"

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *args):
        pass

    def log_error(self, *args):
        pass

    @property
    def state(self):
        return self.server.state

    def reply(self, status, value):
        payload = json.dumps(value, separators=(",", ":"), allow_nan=False).encode()
        self.raw_reply(status, payload)

    def raw_reply(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        if self.state.args.mock:
            self.send_header("X-Hush-Mode", "MOCK")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def read_body(self):
        require(self.headers.get("Transfer-Encoding") is None, "Transfer encoding unsupported")
        lengths = self.headers.get_all("Content-Length", [])
        require(len(lengths) == 1 and lengths[0].isdigit(), "Content-Length required", 411)
        length = int(lengths[0])
        require(0 < length <= LIMIT, "Body size exceeds limit or is empty", 413)
        body = self.rfile.read(length)
        require(len(body) == length, "Truncated request body")
        return body

    def json_body(self, body):
        require(self.headers.get_content_type() == "application/json", "Expected application/json", 415)
        def unique(items):
            result = {}
            for key, value in items:
                require(key not in result, "Duplicate JSON field")
                result[key] = value
            return result
        try:
            result = json.loads(body, object_pairs_hook=unique, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (ValueError, UnicodeDecodeError, RecursionError):
            raise ProtocolError(400, "Invalid JSON")
        require(isinstance(result, dict), "Expected JSON object")
        return result

    def model(self, model, permitted):
        require(isinstance(model, str) and model in permitted and model in self.state.args.models, "Model not allowlisted", 403)
        require("model" not in self.state.args.fail, "Injected model rejection", 403)

    def inference_session(self):
        if not self.state.args.mock:
            self.state.session(self.headers.get("Authorization"))

    def do_GET(self):
        self.dispatch(False)

    def do_POST(self):
        self.dispatch(True)

    def dispatch(self, post):
        try:
            require("?" not in self.path and "#" not in self.path, "Query strings unsupported")
            if self.state.args.mock and self.state.args.forbid_credential:
                require(self.headers.get("Authorization") != "Bearer " + self.state.args.forbid_credential, "Mock credential isolation failed", 403)
            if post:
                self.post(self.read_body())
            else:
                self.get()
        except ProtocolError as error:
            self.reply(error.status, {"error": {"message": error.message}, "mock": self.state.args.mock})
        except (socket.timeout, TimeoutError):
            self.reply(408, {"error": {"message": "Request timeout"}, "mock": self.state.args.mock})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            self.reply(500, {"error": {"message": "Internal proxy error"}, "mock": self.state.args.mock})

    def get(self):
        path, state = self.path, self.state
        if path == "/health":
            self.reply(200, {"status": "ok", "mock": state.args.mock, "mode": "MOCK" if state.args.mock else "FORWARDING", "e2ee_supported": state.sodium is not None})
        elif path == "/attestation":
            require("attestation" not in state.args.fail, "Injected attestation rejection", 403)
            if state.args.mock:
                self.reply(200, {"mode": "MOCK", "mock": True, "validQuote": False, "quote": None, "detail": "MOCK fixture, NOT valid TEE evidence", "signing_public_key": state.sodium.public.raw.hex() if state.sodium else None, "signing_algo": "ed25519", "e2ee_supported": state.sodium is not None})
            else:
                self.raw_reply(*state.forward(path))
        elif path == "/v1/model/list":
            if state.args.mock:
                self.reply(200, {"object": "list", "mock": True, "data": [{"id": model, "object": "model", "owned_by": "MOCK", "verifiable": "model" not in state.args.fail, "mock": True} for model in state.args.models]})
            else:
                status, payload = state.forward(path)
                try:
                    result = json.loads(payload)
                    require(isinstance(result, dict) and isinstance(result.get("data"), list), "Invalid upstream model list", 502)
                    result["data"] = [item for item in result["data"] if isinstance(item, dict) and item.get("id") in state.args.models]
                except ValueError:
                    raise ProtocolError(502, "Invalid upstream model list")
                self.reply(status, result)
        elif path == "/quota":
            account = state.session(self.headers.get("Authorization"))
            require("quota" not in state.args.fail, "Injected quota exhausted", 402)
            if state.args.mock:
                with state.lock:
                    result = dict(state.quotas[account], mock=True)
                self.reply(200, result)
            else:
                # User quota cannot be inferred from the shared upstream API-key account.
                raise ProtocolError(501, "Per-wallet quota requires a deployed staking/quota backend")
        else:
            raise ProtocolError(404, "Unknown endpoint")

    def post(self, raw):
        path, state = self.path, self.state
        if path == "/mock/control":
            require(state.args.mock and ipaddress.ip_address(self.client_address[0]).is_loopback, "Unknown endpoint", 404)
            body = self.json_body(raw)
            failures = body.get("fail")
            require(set(body) == {"fail"} and isinstance(failures, list) and len(failures) <= len(FAILURES) and all(isinstance(item, str) and item in FAILURES for item in failures), "Expected fail array of known injections")
            with state.lock:
                state.args.fail = list(dict.fromkeys(failures))
            self.reply(200, {"mock": True, "fail": state.args.fail})
            return
        if path in ("/auth/challenge", "/auth/verify", "/stake"):
            body = self.json_body(raw)
            if path == "/auth/challenge":
                self.reply(200, state.challenge(body))
            elif path == "/auth/verify":
                self.reply(200, state.verify_identity(body))
            else:
                account = state.session(self.headers.get("Authorization"))
                require(state.args.mock, "Real staking requires wallet-signed contract transaction; proxy never signs or spends", 501)
                require("quota" not in state.args.fail, "Injected quota exhausted", 402)
                amount = body.get("amount")
                require(isinstance(amount, str) and re.fullmatch(r"[1-9][0-9]{0,29}", amount), "amount must be a positive yocto integer")
                with state.lock:
                    quota = state.quotas[account]
                    quota["stakedYocto"] = str(int(quota["stakedYocto"]) + int(amount))
                    result = dict(quota, mock=True, simulated=True, detail="MOCK balance only; no transaction, yield, or additional credits")
                self.reply(200, result)
            return
        require(path in ("/v1/audio/transcriptions", "/v1/chat/completions", "/v1/embeddings"), "Unknown endpoint", 404)
        self.inference_session()
        if state.args.mock and state.args.delay_ms:
            time.sleep(state.args.delay_ms / 1000)
        require("quota" not in state.args.fail, "Injected quota exhausted", 402)
        if path == "/v1/audio/transcriptions":
            require("transcription" not in state.args.fail, "Injected transcription failure", 503)
            self.transcribe(raw)
            return
        body = self.json_body(raw)
        if path == "/v1/embeddings":
            self.model(body.get("model"), ("Qwen/Qwen3-Embedding-0.6B",))
            require("embeddings" not in state.args.fail, "Injected embedding failure", 503)
            texts = body.get("input")
            if isinstance(texts, str):
                texts = [texts]
            require(isinstance(texts, list) and 1 <= len(texts) <= 128 and all(isinstance(text, str) and 0 < len(text) <= 65536 for text in texts), "Invalid embedding input")
            if not state.args.mock:
                self.raw_reply(*state.forward(path, raw))
                return
            vectors = []
            for index, text in enumerate(texts):
                vector = [0.0] * 32
                for word in re.findall(r"\w+", text.lower()):
                    hashed = hashlib.sha256(word.encode()).digest()
                    vector[hashed[0] % 32] += 1 if hashed[1] & 1 else -1
                norm = math.sqrt(sum(value * value for value in vector)) or 1
                vectors.append({"index": index, "object": "embedding", "embedding": [value / norm for value in vector]})
            self.reply(200, {"object": "list", "model": body["model"], "data": vectors, "mock": True, "usage": {"prompt_tokens": 0, "total_tokens": 0}})
        else:
            self.chat(body, raw)

    def transcribe(self, raw):
        content_type = self.headers.get("Content-Type", "")
        require(self.headers.get_content_type() == "multipart/form-data" and len(content_type) < 512, "Expected multipart/form-data", 415)
        message = email.parser.BytesParser(policy=email.policy.default).parsebytes(("Content-Type: " + content_type + "\r\nMIME-Version: 1.0\r\n\r\n").encode() + raw)
        require(message.is_multipart() and not message.defects, "Invalid multipart body")
        fields = {}
        for part in message.iter_parts():
            require(len(fields) < 16 and not part.is_multipart() and not part.defects, "Invalid multipart part")
            require(part.get_content_disposition() == "form-data", "Invalid multipart disposition")
            name = part.get_param("name", header="content-disposition")
            require(isinstance(name, str) and name not in fields, "Invalid or duplicate multipart field")
            fields[name] = part.get_payload(decode=True)
        require(isinstance(fields.get("model"), bytes) and isinstance(fields.get("file"), bytes), "model and file required")
        try:
            model = fields["model"].decode()
        except UnicodeDecodeError:
            raise ProtocolError(400, "Invalid model")
        self.model(model, ("openai/whisper-large-v3",))
        require(len(fields["file"]) > 0, "Empty audio")
        if not self.state.args.mock:
            self.raw_reply(*self.state.forward(self.path, raw, content_type))
            return
        try:
            with wave.open(io.BytesIO(fields["file"]), "rb") as audio:
                channels, width, rate, frames = audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()
                require(audio.getcomptype() == "NONE" and channels in (1, 2) and width in (1, 2, 3, 4) and 8000 <= rate <= 192000 and 0 < frames <= 600 * rate, "Unsupported mock WAV format")
                samples = audio.readframes(frames)
                require(len(samples) == frames * channels * width, "Truncated WAV samples")
        except (wave.Error, EOFError):
            raise ProtocolError(400, "Mock requires valid PCM WAV audio")
        nonzero = any(sample != 128 for sample in samples) if width == 1 else any(samples)
        require(nonzero, "Mock rejects silent audio", 422)
        fixture = self.headers.get("X-Mock-Transcript")
        require(fixture is None or 0 < len(fixture) <= 2000, "Invalid transcript fixture header")
        description = fixture if fixture is not None else "We discussed the launch plan. Alice will finish the design by Friday."
        text = "MOCK transcript: " + description + f" (audio fixture {hashlib.sha256(samples).hexdigest()[:12]}, validated {frames / rate:.3f}s, {rate}Hz, {channels} channel PCM)"
        self.reply(200, {"text": text, "mock": True, "duration": frames / rate, "audio_sha256": hashlib.sha256(samples).hexdigest()})

    def chat(self, body, raw):
        state = self.state
        self.model(body.get("model"), ("z-ai/glm-5.3-flash", "Qwen/Qwen3.8-27B"))
        require("chat" not in state.args.fail, "Injected chat failure", 503)
        require(body.get("stream", False) is False, "Streaming unsupported by local proxy")
        messages = body.get("messages")
        require(isinstance(messages, list) and 1 <= len(messages) <= 128, "Invalid chat messages")
        for message in messages:
            require(isinstance(message, dict) and message.get("role") in ("system", "user", "assistant") and isinstance(message.get("content"), str) and 0 < len(message["content"]) <= 1048576, "Invalid chat message")
        encryption = self.headers.get("X-Encryption-Version")
        extra = {}
        if encryption is not None:
            require(encryption == "2" and self.headers.get("X-Signing-Algo") == "ed25519", "Unsupported encryption protocol")
            for header in ("X-Signing-Algo", "X-Client-Pub-Key", "X-Model-Pub-Key", "X-Encryption-Version", "x-no-aliasing"):
                value = self.headers.get(header)
                require(isinstance(value, str) and len(value) <= 128, "Missing encryption header")
                extra[header] = value
        if not state.args.mock:
            self.raw_reply(*state.forward(self.path, raw, extra_headers=extra))
            return
        if encryption:
            require(state.sodium is not None, "E2EE requires installed libsodium", 503)
            require(self.headers.get("X-Model-Pub-Key") == state.sodium.public.raw.hex(), "Unknown model encryption key", 403)
            require(re.fullmatch(r"[0-9a-fA-F]{64}", self.headers.get("X-Client-Pub-Key", "")) is not None, "Invalid client public key")
            contents = [state.sodium.decrypt(message["content"]) for message in messages]
        else:
            contents = [message["content"] for message in messages]
        require(any(message["role"] == "user" for message in messages), "User message required")
        # Deterministic external-service fixture; not a claim of real model reasoning.
        context = "\n".join(content for message, content in zip(messages, contents) if message["role"] != "system")
        text = "MOCK response — external inference simulated.\n" + context[:4000]
        if encryption:
            text = state.sodium.encrypt(text, self.headers.get("X-Client-Pub-Key"))
        self.reply(200, {"id": "mock-" + secrets.token_hex(8), "object": "chat.completion", "model": body["model"], "mock": True, "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})


def https_url(value):
    parsed = urllib.parse.urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment, "An HTTPS URL without embedded credentials/query/fragment is required")
    return value.rstrip("/")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--mock", action="store_true")
    mode.add_argument("--upstream", help="HTTPS NEAR inference base URL")
    parser.add_argument("--near-rpc", default="https://rpc.mainnet.near.org")
    parser.add_argument("--recipient", default="hush")
    parser.add_argument("--models", nargs="+", choices=MODELS, default=list(MODELS))
    parser.add_argument("--fail", action="append", choices=FAILURES, default=[])
    parser.add_argument("--delay-ms", type=int, default=0, help="Mock-only bounded inference latency for binary E2E races")
    parser.add_argument("--forbid-credential", default="", help="Mock-only synthetic sentinel forbidden in Authorization")
    args = parser.parse_args()
    try:
        require(0 <= args.port <= 65535, "Invalid port")
        require(0 <= args.delay_ms <= 1000 and (args.mock or args.delay_ms == 0), "Latency injection requires mock and 0–1000 ms")
        require(args.mock or not args.forbid_credential, "Credential sentinel requires mock")
        if args.mock:
            # Resolve every address to prohibit aliases with mixed/non-loopback answers.
            addresses = socket.getaddrinfo(args.host, args.port, type=socket.SOCK_STREAM)
            require(addresses and all(ipaddress.ip_address(item[4][0]).is_loopback for item in addresses), "MOCK must bind only loopback")
            require(1 <= len(args.recipient) <= 128, "Invalid recipient")
        else:
            args.upstream = https_url(args.upstream)
            args.near_rpc = https_url(args.near_rpc)
            require(not args.fail, "Failure injection requires --mock")
            require(1 <= len(args.recipient) <= 128, "Invalid recipient")
        state = State(args)
        server = Server((args.host, args.port), state)
    except (ProtocolError, OSError, ValueError) as error:
        # Configuration errors only; never output environment values or credentials.
        parser.exit(2, "Proxy configuration rejected: " + (error.message if isinstance(error, ProtocolError) else "invalid bind/configuration") + "\n")
    print(json.dumps({"service": "HushProxy", "mode": "MOCK" if args.mock else "FORWARDING", "port": server.server_port, "e2ee_supported": state.sodium is not None}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
