import Foundation

/// Removes terminal escape sequences from text. Programs that color their output (RabbitMQ, many
/// CLIs) write these into their logs; a log table cannot show the invisible ESC, so without this the
/// user sees `[38;5;214m` and `[0m`.
public enum TerminalEscapes {
    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let bell: Unicode.Scalar = "\u{07}"
    /// The 8-bit form of `ESC [`.
    private static let controlSequenceIntroducer: Unicode.Scalar = "\u{9B}"

    /// The text without escape sequences: CSI (colors, cursor moves), OSC (titles, links) ended by
    /// BEL or `ESC \`, the short `ESC` sequences (character sets, modes), and bells. A sequence cut
    /// off at the end of the text is dropped. Text without ESC, CSI or BEL is returned unchanged.
    public static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0 == escape || $0 == controlSequenceIntroducer || $0 == bell }) else { return text }
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case escape:
                guard index < scalars.count else { break }
                let next = scalars[index]
                index += 1
                switch next {
                case "[": skipControlSequence(scalars, &index)
                case "]": skipOperatingSystemCommand(scalars, &index)
                default:
                    // ESC, intermediate bytes (space to /), one final byte (0 to ~).
                    var final = next
                    while (0x20...0x2F).contains(final.value), index < scalars.count {
                        final = scalars[index]
                        index += 1
                    }
                }
            case controlSequenceIntroducer:
                skipControlSequence(scalars, &index)
            case bell:
                break
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// After `ESC [`: parameter bytes (0 to ?), intermediate bytes (space to /), one final byte (@ to ~).
    private static func skipControlSequence(_ scalars: [Unicode.Scalar], _ index: inout Int) {
        while index < scalars.count, (0x30...0x3F).contains(scalars[index].value) { index += 1 }
        while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
        if index < scalars.count, (0x40...0x7E).contains(scalars[index].value) { index += 1 }
    }

    /// After `ESC ]`: everything up to BEL or `ESC \`.
    private static func skipOperatingSystemCommand(_ scalars: [Unicode.Scalar], _ index: inout Int) {
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == bell { return }
            if scalar == escape, index < scalars.count, scalars[index] == "\\" {
                index += 1
                return
            }
        }
    }
}
