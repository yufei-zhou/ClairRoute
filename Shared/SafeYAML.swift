import Foundation

public indirect enum YAMLValue: Sendable, Equatable {
    case mapping([String: YAMLValue]), sequence([YAMLValue]), string(String)
    case bool(Bool), integer(Int), null
    public var map: [String: YAMLValue]? { if case .mapping(let v) = self { v } else { nil } }
    public var array: [YAMLValue]? { if case .sequence(let v) = self { v } else { nil } }
    public var text: String? {
        switch self { case .string(let s): s; case .integer(let n): String(n); default: nil }
    }
    public var boolean: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var int: Int? { if case .integer(let v) = self { v } else { nil } }
}

public struct YAMLParseError: LocalizedError, Sendable {
    public let line: Int
    public let reason: String
    public var errorDescription: String? { "YAML 第 \(line) 行：\(reason)（输入内容已隐藏）。" }
}

/// Deliberately constrained YAML: block maps/sequences, single/double quoted scalars,
/// single/multiline flow maps/arrays, JSON, comments and one document marker.
/// Rejects aliases/anchors/tags/merge keys/directives/block scalars/multiple documents.
/// Error messages never echo any input scalar or URL.
public enum SafeYAML {
    public static let maximumBytes = 4_194_304
    public static func parse(_ data: Data) throws -> YAMLValue {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = String(data: data, encoding: .utf8) else {
            throw YAMLParseError(line: 1, reason: "编码无效或文件超过 4 MiB")
        }
        var parser = try BlockParser(source)
        return try parser.parse()
    }
    public static func parse(_ text: String) throws -> YAMLValue { try parse(Data(text.utf8)) }

    private struct Line {
        let indent: Int
        let text: String
        let number: Int
        var isSequence: Bool { text == "-" || text.hasPrefix("- ") }
    }

    private struct BlockParser {
        var lines: [Line] = []
        var position = 0
        var count = 0

        init(_ source: String) throws {
            var markerSeen = false
            var pending: (indent: Int, text: String, line: Int)?
            let rawLines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            guard rawLines.count <= 30_000 else { throw YAMLParseError(line: 1, reason: "行数超过限制") }
            for (index, raw) in rawLines.enumerated() {
                let number = index + 1
                guard raw.utf8.count <= 65_536, !raw.contains("\t"), !raw.contains("\r"), !raw.contains("\0") else {
                    throw YAMLParseError(line: number, reason: "不支持制表符、控制字符或超长行")
                }
                var text = Self.uncomment(String(raw)).trimmingCharacters(in: .whitespaces)
                if index == 0 { text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }
                if text.isEmpty { continue }
                if text == "---" {
                    guard !markerSeen, lines.isEmpty, pending == nil else { throw YAMLParseError(line: number, reason: "只允许一个 YAML 文档") }
                    markerSeen = true; continue
                }
                guard text != "...", !text.hasPrefix("%") else { throw YAMLParseError(line: number, reason: "不支持文档指令或多文档") }
                let indent = raw.prefix(while: { $0 == " " }).count
                if var accumulating = pending {
                    accumulating.text += " " + text
                    guard accumulating.text.utf8.count <= 262_144 else { throw YAMLParseError(line: number, reason: "流式集合超过限制") }
                    if Self.flowBalance(accumulating.text) == 0 {
                        lines.append(Line(indent: accumulating.indent, text: accumulating.text, number: accumulating.line))
                        pending = nil
                    } else { pending = accumulating }
                } else if Self.flowBalance(text) > 0 {
                    pending = (indent, text, number)
                } else { lines.append(Line(indent: indent, text: text, number: number)) }
            }
            guard pending == nil else { throw YAMLParseError(line: pending!.line, reason: "流式集合未闭合") }
        }

        mutating func parse() throws -> YAMLValue {
            guard let first = lines.first, first.indent == 0 else { throw YAMLParseError(line: 1, reason: "根节点必须从第一列开始") }
            if first.text.hasPrefix("{") || first.text.hasPrefix("[") {
                guard lines.count == 1 else { throw error("流式根节点后有多余内容") }
                return try scalar(first.text, line: first.number, depth: 0)
            }
            let value = try block(indent: 0, depth: 0)
            guard position == lines.count else { throw error("缩进或集合结构无效") }
            return value
        }

