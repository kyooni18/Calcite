import SwiftUI

func fileIconCode(forFileName fileName: String) -> String {
  switch fileName.lowercased() {
  case "cmakelists.txt":
    return "cmake"
  case "makefile", "gnumakefile":
    return "makefile"
  default:
    return URL(fileURLWithPath: fileName).pathExtension.lowercased()
  }
}

struct CIcon: View {
  let code: String
  let size: CGFloat

  var body: some View {
    Text(iconGlyph(for: code) + " ")
      .font(.custom("0xProtoNF-Regular", size: size))
  }

  private func iconGlyph(for code: String) -> String {
    switch code.lowercased() {
    case "python", "py": return "\u{e73c}"
    case "php": return "\u{e73d}"
    case "markdown", "md": return "\u{e73e}"
    case "typescript", "ts", "tsx": return "\u{e69d}"
    case "javascript", "js", "jsx": return "\u{e74e}"
    case "rust", "rs": return "\u{e68b}"
    case "c": return "\u{e649}"
    case "cs": return "\u{e648}"
    case "cpp", "cc", "cxx": return "\u{e646}"
    case "m", "mm": return "\u{e84d}"
    case "git": return "\u{e65d}"
    case "go": return "\u{e65e}"
    case "kotlin", "kt", "kts": return "\u{e634}"
    case "java": return "\u{e738}"
    case "cmake": return "\u{e794}"
    case "makefile": return "\u{e673}"
    case "unity": return "\u{e721}"
    case "raspberrypi": return "\u{e722}"
    case "branch": return "\u{e725}"
    case "apple", "swift": return "\u{e699}"
    case "conda": return "\u{e715}"
    case "nodejs": return "\u{e719}"
    case "svelte": return "\u{e697}"
    case "docker", "dockerfile": return "\u{e650}"
    case "html", "htm": return "\u{e736}"
    case "css", "scss", "less": return "\u{e749}"
    case "json", "yaml", "yml", "toml": return "\u{e60b}"
    case "zig": return "\u{e6a9}"
    default: return "\u{f15b}"
    }
  }
}

private struct CIconPreview: View {
  var body: some View {
    CIcon(code: "rs", size: 20)
      .padding(40)
  }
}

#Preview {
  CIconPreview()
}
