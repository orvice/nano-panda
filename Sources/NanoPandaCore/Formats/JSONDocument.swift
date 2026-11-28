import Foundation

struct JSONDocument {
    struct Member {
        let name: String
        let start: Int
        let value: Node
        let comma: Int?
    }

    struct Node {
        let range: Range<Int>
        let members: [Member]?
        let value: ConfigValue

        subscript(key: String) -> Node? {
            members?.first { $0.name == key }?.value
        }
    }

    struct Edit {
        let range: Range<Int>
        let text: String
    }

    let bytes: [UInt8]
    let root: Node

    init(_ text: String, allowsComments: Bool) throws {
        var parser = Parser(bytes: Array(text.utf8), allowsComments: allowsComments)
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        root = try parser.parseValue(depth: 0)
        try parser.skipTrivia()
        guard parser.index == parser.bytes.count else { throw parser.syntaxError }
        bytes = parser.bytes
    }

    func applying(_ edits: [Edit]) -> String {
        var result = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.text.utf8)
        }
        return String(decoding: result, as: UTF8.self)
    }

    func editObject(
        _ node: Node, remove: Set<String>, replace: [String: ConfigValue]
    ) throws -> [Edit] {
        guard let members = node.members else { throw PandaError.invalid("预期为 JSON 对象。") }
        var edits: [Edit] = []
        let retained = members.filter { !remove.contains($0.name) }
        let existingNames = Set(retained.map(\.name))
        let additions = replace.keys.filter { !existingNames.contains($0) }.sorted()
        let closing = node.range.upperBound - 1
        let keepTrailingComma = members.last?.comma != nil

        for member in members {
            if remove.contains(member.name) {
                edits.append(Edit(range: member.start..<member.value.range.upperBound, text: ""))
                if let comma = member.comma { edits.append(Edit(range: comma..<comma + 1, text: "")) }
                continue
            }
            if let value = replace[member.name], value != member.value.value {
                let text = try ConfigEncoding.json(value, pretty: true)
                    .replacingOccurrences(of: "\n", with: "\n" + indentation(at: member.start))
                edits.append(Edit(range: member.value.range, text: text))
            }
            let needsComma = member.start != retained.last?.start || !additions.isEmpty || keepTrailingComma
            if let comma = member.comma, !needsComma {
                edits.append(Edit(range: comma..<comma + 1, text: ""))
            } else if member.comma == nil, needsComma {
                let end = member.value.range.upperBound
                edits.append(Edit(range: end..<end, text: ","))
            }
        }
        if !additions.isEmpty {
            let indent = indentation(at: retained.first?.start ?? members.first?.start ?? closing)
            let closingIndent = indentation(at: closing)
            let memberIndent = indent.count > closingIndent.count ? indent : closingIndent + "  "
            let fields = try additions.map { key in
                let field = try ConfigEncoding.json(key) + ": " + ConfigEncoding.json(replace[key]!, pretty: true)
                return memberIndent + field.replacingOccurrences(of: "\n", with: "\n" + memberIndent)
            }
            let suffix = keepTrailingComma ? "," : ""
            let rendered = fields.joined(separator: ",\n") + suffix
            let lineStart = closing - closingIndent.utf8.count
            let ownLine = lineStart > 0 && bytes[lineStart - 1] == 10
            let position = ownLine ? lineStart : closing
            let insertion = ownLine ? rendered + "\n" : "\n" + rendered + "\n" + closingIndent
            if let last = edits.indices.last(where: { edits[$0].range == position..<position }) {
                let combined = edits[last].text + insertion
                edits[last] = Edit(range: position..<position, text: combined)
            } else {
                edits.append(Edit(range: position..<position, text: insertion))
            }
        }
        return edits
    }

    private func indentation(at index: Int) -> String {
        let start = bytes[..<index].lastIndex(of: 10).map { $0 + 1 } ?? 0
        return String(decoding: bytes[start..<index].prefix { $0 == 32 || $0 == 9 }, as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        let allowsComments: Bool
        var index = 0

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        var syntaxError: PandaError { .invalid("JSON 配置格式错误（字节 \(index)）。") }

        mutating func take(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            index += 1
            return true
        }

        mutating func require(_ byte: UInt8) throws {
            guard take(byte) else { throw syntaxError }
        }

        mutating func skipTrivia() throws {
            while let byte = current {
                if [9, 10, 13, 32].contains(byte) {
                    index += 1
                } else if allowsComments, byte == 47, index + 1 < bytes.count {
                    switch bytes[index + 1] {
                    case 47:
                        index += 2
                        while let next = current, next != 10, next != 13 { index += 1 }
                    case 42:
                        index += 2
                        while index + 1 < bytes.count, bytes[index] != 42 || bytes[index + 1] != 47 {
                            index += 1
                        }
                        guard index + 1 < bytes.count else { throw syntaxError }
                        index += 2
                    default: return
                    }
                } else {
                    return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> Node {
            guard depth < 256 else { throw syntaxError }
            try skipTrivia()
            let start = index
            switch current {
            case 123:
                index += 1
                var members: [Member] = []
                var fields: [String: ConfigValue] = [:]
                try skipTrivia()
                if !take(125) {
                    while true {
                        let keyStart = index
                        let name = try parseString()
                        try skipTrivia()
                        try require(58)
                        let value = try parseValue(depth: depth + 1)
                        guard fields.updateValue(value.value, forKey: name) == nil else {
                            throw PandaError.invalid("JSON 配置中存在重复键「\(name)」。")
                        }
                        try skipTrivia()
                        let comma = take(44) ? index - 1 : nil
                        members.append(Member(name: name, start: keyStart, value: value, comma: comma))
                        if comma == nil {
                            try require(125)
                            break
                        }
                        try skipTrivia()
                        if allowsComments && take(125) { break }
                    }
                }
                return Node(range: start..<index, members: members, value: .object(fields))
            case 91:
                index += 1
                var items: [ConfigValue] = []
                try skipTrivia()
                if !take(93) {
                    while true {
                        items.append(try parseValue(depth: depth + 1).value)
                        try skipTrivia()
                        if !take(44) {
                            try require(93)
                            break
                        }
                        try skipTrivia()
                        if allowsComments && take(93) { break }
                    }
                }
                return Node(range: start..<index, members: nil, value: .array(items))
            case 34:
                let value = try parseString()
                return Node(range: start..<index, members: nil, value: .string(value))
            default:
                while let byte = current, ![9, 10, 13, 32, 44, 47, 93, 125].contains(byte) { index += 1 }
                do {
                    let value = try ConfigEncoding.decode(String(decoding: bytes[start..<index], as: UTF8.self))
                    return Node(range: start..<index, members: nil, value: value)
                } catch {
                    throw syntaxError
                }
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            try require(34)
            while let byte = current {
                index += 1
                if byte == 34 {
                    let raw = String(decoding: bytes[start..<index], as: UTF8.self)
                    guard let value = try? ConfigEncoding.decode(raw).string else { throw syntaxError }
                    return value
                }
                if byte == 92 {
                    guard current != nil else { throw syntaxError }
                    index += 1
                }
            }
            throw syntaxError
        }
    }
}
