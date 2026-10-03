import SwiftUI

struct RecipeBrowser: View {
    enum Mode { case select, apply((Recipe) -> Void) }

    var mode: Mode = .select

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: RecipeStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tuning: TuningStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = RecipeThumbnailer.shared
    @State private var query = ""
    @State private var editing: Recipe?
    @State private var simFilter: SimProfileKey?

    var body: some View {
        NavigationStack {
            List {
                if simFilter != nil || !query.isEmpty {
                    Text("\(filteredCount) recipes")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                }
                ForEach(filteredSections, id: \.0) { section in
                    Section {
                        ForEach(section.1) { r in
                            row(r)
                        }
                    } header: {
                        SectionTitle(section.0)
                    } footer: {
                        if section.0 == RecipeStore.favoritesSection {
                            Text("Swipe left / right on the viewfinder to switch between favorites.")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search recipes, film sims…")
            .navigationTitle("Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Menu {
                            Button("All Film Simulations") { simFilter = nil }
                            ForEach(SimProfileKey.allCases) { k in
                                Button(k.displayName) { simFilter = k }
                            }
                        } label: {
                            Image(systemName: simFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                        Button {
                            editing = app.activeRecipe.duplicated(named: "New Recipe")
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(item: $editing) { r in
                RecipeEditor(recipe: r)
            }
            .onAppear { thumbs.setSource(library.items.first, library: library) }
        }
    }

    private var filteredSections: [(String, [Recipe])] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return store.sections.compactMap { name, list in
            let f = list.filter { r in
                (simFilter == nil || r.filmSimulation.profileKey == simFilter) &&
                (q.isEmpty || r.name.lowercased().contains(q) || r.filmSimulation.displayName.lowercased().contains(q)
                 || r.category.lowercased().contains(q))
            }
            return f.isEmpty ? nil : (name, f)
        }
    }

    private var filteredCount: Int { filteredSections.reduce(0) { $0 + $1.1.count } }

    @ViewBuilder
    private func row(_ r: Recipe) -> some View {
        let isActive = r.id == app.activeRecipe.id
        let fav = store.isFavorite(r.id)
        HStack(spacing: 12) {
            Button {
                switch mode {
                case .select:
                    app.select(r)
                case .apply(let f):
                    f(r)
                }
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    RecipeThumb(recipe: r)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(r.name)
                                .font(Theme.label(16, .semibold))
                                .foregroundStyle(isActive ? Theme.accent : Theme.text)
                            if store.isModifiedBuiltIn(r.id) { Tag(text: "EDITED", color: Theme.accent) }
                            if isActive { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Theme.accent) }
                        }
                        Text(r.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation { store.toggleFavorite(r.id) }
            } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 18))
                    .foregroundStyle(fav ? Theme.accent : Theme.faint)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .sensoryFeedback(.impact(weight: .light), trigger: fav)
        }
        .swipeActions(edge: .trailing) {
            if !store.isBuiltIn(r.id) {
                Button(role: .destructive) { store.delete(r) } label: { Label("Delete", systemImage: "trash") }
            } else if store.isModifiedBuiltIn(r.id) {
                Button { store.delete(r) } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
                    .tint(.orange)
            }
            Button { editing = r } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button { editing = r.duplicated(named: r.name + " copy") } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .tint(.indigo)
        }
        .contextMenu {
            Button { editing = r } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            Button { editing = r.duplicated(named: r.name + " copy") } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if let s = r.source, let url = URL(string: s) {
                Link(destination: url) { Label("Open on Fuji X Weekly", systemImage: "safari") }
            }
        }
    }
}

struct RecipeThumb: View {
    let recipe: Recipe
    @EnvironmentObject private var tuning: TuningStore
    @ObservedObject private var thumbs = RecipeThumbnailer.shared

    var body: some View {
        let img = thumbs.image(for: recipe, tuning: tuning.tuning, version: tuning.version)
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.panel2)
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(recipe.filmSimulation.badge)
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .id(thumbs.revision)
    }
}

struct RecipeEditor: View {
    @State var recipe: Recipe
    @EnvironmentObject private var store: RecipeStore
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $recipe.name)
                    TextField("Category", text: $recipe.category)
                    if let s = recipe.source, let url = URL(string: s) {
                        Link(destination: url) {
                            Label("Original recipe on Fuji X Weekly", systemImage: "safari")
                        }
                    }
                } header: { SectionTitle("Recipe") }
                RecipeSettingsForm(recipe: $recipe)
                if store.isModifiedBuiltIn(recipe.id), let original = store.original(recipe.id) {
                    Section {
                        Button("Reset to Original Settings") { recipe = original }
                    }
                }
            }
            .navigationTitle(recipe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.save(recipe)
                        if app.activeRecipe.id == recipe.id { app.activeRecipe = recipe }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
