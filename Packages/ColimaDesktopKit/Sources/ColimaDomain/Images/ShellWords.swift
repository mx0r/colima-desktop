import Foundation

/// Splits a command line into arguments like a POSIX shell does, without any expansion:
/// whitespace separates words, single quotes keep everything literally, double quotes allow
/// `\"`, `\\`, `\$` and `` \` `` escapes, and a backslash outside quotes escapes the next character.
public enum ShellWords {
    /// Why a command line could not be split.
    public enum SplitError: Error, Hashable, Sendable, LocalizedError {
        case unclosedQuote(Character)
        case trailingBackslash

        public var errorDescription: String? {
            switch self {
            case .unclosedQuote(let quote): "A \(quote) quote is not closed."
            case .trailingBackslash: "The command ends with a backslash."
            }
        }
    }

    /// The words of a command line.
    public static func split(_ text: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            switch character {
            case " ", "\t", "\n":
                if inWord { words.append(word) }
                word = ""
                inWord = false
            case "'":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "'" { closed = true; break }
                    word.append(next)
                }
                if !closed { throw SplitError.unclosedQuote("'") }
            case "\"":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "\"" { closed = true; break }
                    if next == "\\" {
                        guard let escaped = iterator.next() else { break }
                        if !["\"", "\\", "$", "`"].contains(escaped) { word.append("\\") }
                        word.append(escaped)
                    } else {
                        word.append(next)
                    }
                }
                if !closed { throw SplitError.unclosedQuote("\"") }
            case "\\":
                guard let escaped = iterator.next() else { throw SplitError.trailingBackslash }
                inWord = true
                word.append(escaped)
            default:
                inWord = true
                word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }
}
