@testable import CodeInsightAI
import Foundation
import Security
import Testing

/// The sign-in's ID token is trusted only when the key its header names
/// signed it. Keys here are made by Security and published the way OpenAI's
/// JWKS does (base64url `n`, `e`), so the DER that Cairn rebuilds from them
/// is checked against Security's own encoding.
struct ChatGPTIdentityTests {
    static func newKey() -> SecKey {
        SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, nil)!
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Reads SEQUENCE { INTEGER n, INTEGER e } as Security exports a public key.
    static func jwk(_ key: SecKey, kid: String) -> [String: String] {
        let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
        var index = 0
        func header() -> Int {
            index += 1
            var length = Int(der[index]); index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                length = der[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            return length
        }
        _ = header()
        let nLength = header()
        let n = Data(der[index..<index + nLength].drop { $0 == 0 }); index += nLength
        let eLength = header()
        let e = Data(der[index..<index + eLength])
        return ["kty": "RSA", "kid": kid, "alg": "RS256", "use": "sig", "n": base64URL(n), "e": base64URL(e)]
    }

    static func token(header: [String: String], claims: String, signedBy key: SecKey) -> String {
        let head = base64URL(try! JSONSerialization.data(withJSONObject: header))
        let body = base64URL(Data(claims.utf8))
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                              Data((head + "." + body).utf8) as CFData, nil)! as Data
        return head + "." + body + "." + base64URL(signature)
    }

    @Test func anIDTokenIsTrustedOnlyWithASignatureFromTheKeyItNames() throws {
        let signer = Self.newKey(), other = Self.newKey()
        let keys = try JSONSerialization.data(withJSONObject: ["keys": [
            Self.jwk(other, kid: "b"), Self.jwk(signer, kid: "a"),
        ]])
        let claims = #"{"iss":"https://auth.openai.com","sub":"user-1","aud":["oaiapp_x"]}"#
        let good = Self.token(header: ["alg": "RS256", "kid": "a"], claims: claims, signedBy: signer)
        #expect(ChatGPTAccount.signatureIsValid(good, keys: keys))

        // The same claims with another subject, under the original signature.
        let parts = good.split(separator: ".").map(String.init)
        let forged = parts[0] + "." + Self.base64URL(Data(claims.replacingOccurrences(of: "user-1", with: "user-2").utf8))
            + "." + parts[2]
        #expect(!ChatGPTAccount.signatureIsValid(forged, keys: keys))
        // Signed by a published key, but not the one the header names.
        #expect(!ChatGPTAccount.signatureIsValid(
            Self.token(header: ["alg": "RS256", "kid": "a"], claims: claims, signedBy: other), keys: keys))
        #expect(!ChatGPTAccount.signatureIsValid(
            Self.token(header: ["alg": "RS256", "kid": "gone"], claims: claims, signedBy: signer), keys: keys))
        #expect(!ChatGPTAccount.signatureIsValid(
            Self.token(header: ["alg": "none", "kid": "a"], claims: claims, signedBy: signer), keys: keys))
        #expect(!ChatGPTAccount.signatureIsValid(parts[0] + "." + parts[1] + ".", keys: keys))
        #expect(!ChatGPTAccount.signatureIsValid(good, keys: Data("{}".utf8)))
    }
}
