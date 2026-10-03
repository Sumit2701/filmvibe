import SwiftUI
import UIKit

/// Full-screen photos laid out like the iOS Camera roll: oldest → newest left to right, back or swipe down returns
/// to where it was opened from, Share · Info · Delete along the bottom, tap hides the bars, swipe up shows info.
/// Only the developed JPEG is kept, so there is nothing left to re-develop (failed develops open the editor).
struct PhotoViewer: View {
    enum Origin { case camera, grid }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var app: AppModel
    @StateObject private var images = ViewerImages()
    @StateObject private var drag = DismissDrag()

    let origin: Origin
    let onClose: () -> Void
    var onAllPhotos: (() -> Void)?
    let onEdit: (PhotoItem) -> Void

    @State private var selection: String
    @State private var chromeHidden = false
    @State private var dragging = false
    @State private var showInfo = false
    @State private var deleteTarget: PhotoItem?
    @State private var confirmDelete = false
    @State private var shareURL: URL?
    @State private var toast: String?

    init(origin: Origin, startAt id: String?, onClose: @escaping () -> Void, onAllPhotos: (() -> Void)? = nil,
         onEdit: @escaping (PhotoItem) -> Void) {
        self.origin = origin
        self.onClose = onClose
        self.onAllPhotos = onAllPhotos
        self.onEdit = onEdit
        _selection = State(initialValue: id ?? "")
    }

    /// Oldest first, so older photos sit to the left like the Camera roll.
    private var items: [PhotoItem] { library.items.reversed() }
    private var current: PhotoItem? { library.items.first { $0.id == selection } }
    private var showsChrome: Bool { !chromeHidden && !dragging }

