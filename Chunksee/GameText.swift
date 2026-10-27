import ChunkseeKit
import Foundation

/// Plain title layout for Kit's interpreted components. Language selection stays in GameNames.
nonisolated enum GameText {
    private enum Limit: Error { case exceeded }

    private struct Budget {
        var visits = 65_536
        var bytes = 16 * 1024 * 1024
        var templateBytes = 16 * 1024 * 1024

        mutating func visit() throws {
            guard visits > 0 else { throw Limit.exceeded }
            visits -= 1
        }

        mutating func append(_ text: String, to output: inout String) throws {
            let count = text.utf8.count
            guard count <= bytes else { throw Limit.exceeded }
            bytes -= count
            output.append(text)
        }
    }

    static func string(_ content: TextComponent.Content, translation: (String) -> String?) -> String? {
        var output = "", budget = Budget()
        do {
            try append(content, translation: translation, depth: 0, output: &output, budget: &budget)
            return output
        } catch { return nil }
    }

    private static func append(_ content: TextComponent.Content, translation: (String) -> String?, depth: Int,
                               output: inout String, budget: inout Budget) throws {
        // Kit permits 64 source levels; an `extra` list also wraps its base in a sequence.
        guard depth < 128 else { throw Limit.exceeded }
        try budget.visit()
        switch content {
        case .literal(let text):
            try budget.append(text, to: &output)
        case .sequence(let children):
            for child in children {
                try append(child, translation: translation, depth: depth + 1, output: &output, budget: &budget)
            }
        case .translated(let key, let fallback, let arguments):
            let template = translation(key) ?? fallback ?? key
            let count = template.utf8.count
            guard count <= budget.templateBytes else { throw Limit.exceeded }
            budget.templateBytes -= count
            let bytes = Array(template.utf8)
            // Minecraft rejects the entire substitution on a bad specifier or argument index.
            // Validate first so a malformed suffix cannot leave an already-substituted prefix.
            guard let fragments = try fragments(bytes, argumentCount: arguments.count) else {
                try budget.append(template, to: &output)
                return
            }
            for fragment in fragments {
                try budget.visit()
                switch fragment {
                case .literal(let range):
                    try budget.append(String(decoding: bytes[range], as: UTF8.self), to: &output)
                case .argument(let index):
                    switch arguments[index] {
                    case .string(let value): try budget.append(value, to: &output)
                    case .number(let value): try budget.append(number(value), to: &output)
                    case .boolean(let value): try budget.append(value ? "true" : "false", to: &output)
                    case .component(let value):
                        try append(value, translation: translation, depth: depth + 1, output: &output, budget: &budget)
                    }
                }
            }
        }
    }

    private enum Fragment {
        case literal(Range<Int>)
        case argument(Int)
    }

    /// TranslatableContents accepts %% and %s, optionally with a one-based decimal index.
    /// Explicit indices do not advance the sequential argument cursor.
    private static func fragments(_ bytes: [UInt8], argumentCount: Int) throws -> [Fragment]? {
        var result: [Fragment] = [], cursor = 0, literal = 0, sequential = 0
        while cursor < bytes.count {
            guard bytes[cursor] == 37 else { cursor += 1; continue }
            guard result.count < 65_536 else { throw Limit.exceeded }
            if cursor > literal { result.append(.literal(literal..<cursor)) }
            cursor += 1
            guard cursor < bytes.count else { return nil }
            if bytes[cursor] == 37 {
                result.append(.literal(cursor..<(cursor + 1)))
                cursor += 1
            } else {
                var explicit: Int?
                while cursor < bytes.count, (48...57).contains(bytes[cursor]) {
                    let value = (explicit ?? 0) * 10 + Int(bytes[cursor] - 48)
                    guard value <= Int(Int32.max) else { return nil }
                    explicit = value
                    cursor += 1
                }
                if explicit != nil {
                    guard cursor < bytes.count, bytes[cursor] == 36 else { return nil }
                    cursor += 1
                }
                guard cursor < bytes.count, bytes[cursor] == 115 else { return nil }
                let index: Int
                if let explicit { index = explicit - 1 }
                else { index = sequential; sequential += 1 }
                guard (0..<argumentCount).contains(index) else { return nil }
                result.append(.argument(index))
                cursor += 1
            }
            literal = cursor
        }
        if literal < bytes.count { result.append(.literal(literal..<bytes.count)) }
        return result
    }

    /// Java's Double text uses shortest round-trip digits, a two-digit minimum for choosing
    /// tiny scientific values, fixed notation in [1e-3, 1e7), and an uppercase exponent.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value.sign == .minus ? "-Infinity" : "Infinity") }
        let sign = value.sign == .minus ? "-" : ""
        guard value != 0 else { return sign + "0.0" }

        func decimal(_ text: String) -> (digits: String, exponent: Int) {
            let parts = text.lowercased().split(separator: "e")
            let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            var digits = mantissa.joined(), point = mantissa[0].count
            while digits.first == "0" { digits.removeFirst(); point -= 1 }
            while digits.count > 1, digits.last == "0" { digits.removeLast() }
            return (digits, point - 1 + (parts.count == 2 ? Int(parts[1])! : 0))
        }

        var valueText = decimal(String(value.magnitude))
        if valueText.digits.count == 1 {
            // At subnormal magnitudes the nearest two-digit decimal can differ from adding
            // a zero to Swift's one-digit shortest string (5e-324 becomes Java's 4.9E-324).
            // A locale argument routes this through Foundation's decimal formatting and
            // loses that distinction; the C-format path preserves the binary value.
            valueText = decimal(String(format: "%.1e", value.magnitude))
        }
        let (digits, exponent) = valueText
        if (-3..<7).contains(exponent) {
            let point = exponent + 1
            if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
            if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) + ".0" }
            let split = digits.index(digits.startIndex, offsetBy: point)
            return sign + digits[..<split] + "." + digits[split...]
        }
        return sign + digits.prefix(1) + "." + (digits.count == 1 ? "0" : String(digits.dropFirst())) + "E" + String(exponent)
    }
}
