import CommonCrypto
import CryptoKit
import Foundation
import Security

enum ConfigurationCipher {
    static let saltSize = 16
    static let keySize = 32
    private static let rounds: UInt32 = 600_000

    static func generateKey() throws -> String {
        try randomBytes(count: keySize).base64EncodedString()
    }

    static func rawKey(_ credential: String) throws -> SymmetricKey {
        let input = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count == 44,
              let raw = Data(base64Encoded: input), raw.count == keySize,
              raw.base64EncodedString() == input else {
            throw PandaError.invalid("请输入 32 字节的 Base64 密钥。")
        }
        return SymmetricKey(data: raw)
    }

    static func passwordBytes(_ credential: String, minimumLength: Int = 1) throws -> [UInt8] {
        let normalized = credential.precomposedStringWithCanonicalMapping
        guard normalized.count >= minimumLength, normalized.utf8.count <= 1024 else {
            throw PandaError.invalid("密码至少需要 \(minimumLength) 个字符，且不得超过 1024 UTF-8 字节。")
        }
        return Array(normalized.utf8)
    }

    static func passwordKey(_ credential: String, salt: Data) throws -> SymmetricKey {
        guard salt.count == saltSize else { throw PandaError.invalid("加密数据的随机盐无效。") }
        let password = try passwordBytes(credential)
        var derived = Data(count: keySize)
        let status = derived.withUnsafeMutableBytes { output in
            password.withUnsafeBufferPointer { input in
                salt.withUnsafeBytes { saltBytes in
                    input.baseAddress!.withMemoryRebound(to: CChar.self, capacity: input.count) { characters in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2), characters, input.count,
                            saltBytes.bindMemory(to: UInt8.self).baseAddress!, saltBytes.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                            output.bindMemory(to: UInt8.self).baseAddress!, output.count
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw PandaError.invalid("无法从密码派生加密密钥。") }
        return SymmetricKey(data: derived)
    }

    static func seal(_ payload: Data, with key: SymmetricKey, authenticating header: Data) throws -> Data {
        let box = try AES.GCM.seal(payload, using: key, authenticating: header)
        guard let sealed = box.combined else { throw PandaError.invalid("无法生成加密数据。") }
        return sealed
    }

    static func open(_ sealed: Data, with key: SymmetricKey, authenticating header: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: header)
    }

    static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PandaError.invalid("无法生成安全随机数据。") }
        return bytes
    }
}