    var body: some View {
        ZStack {
            // From the camera the backdrop fades as you swipe down, revealing the viewfinder behind.
            DismissBackdrop(drag: drag, fades: origin == .camera).ignoresSafeArea()
            if items.isEmpty { emptyState } else { pager }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsChrome, let item = current {
                bottomInfo(item).transition(.opacity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbar(showsChrome ? .visible : .hidden, for: .navigationBar)
        .toolbar(showsChrome && current != nil ? .visible : .hidden, for: .bottomBar)
        .modifier(ViewerBarBackground())
        .sheet(isPresented: $showInfo) {
            if let item = current {
                PhotoInfoSheet(item: item, onSave: { save(item) }, onUseRecipe: {
                    app.select(item.recipe)
                    flash("“\(item.recipe.name)” loaded in camera")
                })
            }
        }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { s in
            ShareSheet(items: [s.url])
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
        .onAppear { focus() }
        .onChange(of: library.items) { old, _ in
            keepSelection(after: old)
            focus()
        }
        .onChange(of: library.rendering) { _, _ in focus() }
        .onChange(of: selection) { _, _ in focus() }
    }

    // MARK: Pages

    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                page(item).tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func page(_ item: PhotoItem) -> some View {
        let failed = library.developFailed(item)
        let thumb = library.thumbnail(item)
        ZStack {
            // The thumbnail stands in while the full-resolution JPEG decodes.
            ZoomableImage(image: failed ? nil : images.loaded[item.id] ?? thumb,
                          onTap: toggleChrome,
                          onSwipeUp: { showInfo = true },
                          onDismissProgress: dragChanged,
                          onDismiss: onClose)
            if failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 34))
                    Text("This photo didn't develop").font(.headline)
                    Button("Open in Editor") { onEdit(item) }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.black)
                }
                .foregroundStyle(Theme.dim)
            } else if images.failed.contains(item.id) {
                Text("Could not open this photo")
                    .foregroundStyle(Theme.dim)
                    .allowsHitTesting(false)
            } else if thumb == nil && library.rendering.contains(item.id) {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Developing…").font(.footnote).foregroundStyle(Theme.dim)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle").font(.system(size: 44))
            Text("No photos yet").font(.headline)
            Text("Shoot with the camera, or import RAW / photos from your library.")
                .font(.footnote)
                .multilineTextAlignment(.center)
            ImportButton { Text("Import Photos") }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 40)
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if origin == .camera {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").fontWeight(.semibold)
                }
                .accessibilityLabel("Camera")
            }
        }
        ToolbarItem(placement: .principal) {
            if let item = current {
                VStack(spacing: 0) {
                    Text(item.date.dayTitle).font(.subheadline.weight(.semibold))
                    Text(item.date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let onAllPhotos {
            ToolbarItem(placement: .topBarTrailing) {
                Button("All Photos", action: onAllPhotos)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { shareURL = current.map(library.renderURL) } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
                .disabled(current?.renderedAt == nil)
            Spacer()
            Button { showInfo = true } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("Info")
            Spacer()
            Button {
                deleteTarget = current
                confirmDelete = true
            } label: { Image(systemName: "trash") }
            .accessibilityLabel("Delete")
            .confirmationDialog("Delete", isPresented: $confirmDelete, titleVisibility: .hidden, presenting: deleteTarget) { item in
                Button("Delete Photo", role: .destructive) { delete(item) }
            } message: { _ in
                Text("It's removed from FilmVibe. A copy already saved to Photos is kept.")
            }
        }
    }

    /// Recipe + capture line and the thumbnail strip, just above the bottom bar.
    private func bottomInfo(_ item: PhotoItem) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Tag(text: item.recipe.filmSimulation.badge, color: Theme.accent, filled: true)
                Text(item.recipe.name)
                    .font(Theme.label(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text([item.focalLength.map { "\($0)mm" }, item.exposureInfo].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            Filmstrip(items: items, selection: $selection)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .modifier(ViewerStripBackground())
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
    }

    private func dragChanged(_ progress: CGFloat) {
        drag.progress = progress
        let active = progress > 0
        if active != dragging { withAnimation(.easeOut(duration: 0.15)) { dragging = active } }
    }

    // MARK: Actions

    private func focus() { images.focus(on: selection, in: items, library: library) }

    private func delete(_ item: PhotoItem) {
        let alive = Set(items.map(\.id)).subtracting([item.id])
        let wasLast = alive.isEmpty
        // Move off the photo first so the pager never points at a missing page.
        withAnimation {
            if let next = Self.nearest(to: item.id, in: items, alive: alive) { selection = next }
            library.delete(item)
        }
        if wasLast { onClose() }
    }

    /// Keeps the pager on a real photo when the library changes underneath it (editor or grid deletes).
    private func keepSelection(after old: [PhotoItem]) {
        let alive = Set(library.items.map(\.id))
        guard !alive.contains(selection) else { return }
        selection = Self.nearest(to: selection, in: old.reversed(), alive: alive) ?? items.last?.id ?? ""
    }

    /// Closest surviving photo, preferring the older one like the Camera roll does after a delete.
    private static func nearest(to id: String, in list: [PhotoItem], alive: Set<String>) -> String? {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        if let older = list[..<i].last(where: { alive.contains($0.id) }) { return older.id }
        return list[(i + 1)...].first { alive.contains($0.id) }?.id
    }

    private func save(_ item: PhotoItem) {
        PhotoSaver.save(jpegURL: library.renderURL(item), rawURL: nil) { err in flash(err ?? "Saved to Photos") }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { if toast == s { toast = nil } } }
    }
}

// MARK: - Pieces

/// Tap-to-jump thumbnail strip, the current photo shown wider and kept centred.
private struct Filmstrip: View {
    let items: [PhotoItem]
    @Binding var selection: String
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 2) {
                        ForEach(items) { item in
                            let selected = item.id == selection
                            Theme.panel2
                                .frame(width: selected ? 44 : 28, height: 40)
                                .overlay {
                                    if let img = library.thumbnail(item) {
                                        Image(uiImage: img).resizable().scaledToFill()
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .padding(.horizontal, selected ? 6 : 0)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = item.id }
                                .id(item.id)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: selection)
                }
                .contentMargins(.horizontal, max(geo.size.width / 2 - 28, 0), for: .scrollContent)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, id in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(height: 40)
    }
}

@MainActor
private final class DismissDrag: ObservableObject {
    @Published var progress: CGFloat = 0
}

/// Kept separate so swipe-down progress redraws only the backdrop, not the pager.
private struct DismissBackdrop: View {
    @ObservedObject var drag: DismissDrag
    let fades: Bool

    var body: some View {
        Theme.background.opacity(fades ? 1 - drag.progress : 1)
    }
}

/// iOS 26 floats glass buttons over the photo; earlier versions get the translucent bars the Photos app used.
private struct ViewerBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.toolbarBackground(.visible, for: .navigationBar, .bottomBar)
        }
    }
}

