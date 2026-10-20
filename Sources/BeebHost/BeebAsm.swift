// Runs BeebAsm (github.com/stardot/beebasm; built into MacBeeb.app) to
// assemble a source file to a disc image, with symbols and source lines for
// the debugger.

import BeebCore
import Foundation

public struct BeebAsmBuild: Sendable {
    /// A DFS disc (.ssd) of the files the source SAVEs.
    public var disc: [UInt8]
    /// The files SAVEd, in order.
    public var savedFiles: [String]
    public var symbols: SymbolTable
    /// BeebAsm's messages (PRINT output, warnings).
    public var messages: String
}

public enum BeebAsm {
    public enum BuildError: Error, CustomStringConvertible {
        case notFound
        case failed(String)
        case nothingSaved

        public var description: String {
            switch self {
            case .notFound:
                "BeebAsm isn't installed: it comes with MacBeeb.app, or build it from github.com/stardot/beebasm and put it on your PATH"
            case .failed(let output):
                "BeebAsm failed:\n" + output
            case .nothingSaved:
                "the source doesn't SAVE anything (add SAVE \"NAME\", start, end)"
            }
        }
    }

    /// The beebasm to use: `configured`, or the one beside this program
    /// (in MacBeeb.app), or on the PATH.
    public static func locate(_ configured: String? = nil) -> String? {
        let fm = FileManager.default
        if let configured, fm.isExecutableFile(atPath: configured) {
            return configured
        }
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "beebasm") {
            candidates.append(bundled.path)
        }
        let here = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        candidates.append((here as NSString).appendingPathComponent("beebasm"))
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/beebasm" }
        candidates += ["/opt/homebrew/bin/beebasm", "/usr/local/bin/beebasm"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Assembles `source` (in its own directory, so INCLUDE and INCBIN
    /// paths work) to a disc image.
    public static func assemble(source: String, beebasm configured: String? = nil) throws(BuildError) -> BeebAsmBuild {
        guard let beebasm = locate(configured) else { throw .notFound }
        let source = (source as NSString).standardizingPath
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-beebasm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let disc = temporary.appendingPathComponent("out.ssd").path
        let labels = temporary.appendingPathComponent("labels.txt").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: beebasm)
        process.arguments = ["-i", source, "-do", disc, "-v", "-dd", "-labels", labels]
        process.currentDirectoryURL = URL(fileURLWithPath: (source as NSString).deletingLastPathComponent)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw .failed("couldn't run \(beebasm): \(error)")
        }
        // Read before waiting, so a big listing can't fill the pipe.
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw .failed((err + out.split(separator: "\n").filter { !$0.hasPrefix(" ") && !$0.hasPrefix(".") }.joined(separator: "\n"))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let saved = out.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("Saving file '"), let end = line.lastIndex(of: "'") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 13)..<end])
        }
        guard !saved.isEmpty, let image = FileManager.default.contents(atPath: disc) else { throw .nothingSaved }
        let dump = try? String(contentsOfFile: labels, encoding: .utf8)
        let symbols = SymbolTable.beebAsm(listing: out, symbols: dump, source: source)
        // Everything that isn't the listing.
        let messages = out.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            !(line.hasPrefix(" ") || line.hasPrefix(".") || line.hasPrefix("Macro ") || line.hasPrefix("End macro")
              || line.hasPrefix("Saving file") || line.hasPrefix("Processed file") || line.hasPrefix("Including file") || line.isEmpty)
        }.joined(separator: "\n")
        return BeebAsmBuild(disc: [UInt8](image), savedFiles: saved, symbols: symbols,
                            messages: (err + messages).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
