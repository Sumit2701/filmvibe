import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct PhotoItem: Codable, Identifiable, Hashable {
    var id: String
    var date: Date
    var originalFile: String
    var isRAW: Bool
    /// The recipe this photo is currently developed with (edits included).
    var recipe: Recipe
    var captureRecipeName: String
    /// Stops of underexposure applied at capture for DR200 / DR400.
    var captureDRStops: Double
    var postExposure: Double
    var exposureInfo: String?
    var lens: String?
    var renderedAt: Date?
    /// 35mm-equivalent focal length of the full RAW frame (e.g. 26 for the main camera).
    var nativeFocal: Double?
    /// Centre crop applied at development (focal = nativeFocal × crop). nil = full frame.
    var crop: Double?

    var effectiveCrop: Double { max(crop ?? 1, 1) }
    var focalLength: Int? { nativeFocal.map { Int(($0 * effectiveCrop).rounded()) } }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [PhotoItem] = []
    /// Bumped when thumbnails change so views reload them.
    @Published private(set) var revision = 0
    @Published private(set) var rendering: Set<String> = []
    /// Result of the latest Photos save, for a brief on-screen confirmation.
    @Published private(set) var lastSave: SaveResult?

    struct SaveResult: Equatable {
        let id = UUID()
        let ok: Bool
        let message: String
    }

    private let renderQueue = DispatchQueue(label: "fv.library.render", qos: .userInitiated)
    private let thumbCache = NSCache<NSString, UIImage>()

    init() {
        try? FileManager.default.createDirectory(at: AppPaths.library, withIntermediateDirectories: true)
        load()
        discardDevelopedOriginals()
    }

    // MARK: Paths

    nonisolated func dir(_ id: String) -> URL { AppPaths.library.appendingPathComponent(id, isDirectory: true) }
    nonisolated func originalURL(_ item: PhotoItem) -> URL { dir(item.id).appendingPathComponent(item.originalFile) }
    nonisolated func renderURL(_ item: PhotoItem) -> URL { dir(item.id).appendingPathComponent("render.jpg") }
    nonisolated func thumbURL(_ item: PhotoItem) -> URL { dir(item.id).appendingPathComponent("thumb.jpg") }
    nonisolated private func metaURL(_ id: String) -> URL { dir(id).appendingPathComponent("item.json") }
    func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppPaths.library, includingPropertiesForKeys: nil)) ?? []
        var list: [PhotoItem] = []
        let dec = JSONDecoder()
        for d in dirs {
            if let data = try? Data(contentsOf: d.appendingPathComponent("item.json")),
               let item = try? dec.decode(PhotoItem.self, from: data) {
                list.append(item)
            }
        }
        items = list.sorted { $0.date > $1.date }
    }

    // MARK: Add

    /// Stores a new capture / import and develops it in the background.
    /// Whether focal-length crops are upscaled back to full resolution (set from settings).
    var upscaleCrops = true

    @discardableResult
    func add(data: Data, isRAW: Bool, recipe: Recipe, captureDRStops: Double, exposureInfo: String?,
             nativeFocal: Double?, crop: Double?,
             tuning: EngineTuning, saveToPhotos: Bool, includeRAW: Bool) -> PhotoItem {
        let id = Self.makeID()
        let ext = isRAW ? "dng" : (Self.isHEIC(data) ? "heic" : "jpg")
        var item = PhotoItem(id: id, date: Date(), originalFile: "original.\(ext)", isRAW: isRAW, recipe: recipe,
                             captureRecipeName: recipe.name, captureDRStops: captureDRStops, postExposure: 0,
                             exposureInfo: exposureInfo, lens: nil, renderedAt: nil)
        // Prefer the file's own 35mm-equivalent focal length.
        let exif = FilmEngine.metadata(of: data)?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        if let f = exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Double, f > 0 {
            item.nativeFocal = f
        } else {
            item.nativeFocal = nativeFocal
        }
        if let crop, crop > 1.001 { item.crop = crop }
        try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        // The DNG is ~25 MB: write it off the main thread. develop() runs on the same serial queue, so it's on disk first.
        let url = originalURL(item)
        renderQueue.async { try? data.write(to: url) }
        writeMeta(item)
        items.insert(item, at: 0)
        develop(item, tuning: tuning, saveToPhotos: saveToPhotos, includeRAW: includeRAW, discardOriginal: true)
        return item
    }

    func update(_ item: PhotoItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        writeMeta(item)
    }

    func delete(_ item: PhotoItem) {
        try? FileManager.default.removeItem(at: dir(item.id))
        items.removeAll { $0.id == item.id }
        thumbCache.removeObject(forKey: item.id as NSString)
    }

    // MARK: Develop

    /// Renders the full-resolution JPEG + thumbnail for an item; optionally saves to Photos.
    /// `discardOriginal` deletes the RAW / imported original once the JPEG exists (and Photos has it, if saving).
    func develop(_ item: PhotoItem, tuning: EngineTuning, saveToPhotos: Bool = false, includeRAW: Bool = false,
                 discardOriginal: Bool = false, completion: ((URL?) -> Void)? = nil) {
        rendering.insert(item.id)
        let originalURL = originalURL(item), renderURL = renderURL(item), thumbURL = thumbURL(item)
        let framing = Framing(crop: item.effectiveCrop, upscale: upscaleCrops)
        renderQueue.async {
            var ok = false
            autoreleasepool {
                guard let session = DevelopSession(url: originalURL, captureDRStops: item.captureDRStops),
                      let image = session.render(recipe: item.recipe, tuning: tuning, postExposure: item.postExposure,
                                                 longEdge: nil, framing: framing)
                else { return }
                var metadata = FilmEngine.metadata(of: session.data)
                if let f = item.focalLength, metadata != nil {
                    var exif = metadata?[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                    exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = f
                    if framing.crop > 1.001 {
                        exif[kCGImagePropertyExifDigitalZoomRatio as String] = framing.crop
                    }
                    metadata?[kCGImagePropertyExifDictionary as String] = exif
                }
                guard let jpeg = FilmEngine.shared.jpegData(image, metadata: metadata) else { return }
                try? jpeg.write(to: renderURL, options: .atomic)
                if let thumb = Self.makeThumbnail(jpeg, maxPixel: 480) {
                    try? thumb.write(to: thumbURL, options: .atomic)
                }
                ok = true
            }
            DispatchQueue.main.async {
                var updated = item
                if ok {
                    updated.renderedAt = Date()
                    self.thumbCache.removeObject(forKey: item.id as NSString)
                    if self.items.contains(where: { $0.id == item.id }) { self.update(updated) }
                    self.revision &+= 1
                }
                self.rendering.remove(item.id)
                if !ok { print("[FilmVibe] develop failed for \(item.id)") }
                if ok && saveToPhotos {
                    PhotoSaver.save(jpegURL: renderURL, rawURL: includeRAW && item.isRAW ? originalURL : nil) { err in
                        self.lastSave = SaveResult(ok: err == nil, message: err ?? "Saved to Photos")
                        if discardOriginal { self.removeFile(originalURL) }
                        completion?(err == nil ? renderURL : nil)
                    }
                } else {
                    if ok && discardOriginal { self.removeFile(originalURL) }
                    completion?(ok ? renderURL : nil)
                }
            }
        }
    }

    /// Deletes originals left over from photos that already have their developed JPEG.
    private func discardDevelopedOriginals() {
        let pairs = items.map { (originalURL($0), renderURL($0)) }
        renderQueue.async {
            let fm = FileManager.default
            for (original, render) in pairs where fm.fileExists(atPath: render.path) {
                try? fm.removeItem(at: original)
            }
        }
    }

    /// Runs on the render queue so it never races a develop that's still reading the file.
    private func removeFile(_ url: URL) {
        renderQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Thumbnails

    func thumbnail(_ item: PhotoItem) -> UIImage? {
        if let img = thumbCache.object(forKey: item.id as NSString) { return img }
        guard let img = UIImage(contentsOfFile: thumbURL(item).path) else { return nil }
        thumbCache.setObject(img, forKey: item.id as NSString)
        return img
    }

    nonisolated static func makeThumbnail(_ data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    // MARK: Helpers

    private func writeMeta(_ item: PhotoItem) {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(item) { try? data.write(to: metaURL(item.id), options: .atomic) }
    }

    private static func makeID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "FV-" + f.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4))
    }

    static func isHEIC(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) else { return false }
        return (type as String) == UTType.heic.identifier || (type as String) == UTType.heif.identifier
    }
}

