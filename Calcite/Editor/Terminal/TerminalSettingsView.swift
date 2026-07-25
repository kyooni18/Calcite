#if os(macOS)
  import AppKit
  import SwiftUI

  struct TerminalSettingsView: View {
    @ObservedObject var store: EditorTerminalPreferencesStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
      VStack(spacing: 0) {
        header
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            sourceSection
            fontSection
            colorSection
            spacingSection
            ansiSection
          }
          .padding(20)
        }
      }
      .frame(minWidth: 600, idealWidth: 680, minHeight: 560, idealHeight: 700)
      .background { CalciteBackground() }
    }

    private var header: some View {
      HStack {
        Text("Terminal")
          .font(.headline)
        Spacer()
        Button("Reset") { store.reset() }
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }

    private var sourceSection: some View {
      TerminalSettingsSection("Profile") {
        Picker("Source", selection: valueBinding(\.source)) {
          ForEach(EditorTerminalAppearanceSource.allCases, id: \.self) { source in
            Text(source.title).tag(source)
          }
        }
        .pickerStyle(.segmented)

        HStack {
          Spacer()
          Button("Copy Terminal Profile") {
            guard let imported = TerminalAppearance.importedTerminalProfile() else { return }
            store.replace(with: imported)
          }
        }
      }
    }

    private var fontSection: some View {
      TerminalSettingsSection("Font") {
        Picker("Font", selection: valueBinding(\.fontName)) {
          ForEach(fontNames, id: \.self) { name in
            Text(name).tag(name)
          }
        }
        .disabled(usesSystemProfile)

        HStack {
          Text("Size")
          Slider(value: valueBinding(\.fontSize), in: 7...40, step: 0.5)
          Text(store.preferences.fontSize.formatted(.number.precision(.fractionLength(1))))
            .monospacedDigit()
            .frame(width: 42, alignment: .trailing)
        }
        .disabled(usesSystemProfile)

        Toggle("Ligatures", isOn: valueBinding(\.enablesLigatures))
          .disabled(usesSystemProfile)
        Toggle("Bright bold colors", isOn: valueBinding(\.brightensBoldText))
          .disabled(usesSystemProfile)
      }
    }

    private var colorSection: some View {
      TerminalSettingsSection("Colors") {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
          ColorPicker("Text", selection: colorBinding(\.foreground), supportsOpacity: true)
          ColorPicker("Background", selection: colorBinding(\.background), supportsOpacity: false)
          ColorPicker("Selection", selection: colorBinding(\.selection), supportsOpacity: true)
        }
        .disabled(usesSystemProfile)

        ColorPicker("Cursor", selection: colorBinding(\.cursor), supportsOpacity: true)

        Picker("Cursor Shape", selection: valueBinding(\.cursorStyle)) {
          ForEach(EditorCursorStyle.allCases) { style in
            Text(style.title).tag(style)
          }
        }
        .pickerStyle(.segmented)

        HStack {
          Text("Opacity")
          Slider(value: valueBinding(\.backgroundOpacity), in: 0.2...1, step: 0.01)
          Text(
            store.preferences.backgroundOpacity.formatted(.percent.precision(.fractionLength(0)))
          )
          .monospacedDigit()
          .frame(width: 42, alignment: .trailing)
        }
        .disabled(usesSystemProfile)
      }
    }

    private var spacingSection: some View {
      TerminalSettingsSection("Layout") {
        terminalSlider("Horizontal", keyPath: \.horizontalPadding, range: 0...32)
        terminalSlider("Vertical", keyPath: \.verticalPadding, range: 0...24)
        terminalSlider("Line spacing", keyPath: \.lineSpacing, range: 0...12)
      }
      .disabled(usesSystemProfile)
    }

    private var ansiSection: some View {
      TerminalSettingsSection("ANSI") {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
          ForEach(store.preferences.ansiColors.indices, id: \.self) { index in
            ColorPicker(
              ansiName(index),
              selection: ansiColorBinding(index),
              supportsOpacity: false
            )
          }
        }
      }
      .disabled(usesSystemProfile)
    }

    private var usesSystemProfile: Bool {
      store.preferences.source == .macOSTerminal
    }

    private var fontNames: [String] {
      let selected = store.preferences.fontName
      return TerminalFontCatalog.names.contains(selected)
        ? TerminalFontCatalog.names
        : [selected] + TerminalFontCatalog.names
    }

    private func terminalSlider(
      _ title: String,
      keyPath: WritableKeyPath<EditorTerminalPreferences, Double>,
      range: ClosedRange<Double>
    ) -> some View {
      HStack {
        Text(title)
        Slider(value: valueBinding(keyPath), in: range, step: 0.5)
        Text(
          store.preferences[keyPath: keyPath]
            .formatted(.number.precision(.fractionLength(1)))
        )
        .monospacedDigit()
        .frame(width: 42, alignment: .trailing)
      }
    }

    private func valueBinding<Value>(
      _ keyPath: WritableKeyPath<EditorTerminalPreferences, Value>
    ) -> Binding<Value> {
      Binding(
        get: { store.preferences[keyPath: keyPath] },
        set: { value in
          var preferences = store.preferences
          preferences[keyPath: keyPath] = value
          store.preferences = preferences
        }
      )
    }

    private func colorBinding(
      _ keyPath: WritableKeyPath<EditorTerminalPreferences, EditorTerminalColor>
    ) -> Binding<Color> {
      Binding(
        get: { Color(nsColor: NSColor(store.preferences[keyPath: keyPath])) },
        set: { color in
          var preferences = store.preferences
          preferences[keyPath: keyPath] = NSColor(color).terminalColor
          store.preferences = preferences
        }
      )
    }

    private func ansiColorBinding(_ index: Int) -> Binding<Color> {
      Binding(
        get: { Color(nsColor: NSColor(store.preferences.ansiColors[index])) },
        set: { color in
          var preferences = store.preferences
          guard preferences.ansiColors.indices.contains(index) else { return }
          preferences.ansiColors[index] = NSColor(color).terminalColor
          store.preferences = preferences
        }
      )
    }

    private func ansiName(_ index: Int) -> String {
      let names = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow", "Bright Blue",
        "Bright Magenta", "Bright Cyan", "Bright White",
      ]
      return names[index]
    }
  }

  private struct TerminalSettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
      self.title = title
      self.content = content()
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(.headline)
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @MainActor
  private enum TerminalFontCatalog {
    static let names: [String] = {
      let manager = NSFontManager.shared
      let fixedPitch = manager.availableFonts.filter { name in
        guard let font = NSFont(name: name, size: 13) else { return false }
        return manager.traits(of: font).contains(.fixedPitchFontMask)
      }
      let preferred = ["SFMono-Regular", "Menlo-Regular", "Monaco", "CourierNewPSMT"]
      return Array(Set(preferred + fixedPitch)).sorted { lhs, rhs in
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
      }
    }()
  }

  extension NSColor {
    fileprivate convenience init(_ value: EditorTerminalColor) {
      self.init(
        srgbRed: value.red,
        green: value.green,
        blue: value.blue,
        alpha: value.alpha
      )
    }

    fileprivate var terminalColor: EditorTerminalColor {
      let color = usingColorSpace(.sRGB) ?? self
      return EditorTerminalColor(
        red: color.redComponent,
        green: color.greenComponent,
        blue: color.blueComponent,
        alpha: color.alphaComponent
      )
    }
  }
#endif
