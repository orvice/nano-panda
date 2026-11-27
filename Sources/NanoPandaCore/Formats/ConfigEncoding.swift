import Foundation

enum ConfigEncoding {
    static func json<Value: Encodable>(_ value: Value, pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) throws -> ConfigValue {
        try JSONDecoder().decode(ConfigValue.self, from: Data(text.utf8))
    }

    static func text(_ data: Data?) throws -> String {
        guard let data else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PandaError.invalid("配置文件必须为 UTF-8。")
        }
        return text
    }
}
