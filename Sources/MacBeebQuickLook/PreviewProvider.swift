import BeebCore
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Previews a disc image as its catalogue (DiscPreview's page).
@objc(MacBeebPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let image = [UInt8](try Data(contentsOf: url))
        let html = DiscPreview.html(image: image, fileName: url.lastPathComponent)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 640, height: 640)) { _ in
            Data(html.utf8)
        }
    }
}
