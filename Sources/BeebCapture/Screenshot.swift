import BeebCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Screenshot {
    /// The TV's last complete frame as an image, at native resolution
    /// (736x576, each scanline doubled).
    public static func image(_ tv: TVOutput) -> CGImage? {
        let width = TVOutput.width, height = TVOutput.height
        let data = tv.lastFrame.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG data for the TV's last complete frame.
    public static func png(_ tv: TVOutput) -> Data? {
        guard let image = image(tv) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func writePNG(_ tv: TVOutput, to url: URL) throws {
        guard let data = png(tv) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