        mutating func block(indent: Int, depth: Int) throws -> YAMLValue {
            guard depth <= 20 else { throw error("嵌套深度超过 20") }
            guard position < lines.count, lines[position].indent == indent else { throw error("缩进无效") }
            if lines[position].isSequence {
                var values: [YAMLValue] = []
                while position < lines.count, lines[position].indent == indent, lines[position].isSequence {
                    let current = lines[position]; position += 1
                    let rest = String(current.text.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty {
                        guard position < lines.count, lines[position].indent > indent else { throw error("序列项不能为空") }
                        values.append(try block(indent: lines[position].indent, depth: depth + 1))
                    } else if Self.separator(rest) != nil {
                        var map: [String: YAMLValue] = [:]
                        try entry(rest, line: current.number, indent: indent + 2, depth: depth + 1, into: &map)
                        while position < lines.count, lines[position].indent == indent + 2, !lines[position].isSequence {
                            let next = lines[position]; position += 1
                            try entry(next.text, line: next.number, indent: indent + 2, depth: depth + 1, into: &map)
                        }
                        values.append(.mapping(map))
                    } else { values.append(try scalar(rest, line: current.number, depth: depth + 1)) }
                    count += 1
                    guard count <= 40_000 else { throw error("节点数量超过限制") }
                }
                return .sequence(values)
            }
            var map: [String: YAMLValue] = [:]
            while position < lines.count, lines[position].indent == indent, !lines[position].isSequence {
                let current = lines[position]; position += 1
                try entry(current.text, line: current.number, indent: indent, depth: depth, into: &map)
            }
            return .mapping(map)
        }

        mutating func entry(_ text: String, line: Int, indent: Int, depth: Int,
                            into map: inout [String: YAMLValue]) throws {
            guard let separator = Self.separator(text) else { throw YAMLParseError(line: line, reason: "映射缺少冒号") }
            let keySource = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
            guard case .string(let key) = try scalar(keySource, line: line, depth: depth),
                  !key.isEmpty, key != "<<", map[key] == nil else {
                throw YAMLParseError(line: line, reason: "映射键重复、无效或使用了合并键")
            }
            let rest = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty, position < lines.count,
               lines[position].indent > indent || (lines[position].indent == indent && lines[position].isSequence) {
                map[key] = try block(indent: lines[position].indent, depth: depth + 1)
            } else if rest.isEmpty { map[key] = .null }
            else { map[key] = try scalar(rest, line: line, depth: depth + 1) }
            count += 1
            guard count <= 40_000 else { throw error("节点数量超过限制") }
        }

        func scalar(_ text: String, line: Int, depth: Int) throws -> YAMLValue {
            var flow = FlowParser(text, line: line)
            return try flow.parse(depth: depth)
        }
        func error(_ reason: String) -> YAMLParseError { YAMLParseError(line: position < lines.count ? lines[position].number : (lines.last?.number ?? 1), reason: reason) }

        static func separator(_ text: String) -> String.Index? {
            var quote: Character?; var escaped = false; var nesting = 0
            for index in text.indices {
                let c = text[index]
                if let q = quote {
                    if escaped { escaped = false; continue }
                    if q == "\"", c == "\\" { escaped = true; continue }
                    if c == q { quote = nil }; continue
                }
                if c == "\"" || c == "'" { quote = c }
                else if c == "[" || c == "{" { nesting += 1 }
                else if c == "]" || c == "}" { nesting -= 1 }
                else if c == ":", nesting == 0 {
                    let next = text.index(after: index)
                    if next == text.endIndex || text[next].isWhitespace { return index }
                }
            }
            return nil
        }
        static func uncomment(_ text: String) -> String {
            var quote: Character?; var escaped = false
            for index in text.indices {
                let c = text[index]
                if let q = quote {
                    if escaped { escaped = false; continue }
                    if q == "\"", c == "\\" { escaped = true; continue }
                    if c == q { quote = nil }; continue
                }
                if c == "\"" || c == "'" { quote = c }
                if c == "#", index == text.startIndex || text[text.index(before: index)].isWhitespace { return String(text[..<index]) }
            }
            return text
        }
        static func flowBalance(_ text: String) -> Int {
            var quote: Character?; var escaped = false; var balance = 0
            for c in text {
                if let q = quote {
                    if escaped { escaped = false; continue }
                    if q == "\"", c == "\\" { escaped = true; continue }
                    if c == q { quote = nil }; continue
                }
                if c == "\"" || c == "'" { quote = c }
                else if c == "[" || c == "{" { balance += 1 }
                else if c == "]" || c == "}" { balance -= 1 }
            }
            return balance
        }
    }

