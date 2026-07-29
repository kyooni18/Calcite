import AppKit
import SwiftUI

struct ThemeBuilderView: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var session: ThemeBuilderSession
  @State private var searchText = ""

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      HSplitView {
        tokenBrowser
          .frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
        tokenEditor
          .frame(minWidth: 250, idealWidth: 310, maxWidth: 390)
        preview
          .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(controller.profile.workbench.windowBackground.color)
    .onAppear { session.beginEditing() }
    .onDisappear { session.endEditing() }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Label("Theme Builder", systemImage: "paintpalette")
        .font(.headline)

      Picker("Theme", selection: activeSlotBinding) {
        ForEach(EditorThemeSlot.allCases) { slot in
          Text(slot.title).tag(slot)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 150)

      Menu("Copy Theme", systemImage: "square.on.square") {
        Button("Copy Light to Dark") { session.copyTheme(from: .light, to: .dark) }
        Button("Copy Dark to Light") { session.copyTheme(from: .dark, to: .light) }
      }

      Spacer()

      Button("Undo", systemImage: "arrow.uturn.backward") { session.undo() }
        .disabled(!session.canUndo)
        .labelStyle(.iconOnly)
      Button("Redo", systemImage: "arrow.uturn.forward") { session.redo() }
        .disabled(!session.canRedo)
        .labelStyle(.iconOnly)

      if session.isDirty {
        Text("Modified")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Revert", role: .destructive) { session.discard() }
        Button("Keep Changes") { session.save() }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 42)
    .background(controller.profile.workbench.toolbarBackground.color)
  }

  private var tokenBrowser: some View {
    VStack(spacing: 0) {
      TextField("Search colors", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .padding(10)

      List(selection: $session.selectedTokenID) {
        ForEach(ThemeTokenCategory.allCases) { category in
          let tokens = ThemeColorToken.all.filter {
            $0.category == category && $0.matches(searchText)
          }
          if !tokens.isEmpty {
            Section {
              ForEach(tokens) { token in
                HStack(spacing: 8) {
                  RoundedRectangle(cornerRadius: 3)
                    .fill(session.color(for: token).color)
                    .frame(width: 16, height: 16)
                    .overlay {
                      RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5)
                    }
                  Text(token.title)
                  Spacer(minLength: 4)
                }
                .tag(token.id)
              }
            } header: {
              Label(category.rawValue, systemImage: category.systemImage)
            }
          }
        }
      }
      .listStyle(.sidebar)
    }
    .background(controller.profile.workbench.sidebarBackground.color)
  }

  @ViewBuilder
  private var tokenEditor: some View {
    if let token = session.selectedToken {
      ThemeTokenEditor(
        controller: controller,
        session: session,
        token: token
      )
    } else {
      ContentUnavailableView(
        "Select a Color",
        systemImage: "paintpalette",
        description: Text("Choose a token from the list to edit it.")
      )
    }
  }

  private var preview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Live Preview")
              .font(.headline)
            Text("Click an element to select its color token.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle(
            "Workspace overrides",
            isOn: Binding(
              get: { controller.usesWorkspaceThemeOverrides },
              set: { session.setUsesWorkspaceOverrides($0) }
            )
          )
          .toggleStyle(.switch)
        }

        HStack(alignment: .top, spacing: 12) {
          ThemeInteractivePreview(
            label: "Light",
            profile: controller.profile(for: .light),
            selectedTokenID: session.selectedTokenID ?? "",
            selectToken: { session.selectedTokenID = $0 }
          )
          ThemeInteractivePreview(
            label: "Dark",
            profile: controller.profile(for: .dark),
            selectedTokenID: session.selectedTokenID ?? "",
            selectToken: { session.selectedTokenID = $0 }
          )
        }
      }
      .padding(14)
    }
    .background(controller.profile.workbench.panelBackground.color)
  }

  private var activeSlotBinding: Binding<EditorThemeSlot> {
    Binding(
      get: { controller.activeThemeSlot },
      set: { session.activateThemeSlot($0) }
    )
  }
}

