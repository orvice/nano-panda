import Foundation

struct TOMLDocument {
    private struct Token {
        enum Kind { case symbol(UInt8), string(String), atom(String), newline }
        let kind: Kind
        let range: Range<Int>
    }

    private struct Statement {
        let scope: [String]
        let path: [String]
        let range: Range<Int>
        let valueRange: Range<Int>?
        let value: ConfigValue?
    }

    private let bytes: [UInt8]
    private let statements: [Statement]
    private let comments: [Range<Int>]

    init(_ text: String) throws {
        bytes = Array(text.utf8)
        var lexer = Lexer(bytes: bytes)
        var cursor = Cursor(tokens: try lexer.tokens())
        var scope: [String] = []
        var statements: [Statement] = []
        while cursor.current != nil {
            if cursor.newline() { continue }
            let start = cursor.current!.range.lowerBound
            if cursor.take(91) {
                let isArray = cursor.take(91)
                scope = try cursor.key()
                try cursor.require(93)
                if isArray {
                    try cursor.require(93)
                    if scope.first == "mcp_servers" { throw Self.unsupported }
                }
                statements.append(Statement(
                    scope: scope, path: scope, range: start..<cursor.end, valueRange: nil, value: nil
                ))
                guard cursor.current == nil || cursor.newline() else { throw Self.syntaxError }
            } else {
                let path = scope + (try cursor.key())
                try cursor.require(61)
                let valueStart = cursor.index
                try cursor.skipValue()
                let tokens = Array(cursor.tokens[valueStart..<cursor.index])
                guard let first = tokens.first, let last = tokens.last else { throw Self.syntaxError }
                if path == ["mcp_servers"] { throw Self.unsupported }
                var valueCursor = Cursor(tokens: tokens)
                let value = try? valueCursor.readCompleteValue()
                statements.append(Statement(
                    scope: scope, path: path, range: start..<last.range.upperBound,
                    valueRange: first.range.lowerBound..<last.range.upperBound, value: value
                ))
            }
        }
        self.statements = statements
        comments = lexer.comments
    }

    var serverIDs: Set<String> {
        Set(statements.compactMap { statement in
            guard statement.path.first == "mcp_servers", statement.path.count >= 2 else { return nil }
            return statement.path[1]
        })
    }

    func fields(for id: String) throws -> [String: ConfigValue] {
        var result: [String: ConfigValue] = [:]
        let prefix = ["mcp_servers", id]
        for statement in statements where statement.path.starts(with: prefix) {
            guard statement.valueRange != nil else { continue }
            let keys = Array(statement.path.dropFirst(2))
            guard !keys.isEmpty else { throw Self.unsupported }
            if let value = statement.value {
                try Self.insert(value, at: keys[...], in: &result)
            } else if AgentAdapter.codexFields.contains(keys[0]) {
                throw Self.unsupported
            }
        }
        for name in ["env", "http_headers"] where result[name] == nil &&
            statements.contains(where: { $0.path == prefix + [name] && $0.valueRange == nil }) {
            result[name] = .object([:])
        }
        return result
    }

    func merging(
        remove: Set<String>, replace: [String: [String: ConfigValue]], owned: Set<String>
    ) throws -> String {
        var edits: [JSONDocument.Edit] = []
        var insertions: [Int: String] = [:]

        func preserveComments(in range: Range<Int>, before statement: Statement) {
            let contents = comments.filter { range.contains($0.lowerBound) }
            guard !contents.isEmpty else { return }
            let restored = contents.map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "\n")
            insertions[statement.range.lowerBound, default: ""] += restored + "\n"
        }

