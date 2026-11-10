//
//  LRTemplateParser.swift
//  Photo Editor
//
//  Reads Lightroom's legacy .lrtemplate preset format, which is a serialised
//  Lua table:
//
//      s = {
//          id = "…",
//          title = "Ilford HP5+",
//          value = { settings = { Contrast = 25, ToneCurve = { 0, 0, … } } },
//      }
//
//  Only the subset Lightroom actually emits is supported — tables, strings,
//  numbers, booleans and nil. That's enough for every preset in the format.
//

import Foundation

indirect enum LuaValue {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case table(LuaTable)

    var tableValue: LuaTable? {
        if case .table(let t) = self { return t }
        return nil
    }

    /// Renders a scalar the way `RawPresetValues` expects it.
    var scalarText: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .boolean(let b): b ? "true" : "false"
        case .null, .table: nil
        }
    }
}

struct LuaTable {
    var keyed: [String: LuaValue] = [:]
    /// Positional entries, which is how Lightroom stores tone curves.
    var positional: [LuaValue] = []

    subscript(key: String) -> LuaValue? { keyed[key] }

    var numberArray: [Double]? {
        guard keyed.isEmpty, !positional.isEmpty else { return nil }
        var out: [Double] = []
        for value in positional {
            guard case .number(let n) = value else { return nil }
            out.append(n)
        }
        return out
    }
}

struct ParsedLRTemplate {
    var title: String?
    var internalName: String?
    var uuid: String?
    var settings: EditSettings
    var raw: RawPresetValues
}

enum LRTemplateParser {

    enum ParseError: LocalizedError {
        case unexpectedToken(String)
        case unexpectedEnd
        case noSettingsTable

        var errorDescription: String? {
            switch self {
            case .unexpectedToken(let t): "Unexpected \(t) while reading the .lrtemplate file."
            case .unexpectedEnd: "The .lrtemplate file ended unexpectedly."
            case .noSettingsTable: "No develop settings were found in this .lrtemplate file."
            }
        }
    }

    static func parse(data: Data) throws -> ParsedLRTemplate {
        // Lightroom writes these as UTF-8, but older ones can be Latin-1.
        let source = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        var lexer = Lexer(source: source)
        let root = try parseDocument(&lexer)

        guard let settingsTable = root["value"]?.tableValue?["settings"]?.tableValue
                ?? root["settings"]?.tableValue
        else {
            throw ParseError.noSettingsTable
        }

        let raw = rawValues(from: settingsTable)

        return ParsedLRTemplate(
            title: root["title"]?.scalarText,
            internalName: root["internalName"]?.scalarText,
            uuid: root["value"]?.tableValue?["uuid"]?.scalarText ?? root["id"]?.scalarText,
            settings: PresetMapper.settings(from: raw),
            raw: raw
        )
    }

    static func parse(url: URL) throws -> ParsedLRTemplate {
        try parse(data: Data(contentsOf: url))
    }

    /// Flattens a settings table into the shared untyped representation.
    private static func rawValues(from table: LuaTable) -> RawPresetValues {
        var raw = RawPresetValues()
        for (key, value) in table.keyed {
            if let numbers = value.tableValue?.numberArray {
                // Tone curves arrive as a flat x, y, x, y… list.
                var pairs: [String] = []
                var index = 0
                while index + 1 < numbers.count {
                    pairs.append("\(Int(numbers[index])), \(Int(numbers[index + 1]))")
                    index += 2
                }
                if !pairs.isEmpty { raw.sequences[key] = pairs }
            } else if let text = value.scalarText {
                raw.scalars[key] = text
            }
        }
        return raw
    }

    // MARK: - Parsing

    /// A document is one or more `name = value` assignments at top level.
    /// Lightroom emits exactly one (`s = { … }`); we merge any others.
    private static func parseDocument(_ lexer: inout Lexer) throws -> LuaTable {
        var merged = LuaTable()
        while let token = try lexer.peek() {
            guard case .identifier = token else {
                _ = try lexer.next()
                continue
            }
            _ = try lexer.next()
            guard case .equals? = try lexer.peek() else { continue }
            _ = try lexer.next()
            let value = try parseValue(&lexer)
            if let table = value.tableValue {
                merged.keyed.merge(table.keyed) { _, new in new }
                merged.positional.append(contentsOf: table.positional)
            }
        }
        return merged
    }

    private static func parseValue(_ lexer: inout Lexer) throws -> LuaValue {
        guard let token = try lexer.next() else { throw ParseError.unexpectedEnd }
        switch token {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .identifier(let name):
            switch name {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "nil": return .null
            default: return .string(name)
            }
        case .openBrace: return .table(try parseTable(&lexer))
        default: throw ParseError.unexpectedToken(String(describing: token))
        }
    }

