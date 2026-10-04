import Foundation
import CryptoKit
import Security
import CSodium

enum InferenceError: LocalizedError {
    case rejectedEndpoint, disallowedModel, unverified(String), malformedResponse, cryptography
    case http(Int), walletRequired(String), invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .rejectedEndpoint: return "Endpoint rejected: production requires https://cloud-api.near.ai; test mode requires an explicit loopback HTTP endpoint."
        case .disallowedModel: return "Model is not in the approved private-model allowlist."
        case .unverified(let detail): return "Private inference blocked: \(detail)"
        case .malformedResponse: return "The service returned an invalid or incomplete response."
        case .cryptography: return "Encrypted inference authentication failed. No plaintext fallback is permitted."
        case .http(let status): return "Service request failed (HTTP \(status))."
        case .walletRequired(let detail): return detail
        case .invalidInput(let detail): return detail
        }
    }
}

struct EndpointPolicy {
    static func validate(_ url: URL, testMode: Bool) throws {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw InferenceError.rejectedEndpoint }
        if testMode {
            guard url.scheme == "http", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "") else {
                throw InferenceError.rejectedEndpoint
            }
        } else {
            guard url.scheme == "https", url.host == "cloud-api.near.ai", url.port == nil || url.port == 443 else {
                throw InferenceError.rejectedEndpoint
            }
        }
    }
}

extension Data {
    var inferenceHex: String { map { String(format: "%02x", $0) }.joined() }
    init(inferenceHex: String) throws {
        let bytes = Array(inferenceHex.utf8)
        guard bytes.count.isMultiple(of: 2), bytes.count <= 16_000_000 else { throw InferenceError.malformedResponse }
        func digit(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var result = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let a = digit(bytes[index]), let b = digit(bytes[index + 1]) else { throw InferenceError.malformedResponse }
            result.append(a * 16 + b)
        }
        self = result
    }
    init?(inferenceBase64URL: String) {
        let text = inferenceBase64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
}

/// NEAR v2 encryption. The caller must establish trust before supplying a model key.
final class InferenceEncryption {
    let clientPublicKey: Data
    private var clientSecret: [UInt8]
    private let modelPublicKey: [UInt8]

    init(modelEd25519: Data) throws {
        guard sodium_init() >= 0, modelEd25519.count == 32 else { throw InferenceError.cryptography }
        var publicKey = [UInt8](repeating: 0, count: 32)
        var signingSecret = [UInt8](repeating: 0, count: 64)
        defer { Self.erase(&signingSecret) }
        guard crypto_sign_keypair(&publicKey, &signingSecret) == 0 else { throw InferenceError.cryptography }
        var secret = [UInt8](repeating: 0, count: 32)
        var model = [UInt8](repeating: 0, count: 32)
        guard crypto_sign_ed25519_sk_to_curve25519(&secret, signingSecret) == 0,
              crypto_sign_ed25519_pk_to_curve25519(&model, Array(modelEd25519)) == 0 else {
            Self.erase(&secret)
            throw InferenceError.cryptography
        }
        clientPublicKey = Data(publicKey)
        clientSecret = secret
        modelPublicKey = model
    }

    deinit { Self.erase(&clientSecret) }

    private static func erase(_ bytes: inout [UInt8]) {
        let count = bytes.count
        bytes.withUnsafeMutableBytes { buffer in
            if let address = buffer.baseAddress { sodium_memzero(address, count) }
        }
    }

    private static func key(secret: [UInt8], publicKey: [UInt8]) throws -> [UInt8] {
        var shared = [UInt8](repeating: 0, count: 32)
        defer { erase(&shared) }
        guard crypto_scalarmult_curve25519(&shared, secret, publicKey) == 0 else { throw InferenceError.cryptography }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: Data(),
                                             info: Data("ed25519_encryption".utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Array($0) }
    }

    func encrypt(_ text: String) throws -> String {
        var ephemeralSecret = [UInt8](repeating: 0, count: 32)
        var ephemeralPublic = [UInt8](repeating: 0, count: 32)
        defer { Self.erase(&ephemeralSecret) }
        guard crypto_box_keypair(&ephemeralPublic, &ephemeralSecret) == 0 else { throw InferenceError.cryptography }
        var key = try Self.key(secret: ephemeralSecret, publicKey: modelPublicKey)
        defer { Self.erase(&key) }
        var nonce = [UInt8](repeating: 0, count: 24)
        nonce.withUnsafeMutableBytes { buffer in
            randombytes_buf(buffer.baseAddress!, buffer.count)
        }
        let plaintext = Array(text.utf8)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + 16)
        var length: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_encrypt(&ciphertext, &length, plaintext,
                UInt64(plaintext.count), nil, 0, nil, nonce, key) == 0 else { throw InferenceError.cryptography }
        return (Data(ephemeralPublic) + Data(nonce) + Data(ciphertext.prefix(Int(length)))).inferenceHex
    }

