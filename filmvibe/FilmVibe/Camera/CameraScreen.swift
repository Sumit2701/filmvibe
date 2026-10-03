import SwiftUI

struct CameraScreen: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var camera: CameraController

    @State private var showRecipes = false
    @State private var showQ = false
    @State private var showGallery = false
    @State private var showSettings = false
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    @State private var banner: String?
    @State private var bannerIsError = false
    @State private var bannerToken = 0
    @EnvironmentObject private var recipeStore: RecipeStore

    var body: some View {
        VStack(spacing: 0) {
            topBar
            viewfinder
            infoStrip
            Spacer(minLength: 0)
            ExposureDial(value: $camera.evComp)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
            bottomBar
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showRecipes) {
            RecipeBrowser(mode: .select)
        }
        .sheet(isPresented: $showQ) {
            QuickMenu()
                .presentationDetents([.fraction(0.5), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen()
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryScreen()
        }
        .onAppear { camera.start() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            Spacer(minLength: 0)
            Button { showRecipes = true } label: {
                HStack(spacing: 6) {
                    Tag(text: app.activeRecipe.filmSimulation.badge, color: Theme.accent, filled: true)
                    Text(app.activeRecipe.name)
                        .font(Theme.label(15, .semibold))
                        .lineLimit(1)
                    if app.isActiveModified {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.panel2, in: Capsule())
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Tag(text: camera.captureFormatLabel.isEmpty ? "…" : camera.captureFormatLabel,
                    color: camera.captureFormatLabel == "RAW" ? Theme.accent : Theme.dim)
                Tag(text: drLabel)
            }
            .frame(width: 40, alignment: .trailing)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private func cycleFavorite(_ dir: Int) {
        let favs = recipeStore.favoriteRecipes
        guard !favs.isEmpty else {
            showBanner("Star recipes to swipe between them", error: false)
            return
        }
        let idx = favs.firstIndex { $0.id == app.activeRecipe.id }
        let next: Recipe
        if let idx {
            next = favs[(idx + dir + favs.count) % favs.count]
        } else {
            next = dir > 0 ? favs[0] : favs[favs.count - 1]
        }
        app.select(next)
        showBanner("★ \(next.name)", error: false)
    }

    private func showBanner(_ text: String, error: Bool) {
        bannerToken += 1
        let token = bannerToken
        withAnimation(.easeOut(duration: 0.2)) {
            banner = text
            bannerIsError = error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 4 : 1.6)) {
            if token == bannerToken { withAnimation(.easeIn(duration: 0.3)) { banner = nil } }
        }
    }

    private var drLabel: String {
        let r = app.activeRecipe
        return r.usesDRangePriority ? "DR-P" : r.dynamicRange.label.replacingOccurrences(of: "DR-Auto", with: "DR-A")
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                FilmPreview(camera: camera)
                if settings.showGrid { GridOverlay() }
                if let p = focusPoint {
                    FocusMarker()
                        .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                        .id(focusToken)
                }
                if camera.shutterBlink {
                    Color.black.opacity(0.85)
                }
                if camera.status == .denied {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text("Camera access is off.\nEnable it in Settings → FilmVibe.")
                            .multilineTextAlignment(.center)
                            .font(.callout)
                    }
                    .foregroundStyle(Theme.dim)
                }
                VStack {
                    Spacer()
                    HStack {
                        Text(app.activeRecipe.whiteBalance.summary)
                        Spacer()
                        if !settings.liveFilmPreview { Text("LIVE FILM OFF") }
                    }
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let p = CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height)
                focusPoint = p
                focusToken += 1
                camera.focus(at: p)
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { v in
                        let dx = v.translation.width, dy = v.translation.height
                        guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                        cycleFavorite(dx < 0 ? 1 : -1)
                    }
            )
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
        .overlay(alignment: .top) {
            if let banner {
                HStack(spacing: 6) {
                    Image(systemName: bannerIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(banner).lineLimit(2)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(bannerIsError ? Color.orange : Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 10)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: library.lastSave) { _, result in
            guard let result else { return }
            showBanner(result.message, error: !result.ok)
        }
    }

    // MARK: Info strip

    private var infoStrip: some View {
        HStack(spacing: 14) {
            Text("\(camera.currentFocal)mm")
                .foregroundStyle(Theme.accent)
            Text(camera.readout.shutter)
            Text(camera.readout.aperture)
            Menu {
                Button("Auto") { camera.isoSetting = .auto }
                ForEach(isoChoices, id: \.self) { v in
                    Button("ISO \(Int(v))") { camera.isoSetting = .manual(v) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(camera.readout.iso)
                    if case .manual = camera.isoSetting { Tag(text: "M", color: Theme.accent) } else { Tag(text: "A") }
                }
            }
            Spacer()
            Text("EV \(camera.evComp.evString)")
                .foregroundStyle(camera.evComp == 0 ? Theme.text : Theme.accent)
        }
        .font(Theme.mono(13, .semibold))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private var isoChoices: [Float] {
        let r = camera.isoRange
        return [32, 50, 64, 100, 125, 200, 400, 800, 1600, 3200, 6400].filter { r.contains($0) }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 14) {
            FocalSelector(options: camera.focalOptions, current: camera.currentFocal) { camera.selectFocal($0) }

            HStack {
                Button { showGallery = true } label: {
                    LastShotThumb()
                }
                Spacer()
                ShutterButton(busy: camera.isBusy) { camera.capture() }
                Spacer()
                Button { showQ = true } label: {
                    Text("Q")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .frame(width: 54, height: 54)
                        .foregroundStyle(Theme.text)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel2))
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 18)
    }
}

// MARK: - Pieces

/// Fixed focal lengths, like prime lenses: physical lenses plus centre crops (35mm equivalent).
struct FocalSelector: View {
    let options: [FocalOption]
    let current: Int
    let select: (FocalOption) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options) { o in
                let selected = o.focal == current
                Button { select(o) } label: {
                    Text("\(o.focal)")
                        .font(Theme.mono(13, .bold))
                        .frame(minWidth: 40, minHeight: 34)
                        .foregroundStyle(selected ? Color.black : (o.isNative ? Theme.text : Theme.dim))
                        .background(Capsule().fill(selected ? Theme.accent : Theme.panel2))
                        .overlay(Capsule().stroke(o.isNative && !selected ? Theme.faint : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text("mm")
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Theme.dim)
        }
        .sensoryFeedback(.selection, trigger: current)
        .opacity(options.isEmpty ? 0 : 1)
    }
}

struct LastShotThumb: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Theme.panel2)
            if let item = library.items.first, let img = library.thumbnail(item) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .id(library.revision)
            } else {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(Theme.dim)
            }
            if let item = library.items.first, library.rendering.contains(item.id) {
                ProgressView().tint(.white)
            }
        }
        .frame(width: 54, height: 54)
    }
}

