import AVFoundation
import CoreImage
import UIKit

struct Lens: Identifiable, Equatable {
    let id: String
    let deviceType: AVCaptureDevice.DeviceType
    /// 35mm-equivalent focal length of the full frame.
    let focal: Double
}

/// A selectable focal length: a physical lens plus a centre crop of its frame.
struct FocalOption: Identifiable, Equatable {
    let focal: Int
    let lensID: String
    let crop: Double
    var id: Int { focal }
    var isNative: Bool { crop < 1.001 }
}

enum ISOSetting: Equatable {
    case auto
    case manual(Float)

    var label: String {
        switch self {
        case .auto: return "ISO A"
        case .manual(let v): return "ISO \(Int(v))"
        }
    }
}

struct ExposureReadout: Equatable {
    var shutter: String = "--"
    var iso: String = "--"
    var aperture: String = ""
}

struct CapturedPhoto {
    let data: Data
    let isRAW: Bool
    let recipe: Recipe
    let captureDRStops: Double
    let exposureInfo: String?
    let focal: Int
    let nativeFocal: Double
    let crop: Double
}

final class CameraController: NSObject, ObservableObject {
    enum Status: Equatable { case idle, running, denied, failed(String) }

    /// Focal lengths offered on top of the physical lenses (35mm equivalent).
    static let cropFocals: [Int] = [28, 35, 40, 50, 70]

    // MARK: Published UI state (main thread)
    @Published private(set) var status: Status = .idle
    @Published private(set) var focalOptions: [FocalOption] = []
    @Published private(set) var currentFocal: Int = 26
    @Published private(set) var captureFormatLabel = ""
    @Published private(set) var readout = ExposureReadout()
    @Published private(set) var shutterBlink = false
    @Published private(set) var isBusy = false
    @Published var isoSetting: ISOSetting = .auto {
        didSet { if isoSetting != oldValue { applyExposure() } }
    }
    @Published var evComp: Double = 0 {
        didSet { if evComp != oldValue { applyExposure() } }
    }