    /// Parses the body of a table, with the opening brace already consumed.
    private static func parseTable(_ lexer: inout Lexer) throws -> LuaTable {
        var table = LuaTable()

        while true {
            guard let token = try lexer.peek() else { throw ParseError.unexpectedEnd }

            if case .closeBrace = token {
                _ = try lexer.next()
                return table
            }
            if case .comma = token { _ = try lexer.next(); continue }
            if case .semicolon = token { _ = try lexer.next(); continue }

            // `["key"] = value`
            if case .openBracket = token {
                _ = try lexer.next()
                let keyValue = try parseValue(&lexer)
                guard case .closeBracket? = try lexer.peek() else {
                    throw ParseError.unexpectedToken("]")
                }
                _ = try lexer.next()
                guard case .equals? = try lexer.peek() else {
                    throw ParseError.unexpectedToken("=")
                }
                _ = try lexer.next()
                let value = try parseValue(&lexer)
                if let key = keyValue.scalarText { table.keyed[key] = value }
                continue
            }

            // `key = value`, distinguished from a positional entry by the `=`.
            if case .identifier(let name) = token {
                _ = try lexer.next()
                if case .equals? = try lexer.peek() {
                    _ = try lexer.next()
                    table.keyed[name] = try parseValue(&lexer)
                } else {
                    // A bare identifier is a keyword literal in value position.
                    switch name {
                    case "true": table.positional.append(.boolean(true))
                    case "false": table.positional.append(.boolean(false))
                    case "nil": table.positional.append(.null)
                    default: table.positional.append(.string(name))
                    }
                }
                continue
            }

            table.positional.append(try parseValue(&lexer))
        }
    }

    // MARK: - Lexer

    private enum Token {
        case identifier(String)
        case string(String)
        case number(Double)
        case openBrace, closeBrace
        case openBracket, closeBracket
        case equals, comma, semicolon
    }

    private struct Lexer {
        private let chars: [Character]
        private var index = 0
        private var lookahead: Token?

        init(source: String) {
            chars = Array(source)
        }

        mutating func peek() throws -> Token? {
            if lookahead == nil { lookahead = try scan() }
            return lookahead
        }

        mutating func next() throws -> Token? {
            if let token = lookahead {
                lookahead = nil
                return token
            }
            return try scan()
        }

        private mutating func scan() throws -> Token? {
            skipTrivia()
            guard index < chars.count else { return nil }

            let c = chars[index]
            switch c {
            case "{": index += 1; return .openBrace
            case "}": index += 1; return .closeBrace
            case "[": index += 1; return .openBracket
            case "]": index += 1; return .closeBracket
            case "=": index += 1; return .equals
            case ",": index += 1; return .comma
            case ";": index += 1; return .semicolon
            case "\"", "'": return .string(scanString(quote: c))
            default: break
            }

            if c.isNumber || c == "-" || c == "+" || c == "." {
                if let number = scanNumber() { return .number(number) }
            }

            if c.isLetter || c == "_" {
                var name = ""
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
                    name.append(chars[index])
                    index += 1
                }
                return .identifier(name)
            }

            // Skip anything unrecognised rather than failing the whole file.
            index += 1
            return try scan()
        }

        private mutating func skipTrivia() {
            while index < chars.count {
                if chars[index].isWhitespace {
                    index += 1
                } else if chars[index] == "-", index + 1 < chars.count, chars[index + 1] == "-" {
                    while index < chars.count, chars[index] != "\n" { index += 1 }
                } else {
                    return
                }
            }
        }

        private mutating func scanString(quote: Character) -> String {
            index += 1  // opening quote
            var out = ""
            while index < chars.count {
                let c = chars[index]
                if c == "\\", index + 1 < chars.count {
                    index += 1
                    switch chars[index] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    default: out.append(chars[index])
                    }
                    index += 1
                } else if c == quote {
                    index += 1
                    return out
                } else {
                    out.append(c)
                    index += 1
                }
            }
            return out
        }

        private mutating func scanNumber() -> Double? {
            let start = index
            var text = ""
            if chars[index] == "-" || chars[index] == "+" {
                text.append(chars[index])
                index += 1
            }
            var sawDigit = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    sawDigit = true
                    text.append(c)
                    index += 1
                } else if c == "." || c == "e" || c == "E" {
                    text.append(c)
                    index += 1
                } else if (c == "-" || c == "+"), let last = text.last, last == "e" || last == "E" {
                    text.append(c)
                    index += 1
                } else {
                    break
                }
            }
            guard sawDigit, let value = Double(text) else {
                index = start
                return nil
            }
            return value
        }
    }
}
