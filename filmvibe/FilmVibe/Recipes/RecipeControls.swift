import SwiftUI

/// The full set of Fujifilm image-quality settings for a recipe, laid out like the camera's IQ menu.
struct RecipeSettingsForm: View {
    @Binding var recipe: Recipe
    var showExposure = true

    var body: some View {
        Group {
            Section {
                FilmSimPicker(selection: $recipe.filmSimulation)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } header: { SectionTitle("Film Simulation") }

            Section {
                SegmentRow(title: "Dynamic Range", selection: $recipe.dynamicRange, options: DynamicRange.allCases) { $0.label.replacingOccurrences(of: "DR-", with: "") }
                    .disabled(recipe.usesDRangePriority)
                    .opacity(recipe.usesDRangePriority ? 0.4 : 1)
                SegmentRow(title: "D-Range Priority", selection: $recipe.dRangePriority, options: DRangePriority.allCases) { $0.label }
                StepRow(title: "Highlight", value: $recipe.highlight, range: -2...4, step: 0.5) { $0.toneString }
                    .disabled(recipe.usesDRangePriority)
                    .opacity(recipe.usesDRangePriority ? 0.4 : 1)
                StepRow(title: "Shadow", value: $recipe.shadow, range: -2...4, step: 0.5) { $0.toneString }
                    .disabled(recipe.usesDRangePriority)
                    .opacity(recipe.usesDRangePriority ? 0.4 : 1)
            } header: { SectionTitle("Tone") }

            Section {
                if recipe.filmSimulation.isMonochrome {
                    StepRow(title: "Mono Color WC", value: intBinding(\.monoWC), range: -18...18, step: 1) { Int($0).signedString }
                    StepRow(title: "Mono Color MG", value: intBinding(\.monoMG), range: -18...18, step: 1) { Int($0).signedString }
                } else {
                    StepRow(title: "Color", value: intBinding(\.color), range: -4...4, step: 1) { Int($0).signedString }
                }
                SegmentRow(title: "Color Chrome Effect", selection: $recipe.colorChrome, options: EffectLevel.allCases) { $0.label }
                SegmentRow(title: "Color Chrome FX Blue", selection: $recipe.colorChromeBlue, options: EffectLevel.allCases) { $0.label }
            } header: { SectionTitle("Color") }

            Section {
                WhiteBalanceRows(wb: $recipe.whiteBalance)
            } header: { SectionTitle("White Balance") }

            Section {
                StepRow(title: "Sharpness", value: intBinding(\.sharpness), range: -4...4, step: 1) { Int($0).signedString }
                StepRow(title: "Clarity", value: intBinding(\.clarity), range: -5...5, step: 1) { Int($0).signedString }
                StepRow(title: "High ISO NR", value: intBinding(\.highISONR), range: -4...4, step: 1) { Int($0).signedString }
            } header: { SectionTitle("Detail") }

            Section {
                SegmentRow(title: "Grain Effect", selection: $recipe.grainEffect, options: EffectLevel.allCases) { $0.label }
                SegmentRow(title: "Grain Size", selection: $recipe.grainSize, options: GrainSize.allCases) { $0.label }
                    .disabled(recipe.grainEffect == .off)
                    .opacity(recipe.grainEffect == .off ? 0.4 : 1)
            } header: { SectionTitle("Grain") }

            if showExposure {
                Section {
                    StepRow(title: "Exposure Comp.", value: $recipe.exposureComp, range: -3...3, step: 1.0 / 3.0) { $0.evString }
                    if let note = recipe.exposureNote, !note.isEmpty {
                        Text("Recipe suggests \(note)")
                            .font(.footnote)
                            .foregroundStyle(Theme.dim)
                    }
                    HStack {
                        Text("ISO")
                        Spacer()
                        Text("Auto, up to \(recipe.isoMax)")
                            .font(Theme.mono(14))
                            .foregroundStyle(Theme.dim)
                    }
                } header: { SectionTitle("Exposure") }
            }
        }
    }

    private func intBinding(_ kp: WritableKeyPath<Recipe, Int>) -> Binding<Double> {
        Binding(get: { Double(recipe[keyPath: kp]) }, set: { recipe[keyPath: kp] = Int($0.rounded()) })
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11, .semibold))
            .foregroundStyle(Theme.accent)
    }
}

// MARK: - Rows

struct StepRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { change(-1) } label: {
                Image(systemName: "minus")
                    .frame(width: 34, height: 30)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(value <= range.lowerBound + 1e-6)

            Text(format(value))
                .font(Theme.mono(15, .semibold))
                .foregroundStyle(isDefault ? Theme.text : Theme.accent)
                .frame(minWidth: 58)
                .contentTransition(.numericText())
                .onTapGesture(count: 2) { value = min(max(0, range.lowerBound), range.upperBound) }

            Button { change(1) } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 30)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(value >= range.upperBound - 1e-6)
        }
        .sensoryFeedback(.selection, trigger: value)
    }

    private var isDefault: Bool { abs(value) < 1e-6 }

    private func change(_ dir: Double) {
        let steps = (value / step).rounded() + dir
        value = min(max(steps * step, range.lowerBound), range.upperBound)
        if abs(value) < 1e-9 { value = 0 }
    }
}

struct SegmentRow<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { o in Text(label(o)).tag(o) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 2)
    }
}

struct WhiteBalanceRows: View {
    @Binding var wb: WhiteBalance

    var body: some View {
        Picker("Mode", selection: $wb.mode) {
            ForEach(WBMode.allCases) { m in Text(m.label).tag(m) }
        }
        if wb.mode == .kelvin {
            VStack(spacing: 6) {
                StepRow(title: "Kelvin", value: Binding(get: { Double(wb.kelvin) }, set: { wb.kelvin = Int($0) }),
                        range: 2500...10000, step: 10) { "\(Int($0))K" }
                Slider(value: Binding(get: { Double(wb.kelvin) }, set: { wb.kelvin = Int(($0 / 50).rounded() * 50) }),
                       in: 2500...10000)
            }
        }
        StepRow(title: "Shift Red", value: Binding(get: { Double(wb.red) }, set: { wb.red = Int($0) }), range: -9...9, step: 1) { Int($0).signedString }
        StepRow(title: "Shift Blue", value: Binding(get: { Double(wb.blue) }, set: { wb.blue = Int($0) }), range: -9...9, step: 1) { Int($0).signedString }
    }
}

struct FilmSimPicker: View {
    @Binding var selection: FilmSimulation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilmSimulation.allCases) { sim in
                        Button { selection = sim } label: {
                            VStack(spacing: 4) {
                                Text(sim.badge)
                                    .font(Theme.mono(13, .bold))
                                    .frame(width: 54, height: 34)
                                    .foregroundStyle(selection == sim ? Color.black : Theme.text)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selection == sim ? Theme.accent : Theme.panel2)
                                    )
                                Text(sim.displayName)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(selection == sim ? Theme.accent : Theme.dim)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 64, height: 24, alignment: .top)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(sim)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}
