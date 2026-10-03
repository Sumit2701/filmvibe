import PhotosUI
import SwiftUI

struct GalleryScreen: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tuning: TuningStore
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [PhotosPickerItem] = []
    @State private var path: [PhotoItem] = []
    @State private var importing = false

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if library.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.aperture").font(.system(size: 44))
                        Text("No photos yet").font(.headline)
                        Text("Shoot with the camera, or import RAW / photos from your library.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 120)
                    .padding(.horizontal, 40)
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.items) { item in
                        NavigationLink(value: item) {
                            GalleryCell(item: item)
                        }
                        .contextMenu {
                            Button(role: .destructive) { library.delete(item) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PhotoItem.self) { item in
                EditorScreen(item: item, library: library, tuning: tuning.tuning)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Camera") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $picks, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current) {
                        if importing { ProgressView() } else { Image(systemName: "square.and.arrow.down") }
                    }
                }
            }
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
}

struct GalleryCell: View {
    let item: PhotoItem
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
            .clipped()
            .id("\(item.id)-\(library.revision)")
    }
}
