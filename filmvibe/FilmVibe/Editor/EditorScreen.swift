import SwiftUI
import UIKit

@MainActor
final class EditorModel: ObservableObject {
    @Published var recipe: Recipe { didSet { if recipe != oldValue { render() } } }
    @Published var postExposure: Double { didSet { if postExposure != oldValue { render() } } }
    /// Focal-length crop (1 = full frame).
    @Published var crop: Double { didSet { if crop != oldValue { render(); renderBefore() } } }
    @Published var image: UIImage?
    @Published var before: UIImage?
    @Published var loading = true
    @Published var failed = false
    @Published var isRAW = false
    @Published var diagnostics = ""

    private(set) var item: PhotoItem
    var tuning: EngineTuning { didSet { if tuning != oldValue { render() } } }
    private let upscaleCrops: Bool
    private var framing: Framing { Framing(crop: crop, upscale: upscaleCrops) }
    private let renderer = PreviewRenderer()
    private let longEdge: CGFloat = 2048

    init(item: PhotoItem, library: LibraryStore, tuning: EngineTuning) {
        self.item = item
        self.recipe = item.recipe
        self.postExposure = item.postExposure
        self.crop = item.effectiveCrop
        self.upscaleCrops = library.upscaleCrops
        self.tuning = tuning
        renderer.load(url: library.originalURL(item), captureDRStops: item.captureDRStops) { [weak self] ok, raw in
            guard let self else { return }
            self.loading = false
            self.failed = !ok
            self.isRAW = raw
            guard ok else { return }
            self.render()
            self.renderBefore()
            self.renderer.diagnostics { [weak self] s in self?.diagnostics = s }
        }
    }

    var isDirty: Bool { recipe != item.recipe || postExposure != item.postExposure || crop != item.effectiveCrop }

    func render() {
        guard !loading, !failed else { return }
        renderer.request(.init(recipe: recipe, tuning: tuning, postExposure: postExposure, longEdge: longEdge,
                               framing: framing) { [weak self] img in
            if let img { self?.image = img }
        })
    }

    func renderBefore() {
        guard !loading, !failed else { return }
        renderer.renderStandard(longEdge: longEdge, framing: framing) { [weak self] img in self?.before = img }
    }

    /// Focal lengths this photo can be re-framed to (35mm equivalent), as (label, crop).
    var focalChoices: [(String, Double)] {
        if let native = item.nativeFocal, native > 0 {
            var list: [(String, Double)] = [("\(Int(native))mm", 1)]
            for f in [18, 21, 24, 28, 35, 40, 50, 70, 85] where Double(f) > native + 0.5 && Double(f) <= native * 3.3 {
                list.append(("\(f)mm", Double(f) / native))
            }
            return list
        }
        return [1, 1.25, 1.5, 2, 2.5, 3].map { ($0 == 1 ? "Full frame" : String(format: "%.2g× crop", $0), $0) }
    }

    var focalLabel: String {
        if let native = item.nativeFocal { return "\(Int((native * crop).rounded()))mm" }
        return crop <= 1.001 ? "Full frame" : String(format: "%.2g× crop", crop)
    }

    /// Writes edits back to the library item.
    func commit(to library: LibraryStore) -> PhotoItem {
        item.recipe = recipe
        item.postExposure = postExposure
        item.crop = crop > 1.001 ? crop : nil
        library.update(item)
        return item
    }
}

struct EditorScreen: View {
    @StateObject private var model: EditorModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tuningStore: TuningStore
    @EnvironmentObject private var store: RecipeStore
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showBefore = false
    @State private var showRecipePicker = false
    @State private var askName = false
    @State private var newName = ""
    @State private var toast: String?
    @State private var exporting = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false

    init(item: PhotoItem, library: LibraryStore, tuning: EngineTuning) {
        _model = StateObject(wrappedValue: EditorModel(item: item, library: library, tuning: tuning))
    }

