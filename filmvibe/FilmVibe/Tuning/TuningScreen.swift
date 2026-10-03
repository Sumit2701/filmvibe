import SwiftUI
import UIKit

@MainActor
final class TuningPreviewModel: ObservableObject {
    @Published var image: UIImage?
    @Published var hasSource = false
    private let renderer = PreviewRenderer()
    private var loadedID: String?
    private var framing = Framing.full
    private var ready = false
    private var last: (Recipe, EngineTuning)?

    func load(_ item: PhotoItem?, library: LibraryStore) {
        guard let item, item.id != loadedID else { return }
        loadedID = item.id
        framing = Framing(crop: item.effectiveCrop, upscale: library.upscaleCrops)
        ready = false
        renderer.load(url: library.originalURL(item), captureDRStops: item.captureDRStops) { [weak self] ok, _ in
            guard let self else { return }
            self.hasSource = ok
            self.ready = ok
            if let (r, t) = self.last { self.render(recipe: r, tuning: t) }
        }
    }

    func render(recipe: Recipe, tuning: EngineTuning) {
        last = (recipe, tuning)
        guard ready else { return }
        renderer.request(.init(recipe: recipe, tuning: tuning, postExposure: 0, longEdge: 1400, framing: framing) { [weak self] img in
            if let img { self?.image = img }
        })
    }
}

/// Global engine calibration: the strength of every camera setting step, and the character of each film simulation.
struct TuningScreen: View {
    @EnvironmentObject private var store: TuningStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var app: AppModel
    @StateObject private var preview = TuningPreviewModel()
    @State private var simKey: SimProfileKey = .nostalgicNeg
    @State private var previewSim = true
    @State private var copied = false
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var confirmReset = false