private struct ViewerStripBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.background(
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        } else {
            content.background(.bar)
        }
    }
}

// MARK: - Info

/// What the Photos (i) panel shows, for a film recipe: the settings it was developed with and how it was shot.
struct PhotoInfoSheet: View {
    let item: PhotoItem
    let onSave: () -> Void
    let onUseRecipe: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = item.recipe
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Tag(text: r.filmSimulation.badge, color: Theme.accent, filled: true)
                        Text(r.name).font(.headline)
                    }
                    if item.captureRecipeName != r.name { row("Shot With", item.captureRecipeName) }
                    row("Film Simulation", r.filmSimulation.displayName)
                    if r.usesDRangePriority {
                        row("D-Range Priority", r.dRangePriority.label)
                    } else {
                        row("Dynamic Range", r.dynamicRange.label)
                        row("Highlight", r.highlight.toneString)
                        row("Shadow", r.shadow.toneString)
                    }
                    if r.filmSimulation.isMonochrome {
                        row("Monochromatic Color", "WC \(r.monoWC.signedString) MG \(r.monoMG.signedString)")
                    } else {
                        row("Color", r.color.signedString)
                    }
                    row("White Balance", r.whiteBalance.summary)
                    row("Grain", r.grainEffect == .off ? "Off" : "\(r.grainEffect.label), \(r.grainSize.label)")
                    row("Color Chrome", r.colorChrome.label)
                    row("Color Chrome FX Blue", r.colorChromeBlue.label)
                    row("Clarity", r.clarity.signedString)
                    row("Sharpness", r.sharpness.signedString)
                    row("High ISO NR", r.highISONR.signedString)
                } header: { Text("Recipe") }

                Section("Capture") {
                    if let f = item.focalLength { row("Focal Length", "\(f)mm") }
                    if let info = item.exposureInfo { row("Exposure", info) }
                    if item.postExposure != 0 { row("Exposure Adjustment", "\(item.postExposure.evString) EV") }
                    row("Original", item.isRAW ? "RAW (DNG)" : "Photo")
                }

                Section {
                    Button {
                        onUseRecipe()
                        dismiss()
                    } label: { Label("Use Recipe in Camera", systemImage: "camera") }
                    Button {
                        onSave()
                        dismiss()
                    } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    .disabled(item.renderedAt == nil)
                }
            }
            .navigationTitle(item.date.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }
}

private extension Date {
    /// "Today", "Yesterday", a weekday within the last week, else the full date — like the Photos viewer title.
    var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: .now)).day ?? 99
        return days < 7 ? formatted(.dateTime.weekday(.wide)) : formatted(.dateTime.day().month(.wide).year())
    }
}

// MARK: - Images

/// Full-resolution decodes for the visible photo and its neighbours; everything else is released.
@MainActor
final class ViewerImages: ObservableObject {
    @Published private(set) var loaded: [String: UIImage] = [:]
    @Published private(set) var failed: Set<String> = []
    private var loading: Set<String> = []

    func focus(on id: String, in items: [PhotoItem], library: LibraryStore) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let wanted = items[max(0, i - 1)...min(items.count - 1, i + 1)]
        let keep = Set(wanted.map(\.id))
        loaded = loaded.filter { keep.contains($0.key) }
        loading.formIntersection(keep)
        for item in wanted where loaded[item.id] == nil && !loading.contains(item.id) && !failed.contains(item.id)
            && item.renderedAt != nil && !library.rendering.contains(item.id) {
            loading.insert(item.id)
            let url = library.renderURL(item)
            Task {
                let img = await UIImage(contentsOfFile: url.path)?.byPreparingForDisplay()
                guard loading.remove(item.id) != nil else { return }   // scrolled away meanwhile
                if let img { loaded[item.id] = img } else { failed.insert(item.id) }
            }
        }
    }
}