    var body: some View {
        VStack(spacing: 0) {
            imageArea
                .frame(maxHeight: .infinity)
            controls
                .frame(height: UIScreen.main.bounds.height * 0.46)
        }
        .background(Theme.background)
        .navigationTitle(model.recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showRecipePicker) {
            RecipeBrowser(mode: .apply { r in
                var applied = r
                applied.exposureComp = model.recipe.exposureComp
                model.recipe = applied
            })
        }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { s in
            ShareSheet(items: [s.url])
        }
        .alert("Save as Recipe", isPresented: $askName) {
            TextField("Name", text: $newName)
            Button("Save") {
                let r = model.recipe.duplicated(named: newName)
                store.save(r)
                model.recipe = r
                flash("Recipe saved")
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(model.item)
                dismiss()
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: tuningStore.tuning) { _, t in model.tuning = t }
        .onDisappear {
            if model.isDirty {
                let item = model.commit(to: library)
                library.develop(item, tuning: tuningStore.tuning)
            }
        }
    }

    // MARK: Image

    private var imageArea: some View {
        ZStack {
            Theme.background
            if let img = (showBefore ? model.before : nil) ?? model.image {
                ZoomableImage(image: img)
            } else if model.failed {
                Text("Could not open this photo").foregroundStyle(Theme.dim)
            } else {
                ProgressView()
            }
            VStack {
                HStack {
                    if showBefore {
                        Tag(text: model.isRAW ? "APPLE STANDARD" : "ORIGINAL", color: .white, filled: false)
                    }
                    Spacer()
                    Button {} label: {
                        Text("HOLD TO COMPARE")
                            .font(Theme.mono(10, .bold))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in showBefore = true }
                            .onEnded { _ in showBefore = false }
                    )
                }
                Spacer()
                if !model.diagnostics.isEmpty {
                    Text(model.diagnostics)
                        .font(Theme.mono(9))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .clipped()
    }

    // MARK: Controls

    private var controls: some View {
        List {
            Section {
                Button { showRecipePicker = true } label: {
                    HStack {
                        Tag(text: model.recipe.filmSimulation.badge, color: Theme.accent, filled: true)
                        Text(model.recipe.name).foregroundStyle(Theme.text)
                        Spacer()
                        Text("Change").foregroundStyle(Theme.accent)
                    }
                }
                StepRow(title: "Exposure", value: $model.postExposure, range: -3...3, step: 1.0 / 3.0) { $0.evString }
                HStack {
                    Text("Focal Length")
                    Spacer()
                    Menu {
                        ForEach(model.focalChoices, id: \.1) { choice in
                            Button {
                                model.crop = choice.1
                            } label: {
                                if abs(choice.1 - model.crop) < 0.001 { Label(choice.0, systemImage: "checkmark") } else { Text(choice.0) }
                            }
                        }
                    } label: {
                        Text(model.focalLabel)
                            .font(Theme.mono(15, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                if model.isDirty {
                    Button("Reset to Capture Settings") {
                        model.recipe = model.item.recipe
                        model.postExposure = model.item.postExposure
                        model.crop = model.item.effectiveCrop
                    }
                    .foregroundStyle(Theme.accent)
                }
            } header: {
                HStack {
                    SectionTitle("Develop")
                    Spacer()
                    if let info = model.item.exposureInfo {
                        Text(info).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    }
                }
            }
            RecipeSettingsForm(recipe: $model.recipe, showExposure: false)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { export(share: false) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                Button { export(share: true) } label: { Label("Share JPEG…", systemImage: "square.and.arrow.up") }
                Button { shareURL = library.originalURL(model.item) } label: {
                    Label(model.isRAW ? "Share Original RAW (DNG)…" : "Share Original…", systemImage: "doc")
                }
                Divider()
                if store.recipe(id: model.recipe.id) != nil && store.recipe(id: model.recipe.id) != model.recipe {
                    Button { store.save(model.recipe); flash("Recipe updated") } label: {
                        Label("Update Recipe “\(model.recipe.name)”", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Button {
                    newName = model.recipe.name + " (edit)"
                    askName = true
                } label: { Label("Save as New Recipe…", systemImage: "plus.square.on.square") }
                Button {
                    app.select(model.recipe)
                    flash("Loaded into camera")
                } label: { Label("Use in Camera", systemImage: "camera") }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Photo", systemImage: "trash") }
            } label: {
                if exporting { ProgressView() } else { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func export(share: Bool) {
        exporting = true
        let item = model.commit(to: library)
        library.develop(item, tuning: tuningStore.tuning, saveToPhotos: !share) { url in
            exporting = false
            guard let url else { flash("Export failed"); return }
            if share { shareURL = url } else { flash("Saved to Photos") }
        }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { toast = nil } }
    }
}

// MARK: - Zoomable image

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomView { ZoomView() }
    func updateUIView(_ v: ZoomView, context: Context) { v.setImage(image) }

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        private let imageView = UIImageView()
        private var lastSize: CGSize = .zero

        init() {
            super.init(frame: .zero)
            delegate = self
            maximumZoomScale = 6
            minimumZoomScale = 1
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            dbl.numberOfTapsRequired = 2
            addGestureRecognizer(dbl)
        }
        required init?(coder: NSCoder) { fatalError() }

        func setImage(_ img: UIImage) {
            imageView.image = img
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize {
                lastSize = bounds.size
                zoomScale = 1
                imageView.frame = bounds
                contentSize = bounds.size
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            if zoomScale > 1 {
                setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let s: CGFloat = 3
                let w = bounds.width / s, h = bounds.height / s
                zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}

// MARK: - Share sheet

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
