import AppKit
import Combine
import Foundation

/// Reflects media already playing in standard macOS media apps without taking
/// ownership of the user's library or playback queue.
@MainActor
final class NowPlayingController: ObservableObject {
  enum Source: String, Sendable, CaseIterable {
    case music = "Music"
    case spotify = "Spotify"
  }

  @Published private(set) var title = "Nothing playing"
  @Published private(set) var artist = "Open Music or Spotify to see playback here"
  @Published private(set) var isPlaying = false
  @Published private(set) var source: Source?
  @Published private(set) var artwork: Data?
  @Published private(set) var artworkAccent: NSColor = .controlAccentColor
  @Published private(set) var artworkSecondaryAccent: NSColor = .controlAccentColor

  private var refreshTask: Task<Void, Never>?
  private var artworkRetryTask: Task<Void, Never>?
  private var refreshInvocation: Task<Void, Never>?

  deinit {
    refreshTask?.cancel()
    artworkRetryTask?.cancel()
    refreshInvocation?.cancel()
  }

  func start() {
    refresh()
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let self, !Task.isCancelled else { return }
        self.refresh()
      }
    }
    artworkRetryTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let self, !Task.isCancelled else { return }
        guard self.source != nil, self.artwork == nil else { continue }
        self.refresh()
      }
    }
  }

  func stop() {
    refreshTask?.cancel()
    refreshTask = nil
    artworkRetryTask?.cancel()
    artworkRetryTask = nil
    refreshInvocation?.cancel()
    refreshInvocation = nil
  }

  func refresh() {
    guard refreshInvocation == nil else { return }
    let runningSources = Source.allCases.filter { source in
      let identifier = source == .music ? "com.apple.Music" : "com.spotify.client"
      return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == identifier }
    }

    refreshInvocation = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        Self.loadNowPlaying(from: runningSources)
      }.value
      guard let self, !Task.isCancelled else { return }
      self.apply(result)
      self.refreshInvocation = nil
    }
  }

  func togglePlayback() { perform("playpause") }
  func previousTrack() { perform("previous track") }
  func nextTrack() { perform("next track") }

  private func perform(_ command: String) {
    guard let source else { return }
    Task { [weak self] in
      _ = await Task.detached(priority: .userInitiated) {
        Self.run("tell application \"\(source.rawValue)\" to \(command)")
      }.value
      self?.refresh()
    }
  }

  private struct LoadedNowPlaying: @unchecked Sendable {
    let source: Source
    let title: String
    let artist: String
    let isPlaying: Bool
    let artwork: Data?
    let primaryColor: NSColor
    let secondaryColor: NSColor
  }

  private func apply(_ result: LoadedNowPlaying?) {
    guard let result else {
      title = "Nothing playing"
      artist = "Open Music or Spotify to see playback here"
      isPlaying = false
      source = nil
      artwork = nil
      artworkAccent = .controlAccentColor
      artworkSecondaryAccent = .controlAccentColor
      return
    }
    source = result.source
    title = result.title
    artist = result.artist
    isPlaying = result.isPlaying
    artwork = result.artwork
    artworkAccent = result.primaryColor
    artworkSecondaryAccent = result.secondaryColor
  }

  nonisolated private static func loadNowPlaying(from sources: [Source]) -> LoadedNowPlaying? {
    var fallback: LoadedNowPlaying?
    for source in sources {
      guard let snapshot = snapshot(from: source) else { continue }
      let image = artworkData(from: source)
      let palette = image.flatMap(paletteColors(for:))
      let loaded = LoadedNowPlaying(
        source: source,
        title: snapshot.title,
        artist: snapshot.artist,
        isPlaying: snapshot.isPlaying,
        artwork: image,
        primaryColor: palette?.primary ?? .controlAccentColor,
        secondaryColor: palette?.secondary ?? palette?.primary ?? .controlAccentColor
      )
      if image != nil { return loaded }
      if fallback == nil { fallback = loaded }
    }
    return fallback
  }

  nonisolated private static func snapshot(from source: Source) -> (
    title: String, artist: String, isPlaying: Bool
  )? {
    let script = """
      tell application "\(source.rawValue)"
        if player state is stopped then return ""
        return (name of current track as text) & "|" & (artist of current track as text) & "|" & (player state as text)
      end tell
      """
    guard let result = run(script), !result.isEmpty else { return nil }
    let fields = result.components(separatedBy: "|")
    guard fields.count >= 3 else { return nil }
    return (fields[0], fields[1], fields[2].lowercased() == "playing")
  }

  nonisolated private static func artworkData(from source: Source) -> Data? {
    let urlScript = "tell application \"\(source.rawValue)\" to return artwork url of current track"
    if let urlString = run(urlScript), let url = URL(string: urlString), url.scheme != nil,
      let data = try? Data(contentsOf: url), !data.isEmpty
    {
      return data
    }

    let script = "tell application \"\(source.rawValue)\" to get data of artwork 1 of current track"
    var error: NSDictionary?
    guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
      error == nil
    else {
      return decodeArtworkPayload(from: run(script))
    }
    return descriptor.data ?? decodeArtworkPayload(from: run(script))
  }

  nonisolated private static func decodeArtworkPayload(from value: String?) -> Data? {
    guard let value else { return nil }
    let payload =
      value
      .replacingOccurrences(of: "«data ", with: "")
      .replacingOccurrences(of: "»", with: "")
    let hex = String(payload.dropFirst(min(4, payload.count)))
    guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
      return nil
    }
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    return data
  }

  nonisolated private static func paletteColors(for data: Data) -> (
    primary: NSColor, secondary: NSColor
  )? {
    guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
    let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 18)
    var samples: [(color: NSColor, hue: CGFloat, weight: CGFloat)] = []

    for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        guard brightness > 0.08, brightness < 0.96 else { continue }
        let weight = max(0.08, saturation) * (0.55 + min(brightness, 0.8))
        samples.append((color, hue, weight))
      }
    }
    guard !samples.isEmpty else { return nil }

    let primary = weightedAverage(samples)
    var primaryHue: CGFloat = 0
    primary.getHue(&primaryHue, saturation: nil, brightness: nil, alpha: nil)
    let secondarySamples = samples.filter {
      let distance = abs($0.hue - primaryHue)
      let circularDistance = min(distance, 1 - distance)
      return circularDistance > 0.10
    }
    let secondary =
      secondarySamples.isEmpty
      ? weightedAverage(samples.reversed())
      : weightedAverage(secondarySamples)
    return (primary, secondary)
  }

  nonisolated private static func weightedAverage<S: Sequence>(
    _ samples: S
  ) -> NSColor where S.Element == (color: NSColor, hue: CGFloat, weight: CGFloat) {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var total: CGFloat = 0
    for sample in samples {
      guard let color = sample.color.usingColorSpace(.sRGB) else { continue }
      red += color.redComponent * sample.weight
      green += color.greenComponent * sample.weight
      blue += color.blueComponent * sample.weight
      total += sample.weight
    }
    guard total > 0 else { return .controlAccentColor }
    return NSColor(red: red / total, green: green / total, blue: blue / total, alpha: 1)
  }

  nonisolated private static func run(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }
}
