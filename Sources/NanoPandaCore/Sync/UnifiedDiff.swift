import Foundation

public enum UnifiedDiff {
    private struct Line: Equatable {
        let text: String
        let endsInNewline: Bool
    }

    private struct Row {
        let prefix: String
        let line: Line
    }

    public static func make(before: String, after: String, path: String, existed: Bool, exists: Bool = true) -> String {
        let old = lines(before)
        let new = lines(after)
        guard old != new || existed != exists else { return "" }
        let path = path.replacingOccurrences(of: "\n", with: #"\n"#)
        let oldPath = existed ? path : "/dev/null"
        let newPath = exists ? path : "/dev/null"
        var output = ["--- " + oldPath, "+++ " + newPath]
        let difference = new.difference(from: old)
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removals.insert(offset)
            case let .insert(offset, _, _): insertions.insert(offset)
            }
        }

        var rows: [Row] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if removals.contains(oldIndex) {
                rows.append(Row(prefix: "-", line: old[oldIndex]))
                oldIndex += 1
            } else if insertions.contains(newIndex) {
                rows.append(Row(prefix: "+", line: new[newIndex]))
                newIndex += 1
            } else {
                rows.append(Row(prefix: " ", line: old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }

        var hunks: [Range<Int>] = []
        for index in rows.indices where rows[index].prefix != " " {
            let range = max(0, index - 3)..<min(rows.count, index + 4)
            if let previous = hunks.last, previous.upperBound >= range.lowerBound {
                hunks[hunks.count - 1] = previous.lowerBound..<range.upperBound
            } else {
                hunks.append(range)
            }
        }
        var previousEnd = 0
        var oldOffset = 0
        var newOffset = 0
        for hunk in hunks {
            for row in rows[previousEnd..<hunk.lowerBound] {
                if row.prefix != "+" { oldOffset += 1 }
                if row.prefix != "-" { newOffset += 1 }
            }
            let oldCount = rows[hunk].filter { $0.prefix != "+" }.count
            let newCount = rows[hunk].filter { $0.prefix != "-" }.count
            let oldStart = oldOffset + (oldCount == 0 ? 0 : 1)
            let newStart = newOffset + (newCount == 0 ? 0 : 1)
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            for row in rows[hunk] {
                output.append(row.prefix + row.line.text)
                if !row.line.endsInNewline { output.append("\\ No newline at end of file") }
            }
            previousEnd = hunk.upperBound
            oldOffset += oldCount
            newOffset += newCount
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func lines(_ text: String) -> [Line] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        let parts = bytes.split(separator: 10, omittingEmptySubsequences: false)
        return parts.enumerated().compactMap { index, part in
            if index == parts.count - 1 && part.isEmpty { return nil }
            return Line(text: String(decoding: part, as: UTF8.self), endsInNewline: index < parts.count - 1)
        }
    }
}
