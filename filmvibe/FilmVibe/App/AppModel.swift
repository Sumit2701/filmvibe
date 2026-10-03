import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let recipes = RecipeStore()
    let tuning = TuningStore()
    let library = LibraryStore()
    let settings = AppSettings()
    let camera = CameraController()

    /// The recipe loaded in the camera (may contain unsaved Q-menu tweaks).
    @Published var activeRecipe: Recipe {
        didSet {
            guard activeRecipe != oldValue else { return }
            settings.savedActiveRecipe = activeRecipe
            pushToCamera()
        }
    }

    private var bag = Set<AnyCancellable>()

    init() {
        let initial = settings.savedActiveRecipe ?? recipes.recipe(id: "retro-slide") ?? .neutral
        activeRecipe = initial
        camera.evComp = initial.exposureComp

        camera.onPhoto = { [weak self] photo in self?.store(photo) }
        camera.preferredFocal = settings.lastFocal
        library.upscaleCrops = settings.upscaleCrops

        camera.$currentFocal
            .dropFirst()
            .sink { [weak self] f in self?.settings.lastFocal = f }
            .store(in: &bag)
        settings.$upscaleCrops
            .dropFirst()
            .sink { [weak self] v in
                DispatchQueue.main.async {
                    self?.library.upscaleCrops = v
                    self?.pushToCamera()
                }
            }
            .store(in: &bag)

        tuning.$tuning
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pushToCamera() } }
            .store(in: &bag)
        settings.$liveFilmPreview
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pushToCamera() } }
            .store(in: &bag)

        pushToCamera()
        if settings.autoSaveToPhotos { PhotoSaver.requestAccess() }
    }

    func pushToCamera() {
        camera.update(recipe: activeRecipe, tuning: tuning.tuning, liveFilm: settings.liveFilmPreview,
                      upscaleCrops: settings.upscaleCrops)
    }

    // MARK: Recipe selection

    func select(_ r: Recipe) {
        activeRecipe = r
        camera.evComp = r.exposureComp
    }

    /// The stored version of the active recipe (nil if it's been deleted).
    var storedActive: Recipe? { recipes.recipe(id: activeRecipe.id) }
    var isActiveModified: Bool { storedActive.map { $0 != activeRecipe } ?? true }

    func saveActive() { recipes.save(activeRecipe) }

    func saveActiveAsNew(named name: String) {
        let r = activeRecipe.duplicated(named: name)
        recipes.save(r)
        activeRecipe = r
    }

    func revertActive() {
        if let r = storedActive { activeRecipe = r }
    }

    // MARK: Capture

    private func store(_ p: CapturedPhoto) {
        library.add(data: p.data, isRAW: p.isRAW, recipe: p.recipe, captureDRStops: p.captureDRStops,
                    exposureInfo: p.exposureInfo, nativeFocal: p.nativeFocal, crop: p.crop, tuning: tuning.tuning,
                    saveToPhotos: settings.autoSaveToPhotos, includeRAW: settings.saveRAWToPhotos)
    }

    func importPhoto(data: Data) -> PhotoItem? {
        guard let session = DevelopSession(data: data, captureDRStops: 0) else { return nil }
        return library.add(data: data, isRAW: session.isRAW, recipe: activeRecipe, captureDRStops: 0,
                           exposureInfo: "Imported", nativeFocal: nil, crop: nil, tuning: tuning.tuning,
                           saveToPhotos: false, includeRAW: false)
    }
}