private struct ThemeTokenEditor: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject var session: ThemeBuilderSession
  let token: ThemeColorToken

  private var color: EditorRGBAColor { session.color(for: token) }

  var body: some View {
    Form {
      Section {
        ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
        LabeledContent("Token") {
          Text(token.id)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        LabeledContent("Hex") {
          TextField("#RRGGBBAA", text: hexBinding)
            .font(.body.monospaced())
            .multilineTextAlignment(.trailing)
            .frame(width: 120)
        }
      } header: {
        Text(token.title)
      }

      Section("RGB") {
        componentSlider("Red", value: color.red, keyPath: \.red)
        componentSlider("Green", value: color.green, keyPath: \.green)
        componentSlider("Blue", value: color.blue, keyPath: \.blue)
        componentSlider("Opacity", value: color.alpha, keyPath: \.alpha)
      }

      Section("HSL") {
        hslSlider("Hue", value: color.hsl.hue * 360, range: 0...360) { hue in
          color.settingHSL(hue: hue / 360)
        }
        hslSlider("Saturation", value: color.hsl.saturation * 100, range: 0...100) { saturation in
          color.settingHSL(saturation: saturation / 100)
        }
        hslSlider("Lightness", value: color.hsl.lightness * 100, range: 0...100) { lightness in
          color.settingHSL(lightness: lightness / 100)
        }
      }

      Section("Comparison") {
        HStack(spacing: 10) {
          ThemeColorSwatch(title: "Before", color: session.baselineColor(for: token) ?? color)
          Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
          ThemeColorSwatch(title: "Current", color: color)
        }
        LabeledContent("Contrast") {
          Text("\(contrastRatio, format: .number.precision(.fractionLength(2))):1")
            .foregroundStyle(contrastRatio >= 4.5 ? Color.secondary : Color.orange)
        }
        HStack {
          Button("Light → Dark") {
            session.copyToken(token, from: .light, to: .dark)
          }
          Button("Dark → Light") {
            session.copyToken(token, from: .dark, to: .light)
          }
        }
        Button("Reset This Token", systemImage: "arrow.counterclockwise") {
          session.resetSelectedToken()
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(controller.profile.workbench.windowBackground.color)
  }

  private func componentSlider(
    _ title: String,
    value: Double,
    keyPath: WritableKeyPath<EditorRGBAColor, Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(title, value: value.formatted(.number.precision(.fractionLength(3))))
      Slider(
        value: Binding(
          get: { value },
          set: { newValue in
            var updated = color
            updated[keyPath: keyPath] = newValue
            session.setColor(updated, for: token)
          }
        ),
        in: 0...1
      )
    }
  }

  private func hslSlider(
    _ title: String,
    value: Double,
    range: ClosedRange<Double>,
    update: @escaping (Double) -> EditorRGBAColor
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent(title, value: value.formatted(.number.precision(.fractionLength(1))))
      Slider(
        value: Binding(
          get: { value },
          set: { session.setColor(update($0), for: token) }
        ),
        in: range
      )
    }
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { color.color },
      set: { value in
        let converted = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
        session.setColor(
          EditorRGBAColor(
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent),
            Double(converted.alphaComponent)
          ),
          for: token
        )
      }
    )
  }

  private var hexBinding: Binding<String> {
    Binding(
      get: { color.rgbaHex },
      set: { value in
        guard let parsed = EditorRGBAColor(rgbaHex: value) else { return }
        session.setColor(parsed, for: token)
      }
    )
  }

  private var contrastBackground: EditorRGBAColor {
    let profile = controller.profile(for: controller.activeThemeSlot)
    return switch token.category {
    case .workbench: profile.workbench.windowBackground
    case .terminal: profile.terminal.background
    case .editor, .syntax, .diagnostics: profile.surface.background
    }
  }

  private var contrastRatio: Double { color.contrastRatio(against: contrastBackground) }
}

