import Foundation
import Combine
import SwiftUI

enum AppPaths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let library = documents.appendingPathComponent("Library", isDirectory: true)
    static let userRecipes = documents.appendingPathComponent("recipes_user.json")
    static let tuning = documents.appendingPathComponent("tuning.json")
}

// MARK: - Recipes

@MainActor
final class RecipeStore: ObservableObject {
    @Published private(set) var builtIn: [Recipe] = []
    @Published private(set) var custom: [Recipe] = []
    @Published private(set) var overrides: [String: Recipe] = [:]
    /// Starred recipe ids, in the order they were starred.
    @Published private(set) var favorites: [String] = []

    private struct UserFile: Codable {
        var custom: [Recipe]
        var overrides: [String: Recipe]
        var favorites: [String]?
    }

    init() {
        if let url = Bundle.main.url(forResource: "Recipes", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Recipe].self, from: data) {
            builtIn = list
        }
        if let data = try? Data(contentsOf: AppPaths.userRecipes),
           let file = try? JSONDecoder().decode(UserFile.self, from: data) {
            custom = file.custom
            overrides = file.overrides
            favorites = file.favorites ?? []
        }
    }

    // MARK: Favorites

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
        persist()
    }

    var favoriteRecipes: [Recipe] { favorites.compactMap { recipe(id: $0) } }

    var all: [Recipe] { custom + builtIn.map { overrides[$0.id] ?? $0 } }

    func recipe(id: String) -> Recipe? { all.first { $0.id == id } }

    func isBuiltIn(_ id: String) -> Bool { builtIn.contains { $0.id == id } }
    func isModifiedBuiltIn(_ id: String) -> Bool { overrides[id] != nil }
    func original(_ id: String) -> Recipe? { builtIn.first { $0.id == id } }

    /// Grouped for display. "My Recipes" first, then the Fuji X Weekly categories in source order.
    var sections: [(String, [Recipe])] {
        var order: [String] = []
        var groups: [String: [Recipe]] = [:]
        for r in all {
            if groups[r.category] == nil { order.append(r.category) }
            groups[r.category, default: []].append(r)
        }
        let favs = favoriteRecipes
        return (favs.isEmpty ? [] : [(Self.favoritesSection, favs)]) + order.map { ($0, groups[$0]!) }
    }

    static let favoritesSection = "★ Favorites"

    func save(_ r: Recipe) {
        if isBuiltIn(r.id) {
            if let o = original(r.id), o == r { overrides[r.id] = nil } else { overrides[r.id] = r }
        } else if let i = custom.firstIndex(where: { $0.id == r.id }) {
            custom[i] = r
        } else {
            custom.insert(r, at: 0)
        }
        persist()
    }

    /// Deletes a custom recipe, or reverts a modified built-in one.
    func delete(_ r: Recipe) {
        if isBuiltIn(r.id) {
            overrides[r.id] = nil
        } else {
            custom.removeAll { $0.id == r.id }
            favorites.removeAll { $0 == r.id }
        }
        persist()
    }

    private func persist() {
        let file = UserFile(custom: custom, overrides: overrides, favorites: favorites)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: AppPaths.userRecipes, options: .atomic)
        }
    }
}

// MARK: - Engine tuning

@MainActor
final class TuningStore: ObservableObject {
    @Published var tuning: EngineTuning {
        didSet {
            guard tuning != oldValue else { return }
            version &+= 1
            scheduleSave()
        }
    }
    /// Bumps on every change; used to invalidate cached renders.
    @Published private(set) var version = 0
    private var saveWork: DispatchWorkItem?

    init() {
        if let data = try? Data(contentsOf: AppPaths.tuning), let t = EngineTuning.decodeMerged(from: data) {
            tuning = t
        } else {
            tuning = .defaults
        }
    }

    func resetAll() { tuning = .defaults }

    func resetSim(_ key: SimProfileKey) {
        tuning.sims[key.rawValue] = EngineTuning.defaultSims[key.rawValue]
    }

    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(tuning), encoding: .utf8) ?? "") ?? ""
    }

    @discardableResult
    func importJSON(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8), let t = EngineTuning.decodeMerged(from: data) else { return false }
        tuning = t
        return true
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = tuning
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: AppPaths.tuning, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var autoSaveToPhotos: Bool { didSet { d.set(autoSaveToPhotos, forKey: "autoSaveToPhotos") } }
    @Published var saveRAWToPhotos: Bool { didSet { d.set(saveRAWToPhotos, forKey: "saveRAWToPhotos") } }
    @Published var liveFilmPreview: Bool { didSet { d.set(liveFilmPreview, forKey: "liveFilmPreview") } }
    @Published var showGrid: Bool { didSet { d.set(showGrid, forKey: "showGrid") } }
    /// Upscale focal-length crops back to full resolution (like Fuji's Digital Teleconverter).
    @Published var upscaleCrops: Bool { didSet { d.set(upscaleCrops, forKey: "upscaleCrops") } }
    @Published var lastFocal: Int { didSet { d.set(lastFocal, forKey: "lastFocal") } }

    init() {
        autoSaveToPhotos = d.object(forKey: "autoSaveToPhotos") as? Bool ?? true
        saveRAWToPhotos = d.object(forKey: "saveRAWToPhotos") as? Bool ?? false
        liveFilmPreview = d.object(forKey: "liveFilmPreview") as? Bool ?? true
        showGrid = d.object(forKey: "showGrid") as? Bool ?? true
        upscaleCrops = d.object(forKey: "upscaleCrops") as? Bool ?? true
        lastFocal = d.object(forKey: "lastFocal") as? Int ?? 26
    }

    /// The recipe loaded in the camera, including unsaved Q-menu tweaks.
    var savedActiveRecipe: Recipe? {
        get {
            guard let data = d.data(forKey: "activeRecipe") else { return nil }
            return try? JSONDecoder().decode(Recipe.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "activeRecipe") }
        }
    }
}
