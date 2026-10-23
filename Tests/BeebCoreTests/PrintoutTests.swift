// Laying out print jobs, and their PDFs.

import Foundation
import AppKit
import PDFKit
import Testing
import BeebPrint
import BeebROMs

struct PrintoutTests {
    let font = Array(BeebROMs.data(.os12)[0..<768])

    @Test func linesPagesAndTabs() {
        var bytes = Array("HELLO\rWORLD\r".utf8)
        bytes += [9] + Array("TABBED\r".utf8)
        bytes += [12] + Array("PAGE TWO\r\n".utf8)
        let printout = Printout(bytes)
        #expect(printout.pageCount == 2)
        #expect(printout.text(page: 0) == "HELLO\nWORLD\n        TABBED")
        #expect(printout.text(page: 1) == "PAGE TWO")
    }

    /// 66 lines make a page, whatever the paper.
    @Test func longJobsMakePages() {
        let bytes = (1...140).flatMap { Array("LINE \($0)\r".utf8) }
        let printout = Printout(bytes)
        #expect(printout.pageCount == 3)
        #expect(printout.text(page: 2).hasPrefix("LINE 133"))
    }

    @Test func epsonBoldAndUnknownCodes() {
        let bytes: [UInt8] = [27, 69] + Array("BOLD".utf8) + [27, 70, 27, 0x47, 7] + Array(" PLAIN\r".utf8)
        let printout = Printout(bytes)
        #expect(printout.pages[0][0][0]?.bold == true)
        #expect(printout.pages[0][0][5]?.bold == false)
        #expect(printout.unsupported["ESC 'G'"] == 1)
        #expect(printout.unsupported["&07"] == 1)
        #expect(printout.text(page: 0) == "BOLD PLAIN")
    }

    /// Without auto line feed, CR returns and LF feeds.
    @Test func lineFeedsWithoutAutoLineFeed() {
        var settings = PrintSettings()
        settings.autoLineFeed = false
        let printout = Printout(Array("ABC\rX\n\rNEXT".utf8), settings: settings)
        #expect(printout.text(page: 0) == "XBC\nNEXT")
    }

    @Test(arguments: PrintSettings.Style.allCases)
    func pdfHasThePagesAndTheText(style: PrintSettings.Style) throws {
        var settings = PrintSettings()
        settings.style = style
        let bytes = Array("HELLO FROM ECONET\r".utf8) + [12] + Array("SECOND PAGE\r".utf8)
        let data = Printout(bytes, settings: settings).pdf(font: font, title: "Test")
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("HELLO FROM ECONET") == true, "\(document.page(at: 0)?.string ?? "")")
        #expect(document.page(at: 1)?.string?.contains("SECOND PAGE") == true)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == PrintSettings.Paper.a4.size)
    }

    @Test func spoolerSplitsJobsWhenThePrinterGoesQuiet() {
        var jobs: [PrintJob] = []
        let spooler = PrintSpooler(printer: "Test", quietCycles: 1000) { job in
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
        }
        for (i, byte) in Array("FIRST\r".utf8).enumerated() { spooler.receive(byte, at: UInt64(i * 10)) }
        spooler.idle(at: 5000)
        for (i, byte) in Array("SECOND\r".utf8).enumerated() { spooler.receive(byte, at: UInt64(6000 + i * 10)) }
        spooler.machineStopped()
        #expect(jobs.count == 2)
        #expect(jobs[0].bytes == Array("FIRST\r".utf8) && jobs[0].status == .finished)
        #expect(jobs[1].bytes == Array("SECOND\r".utf8) && jobs[1].status == .interrupted)
        #expect(jobs[0].cycles.last == 50)
    }
}

struct PrintoutPictures {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINT_PICTURES"] != nil))
    func pictures() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PRINT_PICTURES"]!)
        let font = Array(BeebROMs.data(.os12)[0..<768])
        var bytes = Array("MacBeeb printer server: job from station 1\r\r".utf8)
        bytes += [27, 69] + Array("10 REM Bold listing heading".utf8) + [27, 70, 13]
        for line in ["20 FOR I%=1 TO 10", "30 PRINT \"HELLO FROM ECONET \";I%", "40 NEXT", "50 END"] { bytes += Array((line + "\r").utf8) }
        for style in PrintSettings.Style.allCases {
            for paper in [PrintSettings.Paper.a4, .fanfold] {
                var settings = PrintSettings()
                settings.style = style
                settings.paper = paper
                let image = try #require(Printout(bytes, settings: settings).image(page: 0, scale: 2, font: font))
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("print-\(style.rawValue)-\(paper.rawValue).png"))
            }
        }
    }
}
