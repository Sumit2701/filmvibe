import SwiftUI
import UIKit

/// Finished photos, swipeable in library order. Only the developed JPEG is kept, so there is
/// nothing left to re-develop.
struct PhotoViewer: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var images = ViewerImages()
    /// Closes the whole library and returns to the camera (back goes to the grid).
    let onCamera: () -> Void

    @State private var selection: String
    @State private var items: [PhotoItem] = []
    @State private var shareURL: URL?
    @State private var confirmDelete = false
    @State private var toast: String?

    init(startAt item: PhotoItem, onCamera: @escaping () -> Void) {
        _selection = State(initialValue: item.id)
        self.onCamera = onCamera
    }

    private var current: PhotoItem? { items.first { $0.id == selection } }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                page(item).tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { infoBar }
        .navigationTitle(current?.recipe.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { onCamera() } label: { Image(systemName: "camera") }
                Menu {
                    Button { saveToPhotos() } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    Button { shareURL = current.map(library.renderURL) } label: { Label("Share JPEG…", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Photo", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(current == nil)
            }
        }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { s in
            ShareSheet(items: [s.url])
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
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
        .onAppear { reloadItems() }
        .onChange(of: library.items) { _, _ in reloadItems() }
        .onChange(of: library.rendering) { _, _ in reloadItems() }
        .onChange(of: selection) { _, _ in images.focus(on: selection, in: items, library: library) }
    }

    @ViewBuilder
    private func page(_ item: PhotoItem) -> some View {
        ZStack {
            Theme.background
            if let img = images.loaded[item.id] {
                ZoomableImage(image: img)
            } else if images.failed.contains(item.id) {
                Text("Could not open this photo").foregroundStyle(Theme.dim)
            } else if let thumb = library.thumbnail(item) {
                // Shown while the full-resolution JPEG decodes.
                Image(uiImage: thumb).resizable().scaledToFit()
            } else if library.rendering.contains(item.id) {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Developing…").font(.footnote).foregroundStyle(Theme.dim)
                }
            } else {
                ProgressView()
            }
        }
    }

    private var infoBar: some View {
        HStack(spacing: 8) {
            if let item = current {
                Tag(text: item.recipe.filmSimulation.badge, color: Theme.accent, filled: true)
                if let f = item.focalLength { Text("\(f)mm") }
                Spacer()
                if let info = item.exposureInfo { Text(info) }
            }
        }
        .font(Theme.mono(11, .semibold))
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Developed photos plus any still developing (e.g. the shot just taken); failed ones go to the editor instead.
    private func reloadItems() {
        items = library.items.filter { $0.renderedAt != nil || library.rendering.contains($0.id) }
        images.focus(on: selection, in: items, library: library)
    }

    private func deleteCurrent() {
        guard let i = items.firstIndex(where: { $0.id == selection }) else { return }
        let next = i + 1 < items.count ? items[i + 1] : (i > 0 ? items[i - 1] : nil)
        library.delete(items[i])
        if let next { selection = next.id } else { dismiss() }
    }

    private func saveToPhotos() {
        guard let item = current else { return }
        PhotoSaver.save(jpegURL: library.renderURL(item), rawURL: nil) { err in
            withAnimation { toast = err ?? "Saved to Photos" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { toast = nil } }
        }
    }
}

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
            && !library.rendering.contains(item.id) {
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