    private var d: EngineTuning { .defaults }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            List {
                simSection
                hueSection
                toneSection
                colorSection
                wbSection
                detailSection
                grainSection
                monoSection
                liveSection
                dataSection
            }
            .listStyle(.insetGrouped)
        }
        .background(Theme.background)
        .navigationTitle("Engine Tuning")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            simKey = app.activeRecipe.filmSimulation.profileKey
            preview.load(library.items.first, library: library)
            refresh()
        }
        .onChange(of: store.tuning) { _, _ in refresh() }
        .onChange(of: simKey) { _, _ in refresh() }
        .onChange(of: previewSim) { _, _ in refresh() }
        .onChange(of: app.activeRecipe) { _, _ in refresh() }
        .alert("Paste Tuning JSON", isPresented: $showPaste) {
            TextField("{ … }", text: $pasteText)
            Button("Import") { _ = store.importJSON(pasteText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Reset every tuning value to the built-in defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { store.resetAll() }
        }
    }

    private func refresh() {
        var r = app.activeRecipe
        if previewSim && r.filmSimulation.profileKey != simKey {
            r.filmSimulation = representative(simKey)
        }
        preview.render(recipe: r, tuning: store.tuning)
    }

    private func representative(_ k: SimProfileKey) -> FilmSimulation {
        FilmSimulation.allCases.first { $0.profileKey == k } ?? .provia
    }

    private var previewArea: some View {
        ZStack {
            Theme.panel
            if let img = preview.image {
                Image(uiImage: img).resizable().scaledToFit()
            } else if library.items.isEmpty {
                Text("Take or import a photo to preview tuning")
                    .font(.footnote).foregroundStyle(Theme.dim)
            } else {
                ProgressView()
            }
            VStack {
                Spacer()
                HStack {
                    Text(previewSim ? "\(app.activeRecipe.name) · \(simKey.displayName)" : app.activeRecipe.name)
                        .font(Theme.mono(10, .semibold))
                        .padding(5)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
                .padding(6)
            }
        }
        .frame(height: 280)
        .clipped()
    }

    // MARK: Sections

    private var simSection: some View {
        Section {
            Picker("Profile", selection: $simKey) {
                ForEach(SimProfileKey.allCases) { k in Text(k.displayName).tag(k) }
            }
            Toggle("Preview this profile", isOn: $previewSim)
            let def = EngineTuning.defaultSims[simKey.rawValue]!
            TuneSlider(title: "Contrast (mid slope)", value: sim(\.contrast), range: 0.08...0.3, def: def.contrast, digits: 3)
            TuneSlider(title: "Mid grey shift", value: sim(\.midShift), range: -0.1...0.1, def: def.midShift, digits: 3)
            TuneSlider(title: "Highlight range (stops)", value: sim(\.highlightRange), range: -1.5...2, def: def.highlightRange)
            TuneSlider(title: "Shadow range (stops)", value: sim(\.shadowRange), range: 3...10, def: def.shadowRange)
            TuneSlider(title: "Built-in Highlight (steps)", value: sim(\.highlightTone), range: -2...3, def: def.highlightTone)
            TuneSlider(title: "Built-in Shadow (steps)", value: sim(\.shadowTone), range: -2...3, def: def.shadowTone)
            TuneSlider(title: "Black lift", value: sim(\.blackLift), range: 0...0.1, def: def.blackLift, digits: 3)
            TuneSlider(title: "White cap", value: sim(\.whiteCap), range: 0.85...1, def: def.whiteCap, digits: 3)
            if !simKey.isMonochrome {
                TuneSlider(title: "Saturation", value: sim(\.saturation), range: 0...1.8, def: def.saturation)
                TuneSlider(title: "Shadow saturation", value: sim(\.shadowSaturation), range: 0.5...1.6, def: def.shadowSaturation)
                TuneSlider(title: "Highlight saturation", value: sim(\.highlightSaturation), range: 0.5...1.4, def: def.highlightSaturation)
                TuneSlider(title: "Shadow tint a (green↔magenta)", value: simArr(\.shadowTint, 0), range: -0.03...0.03, def: def.shadowTint[safe: 0], digits: 4)
                TuneSlider(title: "Shadow tint b (blue↔yellow)", value: simArr(\.shadowTint, 1), range: -0.03...0.03, def: def.shadowTint[safe: 1], digits: 4)
                TuneSlider(title: "Mid tint a", value: simArr(\.midTint, 0), range: -0.03...0.03, def: def.midTint[safe: 0], digits: 4)
                TuneSlider(title: "Mid tint b", value: simArr(\.midTint, 1), range: -0.03...0.03, def: def.midTint[safe: 1], digits: 4)
                TuneSlider(title: "Highlight tint a", value: simArr(\.highlightTint, 0), range: -0.03...0.03, def: def.highlightTint[safe: 0], digits: 4)
                TuneSlider(title: "Highlight tint b", value: simArr(\.highlightTint, 1), range: -0.03...0.03, def: def.highlightTint[safe: 1], digits: 4)
            } else {
                TuneSlider(title: "Toning a (green↔magenta)", value: simArr(\.monoTone, 0), range: -0.05...0.05, def: def.monoTone[safe: 0], digits: 4)
                TuneSlider(title: "Toning b (blue↔yellow)", value: simArr(\.monoTone, 1), range: -0.05...0.08, def: def.monoTone[safe: 1], digits: 4)
            }
            Button("Reset \(simKey.displayName) Profile") { store.resetSim(simKey) }
                .foregroundStyle(Theme.accent)
        } header: { SectionTitle("Film Simulation Character") }
    }

    @ViewBuilder
    private var hueSection: some View {
        if !simKey.isMonochrome {
            Section {
                let def = EngineTuning.defaultSims[simKey.rawValue]!
                ForEach(HueAnchor.allCases) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Circle().fill(hueColor(a)).frame(width: 10, height: 10)
                            Text(a.name).font(.subheadline.weight(.semibold))
                        }
                        TuneSlider(title: "Hue °", value: simArr(\.hueShift, a.rawValue), range: -30...30, def: def.hueShift[safe: a.rawValue], digits: 1, compact: true)
                        TuneSlider(title: "Saturation ×", value: simArr(\.hueSat, a.rawValue, fallback: 1), range: 0...2, def: def.hueSat[safe: a.rawValue, default: 1], compact: true)
                        TuneSlider(title: "Lightness", value: simArr(\.hueLum, a.rawValue), range: -0.25...0.25, def: def.hueLum[safe: a.rawValue], digits: 3, compact: true)
                    }
                }
            } header: { SectionTitle("\(simKey.displayName) · Per-Hue") }
        }
    }

    private var toneSection: some View {
        Section {
            TuneSlider(title: "Middle grey (display)", value: g(\.midGrey), range: 0.3...0.6, def: d.midGrey, digits: 3)
            TuneSlider(title: "RAW white (linear, DR100)", value: g(\.rawWhite), range: 0.8...4, def: d.rawWhite)
            TuneSlider(title: "RAW exposure offset (EV)", value: g(\.rawExposure), range: -2...2, def: d.rawExposure)
            TuneSlider(title: "DR stops multiplier", value: g(\.drStrength), range: 0...1.5, def: d.drStrength)
            TuneSlider(title: "DR-Auto stops", value: g(\.drAutoStops), range: 0...2, def: d.drAutoStops)
            TuneSlider(title: "Highlight: bump / step", value: g(\.highlightStep), range: 0...0.25, def: d.highlightStep, digits: 3)
            TuneSlider(title: "Highlight: headroom / −step", value: g(\.highlightRangeStep), range: 0...0.5, def: d.highlightRangeStep, digits: 3)
            TuneSlider(title: "Shadow: bump / step", value: g(\.shadowStep), range: 0...0.25, def: d.shadowStep, digits: 3)
            TuneSlider(title: "Highlight desat. knee", value: g(\.highlightKnee), range: 0.5...0.98, def: d.highlightKnee)
        } header: { SectionTitle("Tone · Dynamic Range · Highlight · Shadow") }
    }

    private var colorSection: some View {
        Section {
            TuneSlider(title: "Color: chroma / step", value: g(\.colorStep), range: 0...0.2, def: d.colorStep, digits: 3)
            TuneSlider(title: "Color Chrome Weak", value: g(\.cceWeak), range: 0...0.2, def: d.cceWeak, digits: 3)
            TuneSlider(title: "Color Chrome Strong", value: g(\.cceStrong), range: 0...0.3, def: d.cceStrong, digits: 3)
            TuneSlider(title: "FX Blue Weak", value: g(\.fxBlueWeak), range: 0...0.3, def: d.fxBlueWeak, digits: 3)
            TuneSlider(title: "FX Blue Strong", value: g(\.fxBlueStrong), range: 0...0.4, def: d.fxBlueStrong, digits: 3)
        } header: { SectionTitle("Color · Color Chrome") }
    }

    private var wbSection: some View {
        Section {
            TuneSlider(title: "WB shift: stops / step", value: g(\.wbShiftStep), range: 0...0.15, def: d.wbShiftStep, digits: 3)
            TuneSlider(title: "Daylight K", value: g(\.daylightK), range: 4500...6500, def: d.daylightK, digits: 0)
            TuneSlider(title: "Shade K", value: g(\.shadeK), range: 6000...9000, def: d.shadeK, digits: 0)
            TuneSlider(title: "Incandescent K", value: g(\.incandescentK), range: 2500...3600, def: d.incandescentK, digits: 0)
            TuneSlider(title: "Fluorescent 1 K", value: g(\.fluorescent1K), range: 3000...7500, def: d.fluorescent1K, digits: 0)
            TuneSlider(title: "Fluorescent 2 K", value: g(\.fluorescent2K), range: 2500...6000, def: d.fluorescent2K, digits: 0)
            TuneSlider(title: "Fluorescent 3 K", value: g(\.fluorescent3K), range: 2500...6000, def: d.fluorescent3K, digits: 0)
            TuneSlider(title: "Fluorescent tint", value: g(\.fluorescentTint), range: -40...40, def: d.fluorescentTint, digits: 0)
            TuneSlider(title: "Auto White Priority strength", value: g(\.autoWhiteStrength), range: 0...0.6, def: d.autoWhiteStrength)
            TuneSlider(title: "Auto Ambience strength", value: g(\.autoAmbienceStrength), range: 0...0.6, def: d.autoAmbienceStrength)
        } header: { SectionTitle("White Balance") }
    }

    private var detailSection: some View {
        Section {
            TuneSlider(title: "Sharpness at 0", value: g(\.sharpBase), range: 0...1.5, def: d.sharpBase)
            TuneSlider(title: "Sharpness / step", value: g(\.sharpStep), range: 0...0.5, def: d.sharpStep, digits: 3)
            TuneSlider(title: "Sharpen radius (px @4032)", value: g(\.sharpRadius), range: 0.5...3, def: d.sharpRadius)
            TuneSlider(title: "Clarity / step", value: g(\.clarityStep), range: 0...0.3, def: d.clarityStep, digits: 3)
            TuneSlider(title: "Clarity radius (px @4032)", value: g(\.clarityRadius), range: 5...80, def: d.clarityRadius, digits: 0)
            TuneSlider(title: "High ISO NR: log2 / step", value: g(\.nrStep), range: 0...1, def: d.nrStep)
            TuneSlider(title: "High ISO NR: add / step", value: g(\.nrAddStep), range: 0...0.15, def: d.nrAddStep, digits: 3)
            TuneSlider(title: "Colour NR floor", value: g(\.nrColorFloor), range: 0...0.6, def: d.nrColorFloor)
        } header: { SectionTitle("Sharpness · Clarity · Noise Reduction") }
    }

    private var grainSection: some View {
        Section {
            TuneSlider(title: "Grain Weak amount", value: g(\.grainWeak), range: 0...0.12, def: d.grainWeak, digits: 3)
            TuneSlider(title: "Grain Strong amount", value: g(\.grainStrong), range: 0...0.2, def: d.grainStrong, digits: 3)
            TuneSlider(title: "Small size (px @4032)", value: g(\.grainSmall), range: 0.5...4, def: d.grainSmall)
            TuneSlider(title: "Large size (px @4032)", value: g(\.grainLarge), range: 0.5...6, def: d.grainLarge)
            TuneSlider(title: "Midtone concentration", value: g(\.grainShape), range: 0...2, def: d.grainShape)
        } header: { SectionTitle("Grain Effect") }
    }

    private var monoSection: some View {
        Section {
            TuneSlider(title: "WC / MG per step", value: g(\.monoToneStep), range: 0...0.01, def: d.monoToneStep, digits: 4)
            TuneSlider(title: "Ye filter: blue pass", value: arr(\.filterYellow, 2), range: 0...1, def: d.filterYellow[2])
            TuneSlider(title: "R filter: green pass", value: arr(\.filterRed, 1), range: 0...1, def: d.filterRed[1])
            TuneSlider(title: "R filter: blue pass", value: arr(\.filterRed, 2), range: 0...1, def: d.filterRed[2])
            TuneSlider(title: "G filter: red pass", value: arr(\.filterGreen, 0), range: 0...1, def: d.filterGreen[0])
            TuneSlider(title: "G filter: blue pass", value: arr(\.filterGreen, 2), range: 0...1, def: d.filterGreen[2])
        } header: { SectionTitle("Monochrome") }
    }

    private var liveSection: some View {
        Section {
            TuneSlider(title: "Live contrast factor", value: g(\.previewContrast), range: 0.5...1.2, def: d.previewContrast)
            TuneSlider(title: "Live grain boost", value: g(\.previewGrain), range: 0...4, def: d.previewGrain)
        } header: { SectionTitle("Live Viewfinder") } footer: {
            Text("The live feed is already processed by iOS, so these keep the viewfinder close to the final RAW render.")
        }
    }

    private var dataSection: some View {
        Section {
            Button(copied ? "Copied ✓" : "Copy Tuning as JSON") {
                UIPasteboard.general.string = store.json
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            Button("Paste Tuning JSON…") {
                pasteText = UIPasteboard.general.string ?? ""
                showPaste = true
            }
            Button("Reset All to Defaults", role: .destructive) { confirmReset = true }
        } header: { SectionTitle("Share / Restore") } footer: {
            Text("Tuning applies to every recipe: e.g. “Shadow: bump / step” changes what Shadow +1 means everywhere.")
        }
    }

    // MARK: Bindings

    private func g(_ kp: WritableKeyPath<EngineTuning, Double>) -> Binding<Double> {
        Binding(get: { store.tuning[keyPath: kp] }, set: { store.tuning[keyPath: kp] = $0 })
    }

    private func arr(_ kp: WritableKeyPath<EngineTuning, [Double]>, _ i: Int) -> Binding<Double> {
        Binding(get: { store.tuning[keyPath: kp][safe: i, default: 1] },
                set: { v in var a = store.tuning[keyPath: kp]; while a.count <= i { a.append(1) }; a[i] = v; store.tuning[keyPath: kp] = a })
    }

    private func sim(_ kp: WritableKeyPath<SimProfile, Double>) -> Binding<Double> {
        let key = simKey
        return Binding(get: { store.tuning.profile(key)[keyPath: kp] },
                       set: { v in var p = store.tuning.profile(key); p[keyPath: kp] = v; store.tuning.sims[key.rawValue] = p })
    }

    private func simArr(_ kp: WritableKeyPath<SimProfile, [Double]>, _ i: Int, fallback: Double = 0) -> Binding<Double> {
        let key = simKey
        return Binding(get: { store.tuning.profile(key)[keyPath: kp][safe: i, default: fallback] },
                       set: { v in
                           var p = store.tuning.profile(key)
                           var a = p[keyPath: kp]
                           while a.count <= i { a.append(fallback) }
                           a[i] = v
                           p[keyPath: kp] = a
                           store.tuning.sims[key.rawValue] = p
                       })
    }

    private func hueColor(_ a: HueAnchor) -> Color {
        [Color.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink][a.rawValue]
    }
}

