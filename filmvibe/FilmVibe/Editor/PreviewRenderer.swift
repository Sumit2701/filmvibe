import CoreImage
import CryptoKit
import UIKit

/// Renders one photo with changing recipes off the main thread. Requests that arrive while
/// a render is running are coalesced so only the latest one is drawn.
final class PreviewRenderer {
    struct Job {
        var recipe: Recipe
        var tuning: EngineTuning
        var postExposure: Double
        var longEdge: CGFloat
        var framing: Framing = .full
        var completion: (UIImage?) -> Void
    }

    private let queue = DispatchQueue(label: "fv.preview.render", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Job?
    private var running = false
    private var session: DevelopSession?   // queue-confined

    func load(url: URL, captureDRStops: Double, completion: @escaping (Bool, Bool) -> Void) {
        queue.async {
            self.session = DevelopSession(url: url, captureDRStops: captureDRStops)
            let ok = self.session != nil
            let raw = self.session?.isRAW ?? false
            DispatchQueue.main.async { completion(ok, raw) }
        }
    }

    func request(_ job: Job) {
        lock.lock()
        pending = job
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func renderStandard(longEdge: CGFloat, framing: Framing = .full, completion: @escaping (UIImage?) -> Void) {
        queue.async {
            let img = autoreleasepool { () -> UIImage? in
                guard let ci = self.session?.renderStandard(longEdge: longEdge, framing: framing),
                      let cg = FilmEngine.shared.cgImage(ci) else { return nil }
                return UIImage(cgImage: cg)
            }
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// Diagnostics for calibration (as-shot white balance, RAW headroom).
    func diagnostics(completion: @escaping (String) -> Void) {
        queue.async {
            guard let s = self.session else { return }
            var parts: [String] = []
            let size = s.nativeSize
            parts.append("\(Int(size.width))×\(Int(size.height))")
            parts.append(s.isRAW ? "RAW" : "Processed")
            if let r = CIRAWFilter(imageData: s.data, identifierHint: nil) {
                parts.append(String(format: "As-shot %.0fK tint %.0f", r.neutralTemperature, r.neutralTint))
                parts.append(String(format: "Baseline %.2f EV", r.baselineExposure))
                parts.append(String(format: "NR L%.2f C%.2f", r.luminanceNoiseReductionAmount, r.colorNoiseReductionAmount))
            }
            if let m = s.measuredRAWMax() { parts.append(String(format: "Max linear %.2f", m)) }
            let text = parts.joined(separator: " · ")
            DispatchQueue.main.async { completion(text) }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let img = autoreleasepool { () -> UIImage? in
                guard let ci = session?.render(recipe: job.recipe, tuning: job.tuning,
                                               postExposure: job.postExposure, longEdge: job.longEdge,
                                               framing: job.framing),
                      let cg = FilmEngine.shared.cgImage(ci) else { return nil }
                return UIImage(cgImage: cg)
            }
            DispatchQueue.main.async { job.completion(img) }
        }
    }
}

/// Small renders of every recipe on one fixed photo bundled with the app (RecipePreview.jpg),
/// for the recipe browser. Results are kept in memory and on disk, so each recipe is developed
/// once per tuning and app build (engine changes alter the look).
final class RecipeThumbnailer {
    static let shared = RecipeThumbnailer()

    struct Key: Hashable {
        var recipe: Recipe
        var tuningVersion: Int
    }

    /// Thumbnails are shown at 58 pt.
    private static let edge: CGFloat = 180
    private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RecipeThumbs", isDirectory: true)
    private static let buildStamp: String = {
        let date = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return "\(date?.timeIntervalSince1970 ?? 0)"
    }()

    private let lock = NSLock()
    private var memory: [Key: UIImage] = [:]      // lock-guarded
    private var latestVersion = -1                // lock-guarded

    private let queue = DispatchQueue(label: "fv.thumbs", qos: .userInitiated)
    private var source: CIImage?                  // queue-confined
    private var dir: URL?                         // queue-confined
    private var dirVersion = -1                   // queue-confined

    func cached(_ key: Key) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return memory[key]
    }

    func thumbnail(_ key: Key, tuning: EngineTuning) async -> UIImage? {
        lock.lock()
        if key.tuningVersion > latestVersion {
            latestVersion = key.tuningVersion
            memory.removeAll()
        }
        let hit = memory[key]
        lock.unlock()
        if let hit { return hit }

        let img = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.load(key, tuning: tuning)) }
        }
        if let img {
            lock.lock()
            if key.tuningVersion == latestVersion { memory[key] = img }
            lock.unlock()
        }
        return img
    }

    private func isCurrent(_ version: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return version == latestVersion
    }

    private func load(_ key: Key, tuning: EngineTuning) -> UIImage? {
        guard isCurrent(key.tuningVersion), let dir = directory(for: key.tuningVersion, tuning: tuning) else { return nil }
        var look = key.recipe
        look.id = ""
        look.name = ""
        look.category = ""
        look.source = nil
        let file = dir.appendingPathComponent(Self.digest(Self.encode(look)) + ".jpg")
        if let img = UIImage(contentsOfFile: file.path)?.preparingForDisplay() { return img }

        return autoreleasepool { () -> UIImage? in
            guard let src = sourceImage() else { return nil }
            // referenceLongEdge stays at the full-frame default so grain and sharpening read as on a real photo.
            let ctx = RenderContext(source: .processed, processedLongEdge: Self.edge)
            let p = ParamResolver.resolve(key.recipe, tuning: tuning, context: ctx)
            let out = FilmEngine.shared.apply(src, p)
            guard let cg = FilmEngine.shared.cgImage(out) else { return nil }
            let img = UIImage(cgImage: cg)
            try? img.jpegData(compressionQuality: 0.9)?.write(to: file, options: .atomic)
            return img
        }
    }

    /// The on-disk folder for the current tuning; folders for other tunings are removed.
    private func directory(for version: Int, tuning: EngineTuning) -> URL? {
        if version == dirVersion { return dir }
        let name = Self.digest(Self.encode(tuning), Data(Self.buildStamp.utf8))
        let url = Self.root.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != name {
            try? fm.removeItem(at: old)
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        dir = url
        dirVersion = version
        return url
    }

    /// The bundled photo, downscaled once to thumbnail size.
    private func sourceImage() -> CIImage? {
        if let source { return source }
        guard let url = Bundle.main.url(forResource: "RecipePreview", withExtension: "jpg"),
              let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let scale = Self.edge / max(img.extent.width, img.extent.height)
        let scaled = img.applyingFilter("CILanczosScaleTransform",
                                        parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let e = scaled.extent.integral
        guard let cg = FilmEngine.shared.cgImage(scaled.cropped(to: e).translatedToOrigin()) else { return nil }
        source = CIImage(cgImage: cg)
        return source
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return (try? enc.encode(value)) ?? Data()
    }

    private static func digest(_ parts: Data...) -> String {
        var h = SHA256()
        parts.forEach { h.update(data: $0) }
        return h.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
