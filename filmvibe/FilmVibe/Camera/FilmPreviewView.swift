import CoreImage
import MetalKit
import SwiftUI

/// Draws the latest film-processed camera frame with Metal.
final class FilmPreviewMTKView: MTKView, MTKViewDelegate {
    var frameProvider: (() -> CIImage?)?
    var onDrawableSize: ((CGSize) -> Void)?
    private let queue: MTLCommandQueue
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    init() {
        let dev = FilmEngine.shared.device
        queue = dev.makeCommandQueue()!
        super.init(frame: .zero, device: dev)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true
        backgroundColor = .black
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        (layer as? CAMetalLayer)?.colorspace = colorSpace
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        onDrawableSize?(size)
    }

    func draw(in view: MTKView) {
        guard let image = frameProvider?(), let drawable = currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let size = drawableSize
        guard size.width > 0, size.height > 0, image.extent.width > 0 else { return }

        // Aspect-fill the frame into the drawable.
        let s = max(size.width / image.extent.width, size.height / image.extent.height)
        let w = image.extent.width * s, h = image.extent.height * s
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
        let bg = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))

        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                       pixelFormat: colorPixelFormat, commandBuffer: cb,
                                       mtlTextureProvider: { drawable.texture })
        dest.colorSpace = colorSpace
        _ = try? FilmEngine.shared.context.startTask(toRender: placed.composited(over: bg),
                                                      from: CGRect(origin: .zero, size: size), to: dest, at: .zero)
        cb.present(drawable)
        cb.commit()
    }
}

struct FilmPreview: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> FilmPreviewMTKView {
        let v = FilmPreviewMTKView()
        let cam = camera
        v.frameProvider = { cam.currentFrame() }
        v.onDrawableSize = { size in cam.setPreviewTarget(longEdge: max(size.width, size.height)) }
        return v
    }

    func updateUIView(_ uiView: FilmPreviewMTKView, context: Context) {}
}