struct TuneSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let def: Double
    var digits = 2
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 2) {
            HStack {
                Text(title)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(compact ? Theme.dim : Theme.text)
                Spacer()
                Text(String(format: "%.\(digits)f", value))
                    .font(Theme.mono(compact ? 11 : 13, .semibold))
                    .foregroundStyle(abs(value - def) < 1e-9 ? Theme.dim : Theme.accent)
                    .onTapGesture(count: 2) { value = def }
            }
            Slider(value: $value, in: range)
                .controlSize(compact ? .mini : .small)
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tuning: TuningStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Live film look in viewfinder", isOn: $settings.liveFilmPreview)
                    Toggle("Grid", isOn: $settings.showGrid)
                } header: { SectionTitle("Viewfinder") }

                Section {
                    Toggle("Save developed JPEG to Photos", isOn: $settings.autoSaveToPhotos)
                    Toggle("Attach RAW (DNG) in Photos", isOn: $settings.saveRAWToPhotos)
                        .disabled(!settings.autoSaveToPhotos)
                    Toggle("Upscale 28–70mm crops to 12 MP", isOn: $settings.upscaleCrops)
                } header: { SectionTitle("Capture") } footer: {
                    Text("Every shot is a pure Bayer RAW straight off the sensor — no Smart HDR, Deep Fusion or tone mapping. The RAW stays in FilmVibe's library (also visible in the Files app), so you can re-develop it with any recipe later.\n\nFocal lengths other than the physical lenses are centre crops stored with the RAW (change them later in the editor). With upscaling on, crops are enlarged back to full resolution like Fujifilm's Digital Teleconverter; off keeps the native pixels.")
                }

                Section {
                    NavigationLink {
                        TuningScreen()
                    } label: {
                        Label("Engine Tuning", systemImage: "slider.horizontal.below.square.filled.and.square")
                    }
                } header: { SectionTitle("Look") } footer: {
                    Text("Adjust how strong each step of Highlight, Shadow, Color, Clarity, Grain, Color Chrome, WB shift … is, and the character of every film simulation.")
                }

                Section {
                    LabeledContent("Photos in library", value: "\(library.items.count)")
                    Button {
                        library.redevelopAll(tuning: tuning.tuning)
                    } label: {
                        HStack {
                            Text("Re-develop All Photos")
                            Spacer()
                            if !library.rendering.isEmpty { ProgressView() }
                        }
                    }
                    .disabled(library.items.isEmpty || !library.rendering.isEmpty)
                    Link(destination: URL(string: "https://fujixweekly.com/fujifilm-x-trans-v-recipes/")!) {
                        Label("Recipes from Fuji X Weekly", systemImage: "safari")
                    }
                } header: { SectionTitle("About") } footer: {
                    Text("Film simulation recipes by Ritchie Roesch / fujixweekly.com. FilmVibe is an independent emulation and is not affiliated with Fujifilm.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
    }
}
