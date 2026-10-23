import Foundation

/// The Distributed Mandelbrot's guest programs (Examples/distributed-mandelbrot):
/// 6502 machine code that runs on the network's BBCs, put on the file server
/// for them to load. The bytes are in MandelbrotGuestFiles.swift.
public enum MandelbrotGuest {
    public struct File: Sendable, Equatable {
        public var name: String
        public var loadAddress: UInt32
        public var executionAddress: UInt32
        public var contents: [UInt8]

        public init(name: String, loadAddress: UInt32, executionAddress: UInt32, contents: [UInt8]) {
            self.name = name
            self.loadAddress = loadAddress
            self.executionAddress = executionAddress
            self.contents = contents
        }

        init(name: String, loadAddress: UInt32, executionAddress: UInt32, base64: String) {
            self.init(name: name, loadAddress: loadAddress, executionAddress: executionAddress,
                      contents: [UInt8](Data(base64Encoded: base64) ?? Data()))
        }
    }
}
