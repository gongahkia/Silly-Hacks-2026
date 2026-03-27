import Foundation

public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        splitLines(in: text)
            .map(normalizeLine(_:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func normalizeLine(_ line: String) -> String {
        let folded = line.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )

        let collapsedWhitespace = folded.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func splitLines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func tokens(in text: String) -> [String] {
        let scalars = normalize(text).unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }

        return String(scalars)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