private struct ThemeColorSwatch: View {
  let title: String
  let color: EditorRGBAColor

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      RoundedRectangle(cornerRadius: 6)
        .fill(color.color)
        .frame(height: 42)
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5)
        }
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct ThemeInteractivePreview: View {
  let label: String
  let profile: EditorCustomProfile
  let selectedTokenID: String
  let selectToken: (String) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          selectToken("workbench.accent")
        } label: {
          Circle().fill(profile.workbench.accent.color).frame(width: 9, height: 9)
        }
        .buttonStyle(.plain)
        Text(label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(profile.workbench.foreground.color)
        Spacer()
        Image(systemName: "sidebar.left")
          .foregroundStyle(profile.workbench.mutedForeground.color)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(profile.workbench.toolbarBackground.color)
      .contentShape(Rectangle())
      .onTapGesture { selectToken("workbench.toolbarBackground") }

      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          previewRow("Sources", icon: "folder", token: "workbench.foreground")
          previewRow("Theme.swift", icon: "swift", token: "workbench.accent")
          previewRow("Preview.swift", icon: "doc", token: "workbench.mutedForeground")
          Spacer()
        }
        .padding(9)
        .frame(width: 105, alignment: .topLeading)
        .frame(minHeight: 230, alignment: .topLeading)
        .background(profile.workbench.sidebarBackground.color)
        .contentShape(Rectangle())
        .onTapGesture { selectToken("workbench.sidebarBackground") }

        VStack(spacing: 0) {
          HStack(spacing: 0) {
            previewTab("Theme.swift", active: true)
            previewTab("Preview.swift", active: false)
            Spacer(minLength: 0)
          }
          .frame(height: 28)
          .background(profile.workbench.inactiveTabBackground.color)

          VStack(alignment: .leading, spacing: 7) {
            codeLine([
              ("struct", profile.syntax.literals.keyword, "syntax.keyword"),
              (" Preview", profile.syntax.symbols.type, "syntax.type"),
              (" {", profile.syntax.symbols.punctuation, "syntax.punctuation"),
            ])
            codeLine([
              ("  let", profile.syntax.literals.keyword, "syntax.keyword"),
              (" title", profile.syntax.symbols.variable, "syntax.variable"),
              (" = ", profile.syntax.symbols.operator, "syntax.operator"),
              ("\"Calcite\"", profile.syntax.literals.string, "syntax.string"),
            ])
            codeLine([
              ("  // Live theme preview", profile.syntax.literals.comment, "syntax.comment")
            ])
            codeLine([
              ("  func", profile.syntax.literals.keyword, "syntax.keyword"),
              (" render", profile.syntax.symbols.function, "syntax.function"),
              ("()", profile.syntax.symbols.punctuation, "syntax.punctuation"),
            ])
            Spacer()
            HStack(spacing: 6) {
              Circle().fill(profile.highlights.error.color).frame(width: 7, height: 7)
                .onTapGesture { selectToken("diagnostic.error") }
              Text("1 problem")
                .font(.caption2)
                .foregroundStyle(profile.workbench.mutedForeground.color)
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .background(profile.surface.background.color)
          .contentShape(Rectangle())
          .onTapGesture { selectToken("editor.background") }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(profile.workbench.border.color, lineWidth: selectedTokenID.isEmpty ? 0.5 : 1)
    }
    .frame(maxWidth: .infinity)
  }

  private func previewRow(_ title: String, icon: String, token: String) -> some View {
    Button {
      selectToken(token)
    } label: {
      Label(title, systemImage: icon)
        .font(.caption2)
        .foregroundStyle(profile.workbench.foreground.color)
        .lineLimit(1)
    }
    .buttonStyle(.plain)
  }

  private func previewTab(_ title: String, active: Bool) -> some View {
    Button {
      selectToken(active ? "workbench.activeTabBackground" : "workbench.inactiveTabBackground")
    } label: {
      Text(title)
        .font(.caption2)
        .foregroundStyle(
          active ? profile.workbench.foreground.color : profile.workbench.mutedForeground.color
        )
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .background(
          active
            ? profile.workbench.activeTabBackground.color
            : profile.workbench.inactiveTabBackground.color
        )
    }
    .buttonStyle(.plain)
  }

  private func codeLine(_ segments: [(String, EditorRGBAColor, String)]) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(segments.enumerated()), id: \.offset) { item in
        let segment = item.element
        Text(segment.0)
          .foregroundStyle(segment.1.color)
          .onTapGesture { selectToken(segment.2) }
      }
    }
    .font(.system(size: 11, design: .monospaced))
  }
}

private extension EditorRGBAColor {
  var hsl: (hue: Double, saturation: Double, lightness: Double) {
    let maximum = max(red, green, blue)
    let minimum = min(red, green, blue)
    let delta = maximum - minimum
    let lightness = (maximum + minimum) / 2
    guard delta > 0 else { return (0, 0, lightness) }

    let saturation = delta / (1 - abs(2 * lightness - 1))
    let sector: Double
    if maximum == red {
      sector = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
    } else if maximum == green {
      sector = (blue - red) / delta + 2
    } else {
      sector = (red - green) / delta + 4
    }
    let hue = ((sector / 6).truncatingRemainder(dividingBy: 1) + 1)
      .truncatingRemainder(dividingBy: 1)
    return (hue, saturation, lightness)
  }

  func settingHSL(
    hue: Double? = nil,
    saturation: Double? = nil,
    lightness: Double? = nil
  ) -> EditorRGBAColor {
    let current = hsl
    let hue = min(max(hue ?? current.hue, 0), 1)
    let saturation = min(max(saturation ?? current.saturation, 0), 1)
    let lightness = min(max(lightness ?? current.lightness, 0), 1)
    let chroma = (1 - abs(2 * lightness - 1)) * saturation
    let sector = hue * 6
    let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let components: (Double, Double, Double)
    switch sector {
    case 0..<1: components = (chroma, secondary, 0)
    case 1..<2: components = (secondary, chroma, 0)
    case 2..<3: components = (0, chroma, secondary)
    case 3..<4: components = (0, secondary, chroma)
    case 4..<5: components = (secondary, 0, chroma)
    default: components = (chroma, 0, secondary)
    }
    let match = lightness - chroma / 2
    return EditorRGBAColor(
      components.0 + match,
      components.1 + match,
      components.2 + match,
      alpha
    )
  }

  var rgbaHex: String {
    let values = [red, green, blue, alpha].map { component in
      Int((min(max(component, 0), 1) * 255).rounded())
    }
    return String(format: "#%02X%02X%02X%02X", values[0], values[1], values[2], values[3])
  }

  init?(rgbaHex value: String) {
    var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6 || value.count == 8,
      let raw = UInt64(value, radix: 16)
    else { return nil }
    let includesAlpha = value.count == 8
    let red = includesAlpha ? (raw >> 24) & 0xFF : (raw >> 16) & 0xFF
    let green = includesAlpha ? (raw >> 16) & 0xFF : (raw >> 8) & 0xFF
    let blue = includesAlpha ? (raw >> 8) & 0xFF : raw & 0xFF
    let alpha = includesAlpha ? raw & 0xFF : 0xFF
    self.init(
      Double(red) / 255,
      Double(green) / 255,
      Double(blue) / 255,
      Double(alpha) / 255
    )
  }
}