        for statement in statements where statement.path.count >= 2 &&
            statement.path[0] == "mcp_servers" && remove.contains(statement.path[1]) {
            preserveComments(in: statement.range, before: statement)
            edits.append(.init(range: statement.range, text: ""))
        }
        for id in replace.keys.sorted() {
            let previous = try fields(for: id)
            let path = ["mcp_servers", id]
            let sections = statements.filter { $0.path.starts(with: path) }
            let originalFields = Set(sections.compactMap { $0.path.count > 2 ? $0.path[2] : nil })
            let desired = replace[id]!.filter { owned.contains($0.key) || !originalFields.contains($0.key) }
            let changed = Set(desired.keys).union(owned).filter { desired[$0] != previous[$0] }
            guard !changed.isEmpty || !serverIDs.contains(id) else { continue }
            var remaining = Set(changed.filter { desired[$0] != nil })

            for section in sections where section.path.count > 2 && changed.contains(section.path[2]) {
                let key = section.path[2]
                if section.path.count == 3, let valueRange = section.valueRange, let value = desired[key] {
                    preserveComments(in: valueRange, before: section)
                    edits.append(.init(range: valueRange, text: try Self.render(value)))
                    remaining.remove(key)
                } else {
                    preserveComments(in: section.range, before: section)
                    edits.append(.init(range: section.range, text: ""))
                }
            }
            guard !remaining.isEmpty else { continue }

            let sharedScope = sections.first { $0.scope.count < path.count && $0.valueRange != nil }
            let header = sections.first { $0.path == path && $0.valueRange == nil }
            let anchor = sharedScope ?? header
            let qualifiers = sharedScope.map { Array(path.dropFirst($0.scope.count)) } ?? []
            let fields = try remaining.sorted().map { key in
                let name = try (qualifiers + [key]).map(Self.quote).joined(separator: ".")
                return name + " = " + (try Self.render(desired[key]!))
            }.joined(separator: "\n")

            if let anchor {
                let end = afterLine(at: anchor.range.upperBound)
                let lineBreak = end == bytes.count && bytes.last != 10 ? "\n" : ""
                insertions[end, default: ""] += lineBreak + fields + "\n"
            } else {
                let section = try path.map(Self.quote).joined(separator: ".")
                insertions[bytes.count, default: ""] += "\n[\(section)]\n\(fields)\n"
            }
        }
        for (index, text) in insertions {
            edits.append(.init(range: index..<index, text: text))
        }
        var result = bytes
        for edit in edits.sorted(by: {
            if $0.range.lowerBound == $1.range.lowerBound { return !$0.range.isEmpty && $1.range.isEmpty }
            return $0.range.lowerBound > $1.range.lowerBound
        }) {
            result.replaceSubrange(edit.range, with: edit.text.utf8)
        }
        let output = String(decoding: result, as: UTF8.self)
        _ = try TOMLDocument(output)
        return output
    }

    private func afterLine(at index: Int) -> Int {
        bytes[index...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
    }

    private static func insert(
        _ value: ConfigValue, at keys: ArraySlice<String>, in fields: inout [String: ConfigValue]
    ) throws {
        guard let key = keys.first else { throw syntaxError }
        if keys.count == 1 {
            guard fields.updateValue(value, forKey: key) == nil else { throw syntaxError }
        } else {
            var parent: [String: ConfigValue] = [:]
            if let existing = fields[key] {
                guard let object = existing.object else { throw syntaxError }
                parent = object
            }
            try insert(value, at: keys.dropFirst(), in: &parent)
            fields[key] = .object(parent)
        }
    }

    private static func quote(_ value: String) throws -> String {
        let encoded = try ConfigEncoding.json(value)
        return encoded.replacingOccurrences(of: "\u{7F}", with: #"\u007F"#)
    }

    private static func render(_ value: ConfigValue) throws -> String {
        switch value {
        case let .string(value): return try quote(value)
        case let .array(values): return "[" + (try values.map(render).joined(separator: ", ")) + "]"
        case let .object(fields):
            let fields = try fields.keys.sorted().map { try quote($0) + " = " + render(fields[$0]!) }
            return "{ " + fields.joined(separator: ", ") + " }"
        case let .number(value):
            guard value.isFinite else { throw syntaxError }
            return String(value)
        case .null:
            throw PandaError.invalid("Codex TOML 不支持 null。")
        default:
            return try ConfigEncoding.json(value)
        }
    }

    private static let syntaxError = PandaError.invalid("TOML 配置格式错误。")
    private static let unsupported = PandaError.invalid("无法安全读取此 Codex MCP 配置结构。")

    private struct Cursor {
        let tokens: [Token]
        var index = 0
        var current: Token? { index < tokens.count ? tokens[index] : nil }
        var end: Int { tokens[index - 1].range.upperBound }

        mutating func take(_ symbol: UInt8) -> Bool {
            guard case let .symbol(value)? = current?.kind, value == symbol else { return false }
            index += 1
            return true
        }

        mutating func require(_ symbol: UInt8) throws {
            guard take(symbol) else { throw syntaxError }
        }

        mutating func newline() -> Bool {
            guard case .newline? = current?.kind else { return false }
            index += 1
            return true
        }

        mutating func key() throws -> [String] {
            var parts: [String] = []
            repeat {
                switch current?.kind {
                case let .string(value)?: parts.append(value)
                case let .atom(value)?:
                    guard !value.isEmpty, value.utf8.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0) ||
                            (97...122).contains($0) || $0 == 45 || $0 == 95
                    }) else { throw syntaxError }
                    parts.append(value)
                default: throw syntaxError
                }
                index += 1
            } while take(46)
            return parts
        }

        mutating func skipValue() throws {
            var closing: [UInt8] = []
            while let token = current {
                switch token.kind {
                case .newline where closing.isEmpty: return
                case .symbol(91): closing.append(93)
                case .symbol(123): closing.append(125)
                case let .symbol(symbol) where symbol == 93 || symbol == 125:
                    guard closing.popLast() == symbol else { throw syntaxError }
                default: break
                }
                index += 1
            }
            guard closing.isEmpty else { throw syntaxError }
        }

        mutating func readCompleteValue() throws -> ConfigValue {
            let result = try value(depth: 0)
            guard current == nil else { throw syntaxError }
            return result
        }

        mutating func value(depth: Int) throws -> ConfigValue {
            guard depth < 128 else { throw syntaxError }
            while newline() {}
            if take(91) {
                var values: [ConfigValue] = []
                while newline() {}
                while !take(93) {
                    values.append(try value(depth: depth + 1))
                    while newline() {}
                    if take(93) { break }
                    try require(44)
                    while newline() {}
                }
                return .array(values)
            }
            if take(123) {
                var fields: [String: ConfigValue] = [:]
                if !take(125) {
                    repeat {
                        let path = try key()
                        try require(61)
                        try insert(value(depth: depth + 1), at: path[...], in: &fields)
                    } while take(44)
                    try require(125)
                }
                return .object(fields)
            }
            switch current?.kind {
            case let .string(string)?:
                index += 1
                return .string(string)
            case let .atom(atom)?:
                index += 1
                if atom == "true" { return .bool(true) }
                if atom == "false" { return .bool(false) }
                var number = atom.replacingOccurrences(of: "_", with: "")
                if take(46), case let .atom(fraction)? = current?.kind {
                    number += "." + fraction.replacingOccurrences(of: "_", with: "")
                    index += 1
                }
                if let integer = Int64(number) { return .integer(integer) }
                for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where number.hasPrefix(prefix) {
                    if let integer = Int64(number.dropFirst(2), radix: radix) { return .integer(integer) }
                }
                if let value = Double(number), value.isFinite { return .number(value) }
                throw syntaxError
            default: throw syntaxError
            }
        }
    }

    private struct Lexer {
        let bytes: [UInt8]
        var index = 0
        var comments: [Range<Int>] = []

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func tokens() throws -> [Token] {
            var result: [Token] = []
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
            while let byte = current {
                let start = index
                let kind: Token.Kind
                switch byte {
                case 9, 13, 32:
                    index += 1
                    continue
                case 35:
                    while let next = current, next != 10 { index += 1 }
                    comments.append(start..<index)
                    continue
                case 10:
                    index += 1
                    kind = .newline
                case 34, 39:
                    kind = .string(try string(quote: byte))
                case 44, 46, 61, 91, 93, 123, 125:
                    index += 1
                    kind = .symbol(byte)
                default:
                    while let next = current, ![9, 10, 13, 32, 34, 35, 39, 44, 46, 61, 91, 93, 123, 125].contains(next) {
                        index += 1
                    }
                    kind = .atom(String(decoding: bytes[start..<index], as: UTF8.self))
                }
                result.append(Token(kind: kind, range: start..<index))
            }
            return result
        }

        mutating func string(quote: UInt8) throws -> String {
            let delimiter = [quote, quote, quote]
            let multiline = bytes[index...].starts(with: delimiter)
            index += multiline ? 3 : 1
            if multiline {
                if bytes[index...].starts(with: [13, 10]) { index += 2 }
                else if current == 10 { index += 1 }
            }
            var value: [UInt8] = []
            while let byte = current {
                index += 1
                if byte == quote {
                    if !multiline { return String(decoding: value, as: UTF8.self) }
                    if bytes[index...].starts(with: [quote, quote]) {
                        index += 2
                        for _ in 0..<2 where current == quote {
                            value.append(quote)
                            index += 1
                        }
                        return String(decoding: value, as: UTF8.self)
                    }
                }
                if byte == 10, !multiline { throw syntaxError }
                if byte == 92, quote == 34 {
                    try escape(into: &value, multiline: multiline)
                } else {
                    value.append(byte)
                }
            }
            throw syntaxError
        }

        mutating func escape(into value: inout [UInt8], multiline: Bool) throws {
            guard let byte = current else { throw syntaxError }
            index += 1
            switch byte {
            case 34, 92: value.append(byte)
            case 98: value.append(8)
            case 116: value.append(9)
            case 110: value.append(10)
            case 102: value.append(12)
            case 114: value.append(13)
            case 117, 85:
                let count = byte == 117 ? 4 : 8
                guard index + count <= bytes.count,
                      let codepoint = UInt32(String(decoding: bytes[index..<index + count], as: UTF8.self), radix: 16),
                      let scalar = Unicode.Scalar(codepoint) else { throw syntaxError }
                value += String(scalar).utf8
                index += count
            case 9, 10, 13, 32:
                guard multiline else { throw syntaxError }
                index -= 1
                while current == 9 || current == 32 { index += 1 }
                if current == 13 { index += 1 }
                guard current == 10 else { throw syntaxError }
                while let next = current, [9, 10, 13, 32].contains(next) { index += 1 }
            default: throw syntaxError
            }
        }
    }
}