    private struct FlowParser {
        var chars: [Character]
        let line: Int
        var offset = 0
        var count = 0
        init(_ text: String, line: Int) { chars = Array(text); self.line = line }
        mutating func parse(depth: Int) throws -> YAMLValue {
            let value = try value(depth: depth)
            whitespace()
            guard offset == chars.count else { throw failure("标量或集合后有多余内容") }
            return value
        }
        mutating func value(depth: Int, key: Bool = false, delimited: Bool = false) throws -> YAMLValue {
            guard depth <= 20 else { throw failure("嵌套深度超过 20") }
            count += 1
            guard count <= 40_000 else { throw failure("节点数量超过限制") }
            whitespace()
            guard offset < chars.count else { return .null }
            let first = chars[offset]
            if first == "{" {
                offset += 1; whitespace(); var map: [String: YAMLValue] = [:]
                if consume("}") { return .mapping(map) }
                while true {
                    guard case .string(let name) = try value(depth: depth + 1, key: true),
                          !name.isEmpty, name != "<<", map[name] == nil else { throw failure("映射键重复或无效") }
                    whitespace(); guard consume(":") else { throw failure("映射缺少冒号") }
                    map[name] = try value(depth: depth + 1, delimited: true)
                    whitespace(); if consume("}") { break }
                    guard consume(",") else { throw failure("流式映射缺少逗号") }
                    whitespace(); if consume("}") { break }
                }
                return .mapping(map)
            }
            if first == "[" {
                offset += 1; whitespace(); var array: [YAMLValue] = []
                if consume("]") { return .sequence(array) }
                while true {
                    array.append(try value(depth: depth + 1, delimited: true)); whitespace()
                    if consume("]") { break }
                    guard consume(",") else { throw failure("流式序列缺少逗号") }
                    whitespace(); if consume("]") { break }
                }
                return .sequence(array)
            }
            if first == "\"" || first == "'" { return .string(try quoted(first)) }
            guard !["!", "&", "*", "|", ">", "%", "`", "@"].contains(first) else {
                throw failure("不支持标签、锚点、别名、块标量或指令")
            }
            let start = offset
            while offset < chars.count {
                if (delimited || key) && [",", "}", "]"].contains(chars[offset]) || (key && chars[offset] == ":") { break }
                offset += 1
            }
            let token = String(chars[start..<offset]).trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, token.utf8.count <= 16_384 else { throw failure("标量为空或过长") }
            if key { return .string(token) }
            switch token.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null", "~": return .null
            default: break
            }
            // Preserve leading zeroes in authentication keys and Reality short IDs.
            // Numeric model fields explicitly parse text later, without changing strings.
            if let integer = Int(token), token == String(integer) { return .integer(integer) }
            return .string(token)
        }
        mutating func quoted(_ quote: Character) throws -> String {
            let start = offset; offset += 1; var value = ""
            while offset < chars.count {
                let c = chars[offset]; offset += 1
                if c == quote {
                    if quote == "'", offset < chars.count, chars[offset] == "'" {
                        value.append("'"); offset += 1; continue
                    }
                    if quote == "\"" {
                        let encoded = String(chars[start..<offset])
                        guard let decoded = try? JSONDecoder().decode(String.self, from: Data(encoded.utf8)) else { throw failure("双引号字符串转义无效") }
                        value = decoded
                    }
                    guard value.utf8.count <= 16_384 else { throw failure("标量过长") }
                    return value
                }
                if quote == "\"", c == "\\" {
                    guard offset < chars.count else { throw failure("转义未完成") }
                    offset += 1
                } else { value.append(c) }
            }
            throw failure("引号未闭合")
        }
        mutating func whitespace() { while offset < chars.count, chars[offset].isWhitespace { offset += 1 } }
        mutating func consume(_ c: Character) -> Bool {
            guard offset < chars.count, chars[offset] == c else { return false }
            offset += 1; return true
        }
        func failure(_ reason: String) -> YAMLParseError { YAMLParseError(line: line, reason: reason) }
    }
}