    var onPhoto: ((CapturedPhoto) -> Void)?
    /// Focal length to start with (restored from settings).
    var preferredFocal: Int = 26
    /// Keeps the session off while the gallery covers the camera, even if the app returns to the foreground.
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { stop() } else { start() }
        }
    }

    // MARK: AVFoundation
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "fv.camera.session")
    private let videoQueue = DispatchQueue(label: "fv.camera.video", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var rawFormat: OSType?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var configured = false
    private var readoutTimer: DispatchSourceTimer?
    private var lensesSnapshot: [Lens] = []
    private var usingHighResFormat = false
    private var focalSnapshot = FocalOption(focal: 26, lensID: "", crop: 1)

    // MARK: Live film state (guarded by `lock`)
    private let lock = NSLock()
    private var liveRecipe: Recipe = .neutral
    private var liveTuning: EngineTuning = .defaults
    private var liveDRStops: Double = 0
    private var liveEnabled = true
    private var liveUpscaleCrops = true
    private var liveParams: FilmParams?
    private var liveTargetLongEdge: CGFloat = 1600
    private var liveExtraGains = SIMD3<Float>(1, 1, 1)
    private var liveCrop: Double = 1
    private var latestFrame: CIImage?
    private var frameCounter = 0

    // Snapshot used on sessionQueue
    private var wantedISO: ISOSetting = .auto
    private var wantedBias: Float = 0

    // MARK: - Lifecycle

    func start() {
        guard !suspended else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.startSession() } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.readoutTimer?.cancel()
            self.readoutTimer = nil
        }
    }

    private func startSession() {
        let preferred = preferredFocal
        sessionQueue.async {
            if !self.configured {
                self.discoverLenses()
                let options = self.buildFocalOptions()
                guard let start = options.first(where: { $0.focal == preferred })
                        ?? options.first(where: { $0.isNative && self.lens($0.lensID)?.deviceType == .builtInWideAngleCamera })
                        ?? options.first else {
                    DispatchQueue.main.async { self.status = .failed("No camera available") }
                    return
                }
                DispatchQueue.main.async { self.focalOptions = options }
                self.applyFocal(start)
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.startReadoutTimer()
            DispatchQueue.main.async { self.status = .running }
        }
    }

    // MARK: - Lenses & focal lengths

    private func discoverLenses() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        var list: [Lens] = []
        for d in found {
            // 35mm-equivalent (diagonal) from the horizontal FOV of a 4:3 sensor.
            let hfov = Double(d.activeFormat.videoFieldOfView) * .pi / 180
            var eq = 17.31 / tan(hfov / 2)
            if d.deviceType == .builtInWideAngleCamera, abs(eq - 26) < 3 { eq = 26 }
            if d.deviceType == .builtInUltraWideCamera, abs(eq - 13) < 2 { eq = 13 }
            list.append(Lens(id: d.uniqueID, deviceType: d.deviceType, focal: eq.rounded()))
        }
        lensesSnapshot = list.sorted { $0.focal < $1.focal }
    }

    private func lens(_ id: String) -> Lens? { lensesSnapshot.first { $0.id == id } }

    private func buildFocalOptions() -> [FocalOption] {
        var opts: [FocalOption] = lensesSnapshot.map { FocalOption(focal: Int($0.focal), lensID: $0.id, crop: 1) }
        for f in Self.cropFocals {
            // Crop from the longest physical lens that is still wider than f.
            guard let base = lensesSnapshot.filter({ $0.focal <= Double(f) }).max(by: { $0.focal < $1.focal }) else { continue }
            if Int(base.focal) == f { continue }
            opts.append(FocalOption(focal: f, lensID: base.id, crop: Double(f) / base.focal))
        }
        var seen = Set<Int>()
        return opts.sorted { $0.focal < $1.focal }.filter { seen.insert($0.focal).inserted }
    }

    func selectFocal(_ option: FocalOption) {
        sessionQueue.async { self.applyFocal(option) }
    }

    private func applyFocal(_ option: FocalOption) {
        let needsHighRes = option.crop > 1.45
        if option.lensID != device?.uniqueID || needsHighRes != usingHighResFormat || !configured {
            configure(lensID: option.lensID, highRes: needsHighRes)
        }
        focalSnapshot = option
        lock.lock()
        liveCrop = option.crop
        liveParams = nil
        lock.unlock()
        DispatchQueue.main.async { self.currentFocal = option.focal }
    }

    // MARK: - Configuration

    private func configure(lensID: String, highRes: Bool) {
        guard let dev = AVCaptureDevice(uniqueID: lensID) else { return }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        guard let newInput = try? AVCaptureDeviceInput(device: dev), session.canAddInput(newInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = .failed("Could not open camera") }
            return
        }
        session.sessionPreset = .photo
        session.addInput(newInput)
        input = newInput
        device = dev

        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }

        // A compact 4:3 video format keeps the live film preview cheap; long crops use a
        // higher-resolution feed so the viewfinder stays sharp.
        selectFormat(dev, highRes: highRes)
        usingHighResFormat = highRes

        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = false }
        photoOutput.maxPhotoQualityPrioritization = .quality
        setMaxPhotoDimensions(dev)
        session.commitConfiguration()

        // If the chosen format has no Bayer RAW, fall back to the photo preset.
        if bayerFormat() == nil && session.sessionPreset != .photo {
            session.beginConfiguration()
            session.sessionPreset = .photo
            setMaxPhotoDimensions(dev)
            session.commitConfiguration()
        }

        rawFormat = bayerFormat()
        let label = rawFormat != nil ? "RAW" : "HEIF"
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)

        do {
            try dev.lockForConfiguration()
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.isSubjectAreaChangeMonitoringEnabled = true
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            dev.unlockForConfiguration()
        } catch {}

        applyWhiteBalanceLocked()
        applyExposureLocked()

        DispatchQueue.main.async { self.captureFormatLabel = label }
    }

    private func setMaxPhotoDimensions(_ dev: AVCaptureDevice) {
        if let maxDims = dev.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = maxDims
        }
    }

    private func selectFormat(_ dev: AVCaptureDevice, highRes: Bool) {
        let maxPhotoArea = dev.formats.map { f in f.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0 }.max() ?? 0
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let photoArea = f.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            let sizeOK = highRes ? (d.width >= 3000 && d.width <= 4096) : (d.width >= 1440 && d.width <= 2016)
            return abs(Double(d.width) / Double(d.height) - 4.0 / 3.0) < 0.01
                && sizeOK
                && photoArea == maxPhotoArea
                && sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        let pick = highRes
            ? candidates.min(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width })
            : candidates.max(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width })
        guard let fmt = pick else { return }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = fmt
            dev.unlockForConfiguration()
        } catch {}
    }

    private func bayerFormat() -> OSType? {
        photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    // MARK: - Recipe → camera

    /// Called when the active recipe, tuning or relevant settings change.
    func update(recipe: Recipe, tuning: EngineTuning, liveFilm: Bool, upscaleCrops: Bool) {
        let dr = ParamResolver.captureDRStops(for: recipe, tuning: tuning)
        lock.lock()
        let wbChanged = liveRecipe.whiteBalance != recipe.whiteBalance || liveTuning != tuning
        let drChanged = liveDRStops != dr
        liveRecipe = recipe
        liveTuning = tuning
        liveDRStops = dr
        liveEnabled = liveFilm
        liveUpscaleCrops = upscaleCrops
        liveParams = nil
        if !recipe.whiteBalance.mode.isAuto || recipe.whiteBalance.mode == .auto { liveExtraGains = SIMD3(1, 1, 1) }
        lock.unlock()
        if wbChanged { sessionQueue.async { self.applyWhiteBalanceLocked() } }
        if drChanged { applyExposure() }
    }

    func setPreviewTarget(longEdge: CGFloat) {
        lock.lock()
        if abs(liveTargetLongEdge - longEdge) > 1 {
            liveTargetLongEdge = longEdge
            liveParams = nil
        }
        lock.unlock()
    }

    func currentFrame() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return latestFrame
    }

    // MARK: - White balance

    private func applyWhiteBalanceLocked() {
        guard let dev = device else { return }
        lock.lock()
        let recipe = liveRecipe, tuning = liveTuning
        lock.unlock()
        do { try dev.lockForConfiguration() } catch { return }
        defer { dev.unlockForConfiguration() }
        if let (temp, tint) = ParamResolver.fixedWhiteBalance(for: recipe, tuning: tuning),
           dev.isWhiteBalanceModeSupported(.locked) {
            var g = dev.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temp, tint: tint))
            let maxG = dev.maxWhiteBalanceGain
            g.redGain = min(max(g.redGain, 1), maxG)
            g.greenGain = min(max(g.greenGain, 1), maxG)
            g.blueGain = min(max(g.blueGain, 1), maxG)
            dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
        } else if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            dev.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    /// For Auto White / Ambience priority, nudge the live preview the same way development does.
    private func updateAutoWBCorrection() {
        guard let dev = device else { return }
        lock.lock()
        let mode = liveRecipe.whiteBalance.mode, tuning = liveTuning
        lock.unlock()
        guard mode == .autoWhite || mode == .autoAmbience else { return }
        let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
        let adjust = Float(mode == .autoWhite ? -tuning.autoWhiteStrength : tuning.autoAmbienceStrength)
        let target = FilmEngine.adjustedAutoTemperature(tt.temperature, adjust: adjust)
        let a = kelvinRGB(tt.temperature), b = kelvinRGB(target)
        var g = SIMD3<Float>(a.x / b.x, a.y / b.y, a.z / b.z)
        g /= (0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z)
        lock.lock()
        if simd_length(g - liveExtraGains) > 0.002 {
            liveExtraGains = g
            liveParams = nil
        }
        lock.unlock()
    }

    // MARK: - Exposure

    private func applyExposure() {
        let ev = evComp, iso = isoSetting
        lock.lock()
        let dr = liveDRStops
        lock.unlock()
        sessionQueue.async {
            self.wantedBias = Float(ev - dr)
            self.wantedISO = iso
            self.applyExposureLocked()
        }
    }

    private func applyExposureLocked() {
        guard let dev = device else { return }
        do { try dev.lockForConfiguration() } catch { return }
        defer { dev.unlockForConfiguration() }
        let bias = min(max(wantedBias, dev.minExposureTargetBias), dev.maxExposureTargetBias)
        switch wantedISO {
        case .auto:
            if dev.exposureMode == .custom || dev.exposureMode == .locked,
               dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
        case .manual(let iso):
            let fmt = dev.activeFormat
            let clamped = min(max(iso, fmt.minISO), fmt.maxISO)
            dev.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: clamped, completionHandler: nil)
        }
        dev.setExposureTargetBias(bias, completionHandler: nil)
    }

    /// ISO-priority auto exposure: with a fixed ISO, steer shutter speed toward the metered target.
    private func manualExposureTick() {
        guard case .manual(let wanted) = wantedISO, let dev = device, dev.exposureMode == .custom else { return }
        let fmt = dev.activeFormat
        let iso = min(max(wanted, fmt.minISO), fmt.maxISO)
        let offset = dev.exposureTargetOffset
        guard offset.isFinite else { return }
        let cur = CMTimeGetSeconds(dev.exposureDuration)
        guard cur > 0 else { return }
        var target = cur * pow(2.0, Double(-offset) * 0.6)
        let minD = CMTimeGetSeconds(fmt.minExposureDuration)
        let maxD = min(CMTimeGetSeconds(fmt.maxExposureDuration), 0.25)
        target = min(max(target, minD), maxD)
        if abs(log2(target / cur)) < 0.04 && abs(dev.iso - iso) < 1 { return }
        do {
            try dev.lockForConfiguration()
            dev.setExposureModeCustom(duration: CMTime(seconds: target, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
            dev.unlockForConfiguration()
        } catch {}
    }

    var isoRange: ClosedRange<Float> {
        guard let f = device?.activeFormat else { return 50...3200 }
        return f.minISO...f.maxISO
    }

    private func startReadoutTimer() {
        readoutTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: sessionQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(150))
        t.setEventHandler { [weak self] in
            guard let self, let dev = self.device else { return }
            self.manualExposureTick()
            self.updateAutoWBCorrection()
            let r = ExposureReadout(shutter: Self.shutterString(CMTimeGetSeconds(dev.exposureDuration)),
                                    iso: "ISO \(Int(dev.iso.rounded()))",
                                    aperture: String(format: "ƒ%.1f", dev.lensAperture))
            DispatchQueue.main.async { if self.readout != r { self.readout = r } }
        }
        t.resume()
        readoutTimer = t
    }

    static func shutterString(_ s: Double) -> String {
        guard s > 0, s.isFinite else { return "--" }
        if s >= 0.5 { return String(format: "%.1f\"", s) }
        return "1/\(Int((1 / s).rounded()))"
    }

    // MARK: - Focus

    /// `point` is normalised (0...1) in the portrait viewfinder (which shows the cropped frame), origin top-left.
    func focus(at point: CGPoint) {
        lock.lock()
        let crop = liveCrop
        lock.unlock()
        let full = CGPoint(x: 0.5 + (point.x - 0.5) / crop, y: 0.5 + (point.y - 0.5) / crop)
        sessionQueue.async {
            guard let dev = self.device else { return }
            let devicePoint = CGPoint(x: full.y, y: 1 - full.x)
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported {
                    dev.focusPointOfInterest = devicePoint
                    if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                }
                if dev.isExposurePointOfInterestSupported {
                    dev.exposurePointOfInterest = devicePoint
                    if dev.exposureMode != .custom, dev.isExposureModeSupported(.continuousAutoExposure) {
                        dev.exposureMode = .continuousAutoExposure
                    }
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Capture

    func capture() {
        lock.lock()
        let recipe = liveRecipe, dr = liveDRStops
        lock.unlock()
        DispatchQueue.main.async { self.isBusy = true }
        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            if let raw = self.rawFormat {
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                settings.photoQualityPrioritization = .speed
            } else {
                let codec: AVVideoCodecType = self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                settings.photoQualityPrioritization = .balanced
            }
            if self.photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions

            if let conn = self.photoOutput.connection(with: .video), let rc = self.rotationCoordinator {
                let angle = rc.videoRotationAngleForHorizonLevelCapture
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            }

            let focal = self.focalSnapshot
            let nativeFocal = self.lens(focal.lensID)?.focal ?? Double(focal.focal)
            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(
                willCapture: { [weak self] in
                    DispatchQueue.main.async {
                        self?.shutterBlink = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.shutterBlink = false }
                    }
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    self.sessionQueue.async { self.inFlight[id] = nil }
                    DispatchQueue.main.async {
                        self.isBusy = false
                        if let result {
                            self.onPhoto?(CapturedPhoto(data: result.data, isRAW: result.isRAW, recipe: recipe,
                                                        captureDRStops: result.isRAW ? dr : 0,
                                                        exposureInfo: result.info, focal: focal.focal,
                                                        nativeFocal: nativeFocal, crop: focal.crop))
                        }
                    }
                })
            self.inFlight[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }
}

// MARK: - Live frames

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var img = CIImage(cvPixelBuffer: pb).oriented(.right)

        lock.lock()
        let target = liveTargetLongEdge
        let enabled = liveEnabled
        let crop = liveCrop
        lock.unlock()

        img = img.centerCropped(by: crop)
        let long = max(img.extent.width, img.extent.height)
        if target < long {
            let s = target / long
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        img = img.translatedToOrigin()

        guard enabled else {
            lock.lock(); latestFrame = img; lock.unlock()
            return
        }

        lock.lock()
        if liveParams == nil {
            var ctx = RenderContext(source: .live, processedLongEdge: max(img.extent.width, img.extent.height))
            ctx.captureDRStops = liveDRStops
            ctx.extraGains = liveExtraGains
            if !liveUpscaleCrops { ctx.referenceLongEdge = 4032 / CGFloat(crop) }
            liveParams = ParamResolver.resolve(liveRecipe, tuning: liveTuning, context: ctx)
        }
        let params = liveParams!
        frameCounter &+= 1
        let seed = CGPoint(x: CGFloat((frameCounter * 7919) % 997), y: CGFloat((frameCounter * 104729) % 991))
        lock.unlock()

        let out = FilmEngine.shared.apply(img, params, grainSeed: seed)
        lock.lock(); latestFrame = out; lock.unlock()
    }
}

// MARK: - Photo delegate

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    struct Result { let data: Data; let isRAW: Bool; let info: String? }

    private let willCapture: () -> Void
    private let completion: (Result?) -> Void
    private var result: Result?

    init(willCapture: @escaping () -> Void, completion: @escaping (Result?) -> Void) {
        self.willCapture = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        var info: String?
        if let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            var parts: [String] = []
            if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double { parts.append(CameraController.shutterString(t)) }
            if let f = exif[kCGImagePropertyExifFNumber as String] as? Double { parts.append(String(format: "ƒ%.1f", f)) }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { parts.append("ISO \(iso)") }
            info = parts.joined(separator: "  ")
        }
        result = Result(data: data, isRAW: photo.isRawPhoto, info: info)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(result)
    }
}

// MARK: - Helpers

/// Approximate linear RGB of a black body at `k` Kelvin (Tanner Helland fit), normalised to green.
func kelvinRGB(_ k: Float) -> SIMD3<Float> {
    let t = Double(min(max(k, 1500), 15000)) / 100
    var r: Double, g: Double, b: Double
    if t <= 66 {
        r = 255
        g = 99.4708025861 * log(t) - 161.1195681661
        b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
    } else {
        r = 329.698727446 * pow(t - 60, -0.1332047592)
        g = 288.1221695283 * pow(t - 60, -0.0755148492)
        b = 255
    }
    func lin(_ v: Double) -> Double {
        let x = min(max(v, 1), 255) / 255
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    let rr = lin(r), gg = lin(g), bb = lin(b)
    return SIMD3(Float(rr / gg), 1, Float(bb / gg))
}
