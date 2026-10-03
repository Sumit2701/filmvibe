import PhotosUI
import SwiftUI

enum GalleryRoute: Hashable {
    case allPhotos
    case photo(String)
    case editor(String)
}

/// The photo side of the app, laid out like the iOS Camera roll: the camera's thumbnail opens the latest photo
/// full screen, back (or swipe down) returns to the camera, and "All Photos" opens the grid.
struct GalleryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tuning: TuningStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [GalleryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            PhotoViewer(origin: .camera, startAt: library.items.first?.id, onClose: { dismiss() },
                        onAllPhotos: { path.append(.allPhotos) }, onEdit: edit)
                .navigationDestination(for: GalleryRoute.self) { route in
                    switch route {
                    case .allPhotos:
                        LibraryGrid { path.append(.photo($0.id)) }
                    case .photo(let id):
                        PhotoViewer(origin: .grid, startAt: id, onClose: { path.removeLast() }, onEdit: edit)
                    case .editor(let id):
                        // Only a failed develop still has its original to work on.
                        if let item = library.items.first(where: { $0.id == id }) {
                            EditorScreen(item: item, library: library, tuning: tuning.tuning)
                        }
                    }
                }
        }
    }

    private func edit(_ item: PhotoItem) { path.append(.editor(item.id)) }
}

// MARK: - All Photos

/// Every photo, oldest first with the newest at the bottom like the Photos app. Select mode shares or deletes several.
struct LibraryGrid: View {
    @EnvironmentObject private var library: LibraryStore
    let open: (PhotoItem) -> Void

    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pendingDelete: [PhotoItem] = []
    @State private var confirmDelete = false
    @State private var share: ShareURLs?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private var items: [PhotoItem] { library.items.reversed() }
    private var selectedItems: [PhotoItem] { items.filter { selected.contains($0.id) } }

    var body: some View {
        ScrollView {
            if library.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture").font(.system(size: 44))
                    Text("No photos yet").font(.headline)
                    Text("Shoot with the camera, or import RAW / photos from your library.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    ImportButton { Text("Import Photos") }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                }
                .foregroundStyle(Theme.dim)
                .padding(.top, 120)
                .padding(.horizontal, 40)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    GalleryCell(item: item, selected: selecting ? selected.contains(item.id) : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { tap(item) }
                        .contextMenu {
                            if !selecting {
                                if item.renderedAt != nil {
                                    Button { share = ShareURLs(urls: [library.renderURL(item)]) } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                }
                                Button(role: .destructive) { askDelete([item]) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .background(Theme.background)
        .navigationTitle("All Photos")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        .toolbar { toolbar }
        .toolbar(selecting ? .visible : .hidden, for: .bottomBar)
        .sheet(item: $share) { s in ShareSheet(items: s.urls) }
        .confirmationDialog("Delete", isPresented: $confirmDelete, titleVisibility: .hidden, presenting: pendingDelete) { doomed in
            Button(doomed.count == 1 ? "Delete Photo" : "Delete \(doomed.count) Photos", role: .destructive) {
                doomed.forEach(library.delete)
                selected = []
                selecting = false
            }
        } message: { doomed in
            Text("\(doomed.count == 1 ? "It's" : "They're") removed from FilmVibe. Copies already saved to Photos are kept.")
        }
        .onChange(of: library.items) { _, new in selected.formIntersection(new.map(\.id)) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selecting {
                Button("Cancel") {
                    selecting = false
                    selected = []
                }
                .fontWeight(.semibold)
            } else {
                ImportButton { Image(systemName: "plus") }
                    .accessibilityLabel("Import")
                Button("Select") { selecting = true }
                    .disabled(library.items.isEmpty)
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    let urls = selectedItems.filter { $0.renderedAt != nil }.map(library.renderURL)
                    if !urls.isEmpty { share = ShareURLs(urls: urls) }
                } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
                .disabled(selected.isEmpty)
                Spacer()
                Text(selected.isEmpty ? "Select Items" : "\(selected.count) Photo\(selected.count == 1 ? "" : "s") Selected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { askDelete(selectedItems) } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete")
                    .disabled(selected.isEmpty)
            }
        }
    }

    private func tap(_ item: PhotoItem) {
        guard selecting else { return open(item) }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func askDelete(_ list: [PhotoItem]) {
        guard !list.isEmpty else { return }
        pendingDelete = list
        confirmDelete = true
    }
}

struct ShareURLs: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct GalleryCell: View {
    let item: PhotoItem
    /// nil outside select mode.
    var selected: Bool?
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Color(Theme.panel)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = library.thumbnail(item) {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    Tag(text: item.recipe.filmSimulation.badge, color: .white)
                    if item.isRAW { Tag(text: "RAW", color: Theme.accent) }
                }
                .padding(4)
                .shadow(radius: 2)
            }
            .overlay {
                if library.rendering.contains(item.id) { ProgressView().tint(.white) }
            }
            .overlay {
                if selected == true { Color.white.opacity(0.15) }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .clipped()
    }
}

/// Picks RAW / photos from the system library and develops them with the active recipe.
struct ImportButton<Label: View>: View {
    @EnvironmentObject private var app: AppModel
    @ViewBuilder let label: () -> Label
    @State private var picks: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        PhotosPicker(selection: $picks, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current) {
            if importing { ProgressView() } else { label() }
        }
        .disabled(importing)
        .onChange(of: picks) { _, new in
            guard !new.isEmpty else { return }
            importing = true
            Task {
                for p in new {
                    if let data = try? await p.loadTransferable(type: Data.self) {
                        _ = app.importPhoto(data: data)
                    }
                }
                picks = []
                importing = false
            }
        }
    }
}