// MARK: - Photos

enum PhotoSaver {
    /// Asks for add-only Photos access up front so the prompt never interrupts a shot.
    static func requestAccess() {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                print("[FilmVibe] Photos add-only access: \(status.rawValue)")
            }
        }
    }

    static var isDenied: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return s == .denied || s == .restricted
    }

    /// Saves the developed JPEG (optionally with the DNG attached as RAW+JPEG). Completion: nil on success, else an error message.
    static func save(jpegURL: URL, rawURL: URL?, completion: @escaping (String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                print("[FilmVibe] Photos save skipped, access status \(status.rawValue)")
                DispatchQueue.main.async { completion("Allow FilmVibe to add photos in Settings → Privacy → Photos") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.uniformTypeIdentifier = UTType.jpeg.identifier
                req.addResource(with: .photo, fileURL: jpegURL, options: opts)
                if let rawURL {
                    let rawOpts = PHAssetResourceCreationOptions()
                    rawOpts.uniformTypeIdentifier = "com.adobe.raw-image"
                    req.addResource(with: .alternatePhoto, fileURL: rawURL, options: rawOpts)
                }
            }, completionHandler: { ok, error in
                print("[FilmVibe] Photos save \(ok ? "OK" : "FAILED"): \(error?.localizedDescription ?? "")")
                DispatchQueue.main.async { completion(ok ? nil : (error?.localizedDescription ?? "Could not save to Photos")) }
            })
        }
    }
}
