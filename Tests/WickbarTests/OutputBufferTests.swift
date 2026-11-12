import XCTest
@testable import WickbarCore

final class OutputBufferTests: XCTestCase {
    func testAppendAndSnapshot() {
        let b = OutputBuffer(capacity: 4096)
        b.append("hello ")
        b.append(Array("world".utf8))
        XCTAssertEqual(String(decoding: b.snapshot(), as: UTF8.self), "hello world")
        XCTAssertFalse(b.endsWithNewline)
        b.append("\r\n")
        XCTAssertTrue(b.endsWithNewline)
    }

    func testTrimsFromFrontAtLineBoundary() {
        let cap = 4096
        let b = OutputBuffer(capacity: cap)
        for i in 0..<2000 { b.append("line \(i)\r\n") }
        XCTAssertLessThanOrEqual(b.count, cap + cap / 4)
        let text = String(decoding: b.snapshot(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("line "), "buffer should start at a line boundary, got: \(text.prefix(20))")
        XCTAssertTrue(text.hasSuffix("line 1999\r\n"))
        XCTAssertFalse(text.contains("line 0\r\n"))
    }

    func testAttachReplaysThenStreams() {
        let b = OutputBuffer()
        b.append("before\n")
        var received = Data()
        let token = b.attach { received.append(contentsOf: $0) }
        b.append("after\n")
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "before\nafter\n")
        b.detach(token)
        b.append("ignored\n")
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "before\nafter\n")
    }

    func testSeparatorStartsOnFreshLineAndIsDim() {
        let b = OutputBuffer()
        b.append("partial")
        b.appendSeparator("started 12:01:03")
        let raw = String(decoding: b.snapshot(), as: UTF8.self)
        XCTAssertTrue(raw.contains("\u{1B}[2m── started 12:01:03 ──"))
        XCTAssertEqual(ANSIText.lines(b.snapshot()), ["partial", "── started 12:01:03 ──"])
    }

    func testClear() {
        let b = OutputBuffer()
        b.append("x\n")
        b.clear()
        XCTAssertEqual(b.count, 0)
    }
}

final class ANSITextTests: XCTestCase {
    func testStripsSGRColors() {
        XCTAssertEqual(ANSIText.stripEscapes("\u{1B}[1;31mred\u{1B}[0m plain \u{1B}[38;2;255;0;0mtrue\u{1B}[m"), "red plain true")
    }

    func testStripsOSCWithBELAndST() {
        XCTAssertEqual(ANSIText.stripEscapes("\u{1B}]0;title\u{07}a\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\b"), "alinkb")
    }

    func testStripsCharsetAndPrivateModes() {
        XCTAssertEqual(ANSIText.stripEscapes("\u{1B}(Bx\u{1B}[?25ly\u{1B}[?1049hz\u{1B}=\u{1B}>"), "xyz")
    }

    func testStripsDCS() {
        XCTAssertEqual(ANSIText.stripEscapes("a\u{1B}Pq#0;2;0;0;0\u{1B}\\b"), "ab")
    }

    func testCarriageReturnKeepsTextAfterLastCR() {
        let text = "Downloading 10%\rDownloading 50%\rDownloading 100%\r\nnext line\r\n"
        XCTAssertEqual(ANSIText.lines(text), ["Downloading 100%", "next line"])
    }

    func testCRLFLineEndings() {
        XCTAssertEqual(ANSIText.lines("a\r\nb\r\n\r\nc"), ["a", "b", "", "c"])
    }

    func testBackspace() {
        XCTAssertEqual(ANSIText.lines("abc\u{8}\u{8}X\n"), ["aX"])
    }

    func testDropsOtherControlCharacters() {
        XCTAssertEqual(ANSIText.lines("a\u{07}b\u{00}c\n"), ["abc"])
    }

    func testLastLines() {
        var bytes: [UInt8] = []
        for i in 1...10 { bytes += Array("\u{1B}[32m\(i)\u{1B}[0m\r\n".utf8) }
        XCTAssertEqual(ANSIText.lastLines(bytes, count: 3), "8\n9\n10")
        XCTAssertEqual(ANSIText.lastLines(bytes, count: 100).split(separator: "\n").count, 10)
        XCTAssertEqual(ANSIText.lastLines([], count: 5), "")
    }

    func testInvalidUTF8DoesNotCrash() {
        let bytes: [UInt8] = [0x66, 0xFF, 0xFE, 0x6F, 0x0A]
        XCTAssertEqual(ANSIText.lines(bytes).count, 1)
    }

    func testPlainTextTail() {
        let b = OutputBuffer()
        b.append("\u{1B}[1mone\u{1B}[0m\r\ntwo\r\nthree\r\n")
        XCTAssertEqual(b.plainTextTail(lines: 2), "two\nthree")
    }
}
