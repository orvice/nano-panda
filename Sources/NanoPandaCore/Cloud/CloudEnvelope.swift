import CryptoKit
import Foundation

public enum CloudEncryption: Codable, Equatable, Sendable {
    case password(String)
    case key(String)

    public static func generateKey() throws -> String {
        try ConfigurationCipher.generateKey()
    }

    public func validate() throws {
        switch self {
        case let .password(value):
            _ = try ConfigurationCipher.passwordBytes(value, minimumLength: 12)
        case let .key(value):
            _ = try ConfigurationCipher.rawKey(value)
        }
    }

    fileprivate var mode: CloudEnvelope.Protection {
        switch self {
        case .password: return .password
        case .key: return .key
        }
    }

    fileprivate func symmetricKey(salt: Data?) throws -> SymmetricKey {
        switch self {
        case let .password(value):
            guard let salt else { throw CloudEnvelope.invalidEnvelope }
            return try ConfigurationCipher.passwordKey(value, salt: salt)
        case let .key(value):
            return try ConfigurationCipher.rawKey(value)
        }
    }
}

public enum CloudEnvelope {
    public enum Kind: String, Sendable {
        case sync = "nano-panda.cloud-sync"
        case snapshot = "nano-panda.cloud-snapshot"
    }

    fileprivate enum Protection: String, Codable {
        case password, key
    }

    private struct Header: Codable {
        let format: String
        let version: Int
        let protection: Protection

        func authenticatedData(salt: Data?) -> Data {
            Data("\(format):\(version):\(protection.rawValue):".utf8) + (salt ?? Data())
        }
    }

    private struct Envelope: Codable {
        let header: Header
        let salt: Data?
        let sealed: Data

        private enum Field: String {
            case header, salt, sealed

            var key: AnyField { AnyField(stringValue: rawValue) }
        }

        private struct AnyField: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(header: Header, salt: Data?, sealed: Data) {
            self.header = header
            self.salt = salt
            self.sealed = sealed
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: AnyField.self)
            guard fields.allKeys.allSatisfy({ Field(rawValue: $0.stringValue) != nil }) else {
                throw CloudEnvelope.invalidEnvelope
            }
            header = try fields.decode(Header.self, forKey: Field.header.key)
            salt = fields.contains(Field.salt.key) ? try fields.decode(Data.self, forKey: Field.salt.key) : nil
            sealed = try fields.decode(Data.self, forKey: Field.sealed.key)
        }
    }

    static let fileLimit = 32 * 1024 * 1024
    private static let version = 1

    public static func encode<Value: Encodable>(
        _ value: Value, kind: Kind, encryption: CloudEncryption
    ) throws -> Data {
        try encryption.validate()
        let header = Header(format: kind.rawValue, version: version, protection: encryption.mode)
        let salt = encryption.mode == .password
            ? try ConfigurationCipher.randomBytes(count: ConfigurationCipher.saltSize) : nil
        let encoder = JSONEncoder()
        let payload = try encoder.encode(value)
        guard payload.count <= fileLimit else { throw fileTooLarge }
        let sealed = try ConfigurationCipher.seal(
            payload, with: encryption.symmetricKey(salt: salt), authenticating: header.authenticatedData(salt: salt)
        )
        let data = try encoder.encode(Envelope(header: header, salt: salt, sealed: sealed))
        guard data.count <= fileLimit else { throw fileTooLarge }
        return data
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type, from data: Data, kind: Kind, encryption: CloudEncryption
    ) throws -> Value {
        guard data.count <= fileLimit else { throw fileTooLarge }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.header.format == kind.rawValue,
              envelope.sealed.count >= 28 else { throw invalidEnvelope }
        guard envelope.header.version == version else {
            throw PandaError.invalid("此云端加密数据版本不受支持。")
        }
        guard envelope.header.protection == encryption.mode else {
            throw PandaError.invalid("云端加密数据使用了不同的凭据类型。")
        }
        switch envelope.header.protection {
        case .password:
            guard envelope.salt?.count == ConfigurationCipher.saltSize else { throw invalidEnvelope }
        case .key:
            guard envelope.salt == nil else { throw invalidEnvelope }
        }
        try encryption.validate()
        let key = try encryption.symmetricKey(salt: envelope.salt)
        let payload: Data
        do {
            payload = try ConfigurationCipher.open(
                envelope.sealed, with: key, authenticating: envelope.header.authenticatedData(salt: envelope.salt)
            )
        } catch {
            throw PandaError.invalid("同步密码或密钥不正确，或云端加密数据已损坏。")
        }
        guard let value = try? decoder.decode(type, from: payload) else { throw invalidEnvelope }
        return value
    }

    fileprivate static var invalidEnvelope: PandaError { .invalid("云端加密数据无效或已损坏。") }
    static var fileTooLarge: PandaError { .invalid("云端加密数据最大支持 32 MB。") }
}
