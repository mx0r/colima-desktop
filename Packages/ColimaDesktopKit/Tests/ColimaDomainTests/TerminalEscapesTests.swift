import Testing
@testable import ColimaDomain

@Suite("Terminal escapes")
struct TerminalEscapesTests {
    @Test("Color codes are removed, as in RabbitMQ's colored log lines")
    func colors() {
        let line = "\u{1B}[38;5;214m2026-10-06 06:49:19.482484+00:00 [warning] <0.895.0> By default, this feature can still be used for now.\u{1B}[0m"
        #expect(TerminalEscapes.strip(line) == "2026-10-06 06:49:19.482484+00:00 [warning] <0.895.0> By default, this feature can still be used for now.")
        #expect(TerminalEscapes.strip("\u{1B}[1;31mERROR\u{1B}[0m: boom \u{1B}[2K\u{1B}[1A") == "ERROR: boom ")
    }

    @Test("Other sequences go too: window titles, character sets, the 8-bit CSI, bells")
    func others() {
        #expect(TerminalEscapes.strip("\u{1B}]0;my title\u{07}text") == "text")
        #expect(TerminalEscapes.strip("\u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
        #expect(TerminalEscapes.strip("\u{1B}(Bplain\u{1B}=") == "plain")
        #expect(TerminalEscapes.strip("\u{9B}32mgreen\u{9B}0m") == "green")
        #expect(TerminalEscapes.strip("ding\u{07}") == "ding")
    }

    @Test("Text without escapes is kept, including brackets that only look like codes")
    func untouched() {
        #expect(TerminalEscapes.strip("GET /api 200 [0m] ok") == "GET /api 200 [0m] ok")
        #expect(TerminalEscapes.strip("tab\there, ünïcödé ✓") == "tab\there, ünïcödé ✓")
        #expect(TerminalEscapes.strip("") == "")
    }

    @Test("A cut-off sequence at the end of a line is dropped")
    func truncated() {
        #expect(TerminalEscapes.strip("done\u{1B}") == "done")
        #expect(TerminalEscapes.strip("done\u{1B}[38;5") == "done")
        #expect(TerminalEscapes.strip("done\u{1B}]0;title") == "done")
    }
}
