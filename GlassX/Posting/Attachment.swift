import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// An image, GIF or video attached to a post, already in a format X accepts.
struct PostAttachment: Identifiable, Equatable, Sendable {
    let id = UUID()
    var data: Data
    var mimeType: String
    var category: XClient.MediaCategory
    var preview: NSImage?

    var isVideoLike: Bool { category != .image }
    var fileExtension: String {
        switch mimeType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        default: "jpg"
        }
    }

    static func == (lhs: PostAttachment, rhs: PostAttachment) -> Bool { lhs.id == rhs.id }

    enum Failure: LocalizedError {
        case unsupported, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsupported: "That file type can't be posted. Use a photo, GIF or MP4/MOV video."
            case .tooLarge: "That video is over X's 512 MB limit."
            }
        }
    }

    static let maxImageBytes = 5 << 20

    static func load(from url: URL) throws -> PostAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if type.conforms(to: .gif) { return gif(data) }
        if type.conforms(to: .image) { return try image(data) }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            guard data.count <= 512 << 20 else { throw Failure.tooLarge }
            return PostAttachment(data: data, mimeType: type.conforms(to: .quickTimeMovie) ? "video/quicktime" : "video/mp4",
                                  category: .video, preview: videoThumbnail(url))
        }
        throw Failure.unsupported
    }

    static func gif(_ data: Data) -> PostAttachment {
        PostAttachment(data: data, mimeType: "image/gif", category: .gif, preview: NSImage(data: data))
    }

    /// Keeps JPEG/PNG/WebP under 5 MB as-is; converts anything else (HEIC, TIFF, huge PNGs) to JPEG.
    static func image(_ data: Data) throws -> PostAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeID = CGImageSourceGetType(source) as String?
        else { throw Failure.unsupported }
        let preview = NSImage(data: data)
        let passthrough: [String: String] = [UTType.jpeg.identifier: "image/jpeg", UTType.png.identifier: "image/png", UTType.webP.identifier: "image/webp"]
        if let mime = passthrough[typeID], data.count <= maxImageBytes {
            return PostAttachment(data: data, mimeType: mime, category: .image, preview: preview)
        }
        var maxPixel = 4096
        var quality = 0.88
        while true {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unsupported }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.unsupported }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            CGImageDestinationFinalize(destination)
            if output.length <= maxImageBytes || maxPixel <= 1024 {
                return PostAttachment(data: output as Data, mimeType: "image/jpeg", category: .image, preview: preview)
            }
            maxPixel = Int(Double(maxPixel) * 0.8)
            quality = max(0.7, quality - 0.05)
        }
    }

    /// Images, GIFs or media files on the pasteboard (screenshots, copied images, copied files).
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> [PostAttachment]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let attachments = urls.compactMap { try? load(from: $0) }
            return attachments.isEmpty ? nil : attachments
        }
        if let gifData = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) { return [gif(gifData)] }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)] {
            if let data = pasteboard.data(forType: type), let attachment = try? image(data) { return [attachment] }
        }
        return nil
    }

    private static func videoThumbnail(_ url: URL) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