struct ShutterButton: View {
    var busy: Bool
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Theme.text, lineWidth: 4).frame(width: 78, height: 78)
                Circle()
                    .fill(busy ? Theme.accent : Theme.text)
                    .frame(width: 64, height: 64)
                    .scaleEffect(pressed ? 0.9 : 1)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.easeOut(duration: 0.12)) { pressed = false } })
        .sensoryFeedback(.impact(weight: .medium), trigger: busy) { _, new in new }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

struct FocusMarker: View {
    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Theme.accent, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { scale = 1 }
                withAnimation(.easeIn(duration: 0.6).delay(1.2)) { opacity = 0 }
            }
            .allowsHitTesting(false)
    }
}

/// Horizontal exposure-compensation ruler, −3…+3 EV in thirds.
struct ExposureDial: View {
    @Binding var value: Double
    @State private var dragStart: Double?
    private let spacing: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            ZStack {
                Canvas { ctx, size in
                    for i in -9...9 {
                        let x = mid + CGFloat(Double(i) - value * 3) * spacing
                        guard x > -20, x < size.width + 20 else { continue }
                        let major = i % 3 == 0
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: major ? 6 : 10))
                        path.addLine(to: CGPoint(x: x, y: major ? 20 : 17))
                        let active = abs(Double(i) / 3 - value) < 0.01
                        ctx.stroke(path, with: .color(active ? Theme.accent : (major ? Theme.text : Theme.faint)), lineWidth: major ? 1.5 : 1)
                        if major {
                            let label = i == 0 ? "0" : (i > 0 ? "+\(i / 3)" : "\(i / 3)")
                            ctx.draw(Text(label).font(Theme.mono(10, .semibold)).foregroundColor(Theme.dim),
                                     at: CGPoint(x: x, y: 32))
                        }
                    }
                }
                Path { p in
                    p.move(to: CGPoint(x: mid - 5, y: 0))
                    p.addLine(to: CGPoint(x: mid + 5, y: 0))
                    p.addLine(to: CGPoint(x: mid, y: 6))
                    p.closeSubpath()
                }
                .fill(Theme.accent)
            }
        }
        .frame(height: 42)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    let raw = (dragStart ?? 0) - Double(g.translation.width / spacing) / 3
                    let snapped = min(max((raw * 3).rounded() / 3, -3), 3)
                    if abs(snapped - value) > 1e-6 { value = snapped }
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { value = 0 }
        .sensoryFeedback(.selection, trigger: value)
    }
}

// MARK: - Q menu

/// Quick menu: live-edit every setting of the loaded recipe while watching the viewfinder.
struct QuickMenu: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var askName = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                RecipeSettingsForm(recipe: $app.activeRecipe, showExposure: false)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(app.activeRecipe.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if app.isActiveModified {
                        Button("Revert") { app.revertActive() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Save to “\(app.activeRecipe.name)”") { app.saveActive() }
                            .disabled(!app.isActiveModified)
                        Button("Save as New Recipe…") {
                            newName = app.activeRecipe.name + " (mine)"
                            askName = true
                        }
                    } label: {
                        Text("Save").fontWeight(.semibold)
                    }
                }
            }
            .alert("New Recipe", isPresented: $askName) {
                TextField("Name", text: $newName)
                Button("Save") { app.saveActiveAsNew(named: newName) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