    func decrypt(_ hex: String) throws -> String {
        let wire = try Data(inferenceHex: hex)
        guard wire.count >= 72 else { throw InferenceError.cryptography }
        var key = try Self.key(secret: clientSecret, publicKey: Array(wire.prefix(32)))
        defer { Self.erase(&key) }
        let nonce = Array(wire[32..<56])
        let ciphertext = Array(wire.dropFirst(56))
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count - 16)
        defer { Self.erase(&plaintext) }
        var length: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_decrypt(&plaintext, &length, nil, ciphertext,
                UInt64(ciphertext.count), nil, 0, nonce, key) == 0,
              let text = String(bytes: plaintext.prefix(Int(length)), encoding: .utf8) else {
            throw InferenceError.cryptography
        }
        return text
    }
}

/// Authenticates ITA JWT bytes only. A valid signature is NOT an approved workload.
struct IntelTokenVerifier {
    static let issuer = "https://portal.trustauthority.intel.com"
    static let jwksURL = URL(string: issuer + "/certs")!

    static func authenticate(_ token: String, jwks: Data, now: Date = Date()) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count < 2_000_000,
              let headerData = Data(inferenceBase64URL: String(parts[0])),
              let claimsData = Data(inferenceBase64URL: String(parts[1])),
              let signature = Data(inferenceBase64URL: String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              header["typ"] as? String == "JWT", header["crit"] == nil,
              let algorithm = header["alg"] as? String, ["PS384", "RS256"].contains(algorithm),
              let kid = header["kid"] as? String,
              let keyset = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = keyset["keys"] as? [[String: Any]] else { throw InferenceError.malformedResponse }
        let matching = keys.filter { $0["kid"] as? String == kid }
        guard matching.count == 1, let key = matching.first, key["kty"] as? String == "RSA",
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == algorithm,
              let n = key["n"] as? String, let modulus = Data(inferenceBase64URL: n), modulus.count >= 256,
              let e = key["e"] as? String, let exponent = Data(inferenceBase64URL: e), !exponent.isEmpty else {
            throw InferenceError.unverified("ITA signing key unavailable or ambiguous")
        }
        let rsaDER = der(0x30, derInteger(modulus) + derInteger(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(rsaDER as CFData, attributes as CFDictionary, &error) else {
            throw InferenceError.cryptography
        }
        let secAlgorithm: SecKeyAlgorithm = algorithm == "PS384" ? .rsaSignatureMessagePSSSHA384 : .rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(publicKey, .verify, secAlgorithm),
              SecKeyVerifySignature(publicKey, secAlgorithm, Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                                    signature as CFData, &error) else { throw InferenceError.cryptography }
        let timestamp = now.timeIntervalSince1970
        guard claims["iss"] as? String == issuer,
              let issued = claims["iat"] as? Double, issued.isFinite, issued <= timestamp, timestamp - issued <= 300,
              let expires = claims["exp"] as? Double, expires.isFinite, expires > timestamp, expires > issued,
              let notBefore = claims["nbf"] as? Double, notBefore.isFinite, notBefore <= timestamp else {
            throw InferenceError.unverified("ITA issuer or freshness invalid")
        }
        return claims
    }

    static func validateTDXFreshness(_ authenticatedClaims: [String: Any], nonce: String) throws {
        // Accept documented v1 flat and v2 nested claim containers only.
        let tdx = authenticatedClaims["tdx"] as? [String: Any] ?? authenticatedClaims
        guard let debug = tdx["tdx_is_debuggable"] as? NSNumber,
              CFGetTypeID(debug) == CFBooleanGetTypeID(), !debug.boolValue,
              let reportText = tdx["tdx_report_data"] as? String else {
            throw InferenceError.unverified("Signed TDX claims lack a non-debug report-data binding")
        }
        let reportData: Data
        if reportText.count == 128 {
            reportData = try Data(inferenceHex: reportText)
        } else if let decoded = Data(base64Encoded: reportText) {
            reportData = decoded
        } else {
            throw InferenceError.malformedResponse
        }
        let expectedNonce = try Data(inferenceHex: nonce)
        guard reportData.count == 64, reportData.suffix(32) == expectedNonce else {
            throw InferenceError.unverified("Signed TDX report data does not bind the client nonce")
        }
        // No result from this helper grants inference access: measurement,
        // signer/configuration, GPU and live connection policies are separate.
    }

    private static func derInteger(_ data: Data) -> Data {
        var value = Data(data.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return der(0x02, value)
    }

    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = bytes.count
        var encodedLength = Data()
        if length < 128 { encodedLength.append(UInt8(length)) }
        else {
            var digits = [UInt8]()
            while length > 0 { digits.insert(UInt8(length & 255), at: 0); length >>= 8 }
            encodedLength.append(0x80 | UInt8(digits.count))
            encodedLength.append(contentsOf: digits)
        }
        return Data([tag]) + encodedLength + bytes
    }
}
