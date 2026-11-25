import Foundation

/// What the Command Bar understands, as Muna on Linux (linux/src/commandbar/engine.js):
/// arithmetic, unit conversion, and how well a name matches what was typed.
public enum CommandEngine {
    // --- the calculator ------------------------------------------------------------------------

    /// The value of an expression like "12*(3+4)", "2^10", "sqrt(2)", "15%4"; nil when it is not one
    /// (a bare number is not a calculation).
    public static func calculate(_ text: String) -> Double? {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        source = source.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".")
        // "x" between numbers is a multiplication
        source = source.replacingOccurrences(of: #"x(?=\s*[\d(])"#, with: "*", options: .regularExpression)
        source = source.components(separatedBy: .whitespaces).joined()
        guard !source.isEmpty, source.rangeOfCharacter(from: .decimalDigits) != nil,
              source.range(of: #"^[\d+\-*/^%().a-z]+$"#, options: .regularExpression) != nil else { return nil }
        var tokens: [String] = []
        var rest = Substring(source)
        let patterns = [#"^\d+\.?\d*"#, #"^\.\d+"#, #"^[a-z]+"#, #"^[+\-*/^%()]"#]
        while !rest.isEmpty {
            var matched = false
            for pattern in patterns {
                if let range = rest.range(of: pattern, options: .regularExpression) {
                    tokens.append(String(rest[range]))
                    rest = rest[range.upperBound...]
                    matched = true
                    break
                }
            }
            if !matched { return nil }
        }
        if tokens.count == 1, Double(tokens[0]) != nil { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.index == tokens.count, value.isFinite else { return nil }
        return value
    }

    private struct Parser {
        let tokens: [String]
        var index = 0

        static let functions: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "abs": { Swift.abs($0) }, "round": { Foundation.round($0) },
            "floor": { Foundation.floor($0) }, "ceil": { Foundation.ceil($0) },
            "sin": { Foundation.sin($0) }, "cos": { Foundation.cos($0) }, "tan": { Foundation.tan($0) },
            "ln": { Foundation.log($0) }, "log": { Foundation.log10($0) },
        ]
        static let constants: [String: Double] = ["pi": Double.pi, "e": M_E]

        init(tokens: [String]) { self.tokens = tokens }

        private var current: String? { index < tokens.count ? tokens[index] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = current, op == "+" || op == "-" {
                index += 1
                guard let right = term() else { return nil }
                value = op == "+" ? value + right : value - right
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = current, op == "*" || op == "/" || op == "%" {
                index += 1
                guard let right = power() else { return nil }
                value = op == "*" ? value * right : op == "/" ? value / right : value.truncatingRemainder(dividingBy: right)
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if current == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return Foundation.pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if current == "-" {
                index += 1
                return unary().map { -$0 }
            }
            if current == "+" {
                index += 1
                return unary()
            }
            return atom()
        }

        mutating func atom() -> Double? {
            guard let token = current else { return nil }
            index += 1
            if let number = Double(token) { return number }
            if token == "(" {
                guard let value = expression(), current == ")" else { return nil }
                index += 1
                return value
            }
            if let constant = Self.constants[token] { return constant }
            if let function = Self.functions[token] {
                guard current == "(" else { return nil }
                index += 1
                guard let value = expression(), current == ")" else { return nil }
                index += 1
                return function(value)
            }
            return nil
        }
    }

    /// A number as people write it: up to 12 significant digits, no trailing ".0".
    public static func format(_ value: Double) -> String {
        let rounded = Double(String(format: "%.12g", value)) ?? value
        if rounded == rounded.rounded(), Swift.abs(rounded) < 1e15 {
            return String(Int64(rounded))
        }
        return String(format: "%.12g", rounded)
    }

    // --- units ------------------------------------------------------------------------------------

    private static let units: [[String: Double]] = [
        ["m": 1, "km": 1000, "cm": 0.01, "mm": 0.001, "mi": 1609.344, "mile": 1609.344, "miles": 1609.344, "yd": 0.9144,
         "ft": 0.3048, "foot": 0.3048, "feet": 0.3048, "in": 0.0254, "inch": 0.0254, "inches": 0.0254],
        ["kg": 1, "g": 0.001, "mg": 0.000001, "t": 1000, "lb": 0.45359237, "lbs": 0.45359237, "oz": 0.028349523125],
        ["l": 1, "ml": 0.001, "gal": 3.785411784, "cup": 0.2365882365, "floz": 0.0295735295625],
        ["s": 1, "sec": 1, "min": 60, "h": 3600, "hr": 3600, "d": 86400, "day": 86400, "days": 86400, "week": 604800, "weeks": 604800],
        ["b": 1, "kb": 1024, "mb": 1_048_576, "gb": 1_073_741_824, "tb": 1_099_511_627_776],
        ["m/s": 1, "km/h": 1 / 3.6, "kmh": 1 / 3.6, "mph": 0.44704, "kn": 0.514444],
    ]

    private static let temperature: [String: String] = [
        "c": "c", "°c": "c", "celsius": "c", "f": "f", "°f": "f", "fahrenheit": "f", "k": "k", "kelvin": "k",
    ]

    /// "5 km to mi" → (3.10686, "5 km = 3.106856 mi"); nil when it is not a conversion.
    public static func convert(_ text: String) -> (value: Double, text: String)? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ",", with: ".")
        let pattern = #"^(-?\d+\.?\d*)\s*([a-z°/]+)\s*(?:to|in|into|=|->|→)\s*([a-z°/]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let valueRange = Range(match.range(at: 1), in: source),
              let fromRange = Range(match.range(at: 2), in: source),
              let toRange = Range(match.range(at: 3), in: source),
              let value = Double(source[valueRange]) else { return nil }
        let from = String(source[fromRange])
        let to = String(source[toRange])
        if let a = temperature[from], let b = temperature[to] {
            let celsius = a == "c" ? value : a == "f" ? (value - 32) * 5 / 9 : value - 273.15
            let result = b == "c" ? celsius : b == "f" ? celsius * 9 / 5 + 32 : celsius + 273.15
            return (result, "\(format(value)) \(from) = \(format((result * 1000).rounded() / 1000)) \(to)")
        }
        for table in units {
            if let a = table[from], let b = table[to] {
                let result = value * a / b
                return (result, "\(format(value)) \(from) = \(format((result * 1e6).rounded() / 1e6)) \(to)")
            }
        }
        return nil
    }

    // --- matching names ------------------------------------------------------------------------

    /// How well `query` matches `name` (0: not at all): the whole name, then a prefix, a word start,
    /// a substring, the letters in order close together.
    public static func matchScore(_ name: String, _ query: String) -> Int {
        let n = name.lowercased()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if n == q { return 100 }
        if n.hasPrefix(q) { return 80 }
        let words = n.split(whereSeparator: { " -_.".contains($0) })
        if words.contains(where: { $0.hasPrefix(q) }) { return 60 }
        if n.contains(q) { return 40 }
        guard q.count >= 3 else { return 0 }
        let letters = Array(n)
        var at = 0
        var first = -1
        for ch in q {
            guard let found = letters[at...].firstIndex(of: ch) else { return 0 }
            if first < 0 { first = found }
            at = found + 1
            if at > letters.count { return 0 }
        }
        return at - first <= q.count + 1 ? 20 : 0
    }
}
