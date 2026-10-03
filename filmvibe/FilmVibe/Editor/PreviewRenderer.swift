import CoreImage
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

/// Small renders of every recipe on one sample photo, for the recipe browser.
@MainActor
final class RecipeThumbnailer: ObservableObject {
    static let shared = RecipeThumbnailer()

    @Published private(set) var revision = 0
    private let queue = DispatchQueue(label: "fv.thumbs", qos: .utility)
    private var session: DevelopSession?          // queue-confined
    private var sourceID: String?
    private var framing = Framing.full
    private var cache: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    private var tuningVersion = -1

    func setSource(_ item: PhotoItem?, library: LibraryStore) {
        guard let item, item.id != sourceID else { return }
        sourceID = item.id
        framing = Framing(crop: item.effectiveCrop, upscale: library.upscaleCrops)
        cache.removeAll()
        inFlight.removeAll()
        let url = library.originalURL(item), dr = item.captureDRStops
        queue.async { self.session = DevelopSession(url: url, captureDRStops: dr) }
        revision &+= 1
    }

    var hasSource: Bool { sourceID != nil }

    func image(for recipe: Recipe, tuning: EngineTuning, version: Int) -> UIImage? {
        if version != tuningVersion {
            tuningVersion = version
            cache.removeAll()
            inFlight.removeAll()
        }
        let key = "\(recipe.hashValue)"
        if let img = cache[key] { return img }
        guard sourceID != nil, !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        let v = version, framing = framing
        queue.async {
            let img = autoreleasepool { () -> UIImage? in
                guard let ci = self.session?.render(recipe: recipe, tuning: tuning, postExposure: 0, longEdge: 220, framing: framing),
                      let cg = FilmEngine.shared.cgImage(ci) else { return nil }
                return UIImage(cgImage: cg)
            }
            DispatchQueue.main.async {
                guard v == self.tuningVersion else { return }
                self.inFlight.remove(key)
                if let img {
                    self.cache[key] = img
                    self.revision &+= 1
                }
            }
        }
        return nil
    }
}
