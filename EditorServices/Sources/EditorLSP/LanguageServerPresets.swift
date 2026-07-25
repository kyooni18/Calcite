import EditorCore
import Foundation

#if os(macOS) || os(Linux)
/// Common command-line presets. Presets only describe invocation; the executable must be installed.
public enum LanguageServerPresets {
  public static func sourceKitLSP(executable: String = "sourcekit-lsp") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func clangd(executable: String = "clangd", arguments: [String] = []) -> LSPProcessConfiguration {
    .init(executable: executable, arguments: arguments)
  }

  public static func ccls(executable: String = "ccls", arguments: [String] = []) -> LSPProcessConfiguration {
    .init(executable: executable, arguments: arguments)
  }

  public static func pyright(executable: String = "pyright-langserver") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func pythonLSP(executable: String = "pylsp") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func rustAnalyzer(executable: String = "rust-analyzer") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func gopls(executable: String = "gopls") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func typescript(executable: String = "typescript-language-server") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func eslint(executable: String = "vscode-eslint-language-server") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func html(executable: String = "vscode-html-language-server") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func css(executable: String = "vscode-css-language-server") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func json(executable: String = "vscode-json-language-server") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func yaml(executable: String = "yaml-language-server") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func bash(executable: String = "bash-language-server") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["start"])
  }

  public static func lua(executable: String = "lua-language-server") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func java(executable: String = "jdtls", arguments: [String] = []) -> LSPProcessConfiguration {
    .init(executable: executable, arguments: arguments)
  }

  public static func kotlin(executable: String = "kotlin-language-server") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func solargraph(executable: String = "solargraph") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["stdio"])
  }

  public static func intelephense(executable: String = "intelephense") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func omniSharp(executable: String = "OmniSharp") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--languageserver"])
  }

  public static func haskell(executable: String = "haskell-language-server-wrapper") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--lsp"])
  }

  public static func ocaml(executable: String = "ocamllsp") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func zig(executable: String = "zls") -> LSPProcessConfiguration {
    .init(executable: executable)
  }

  public static func terraform(executable: String = "terraform-ls") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["serve"])
  }

  public static func docker(executable: String = "docker-langserver") -> LSPProcessConfiguration {
    .init(executable: executable, arguments: ["--stdio"])
  }

  public static func custom(
    executable: String,
    arguments: [String] = [],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    initializationOptions: EditorJSONValue? = nil
  ) -> LSPProcessConfiguration {
    .init(
      executable: executable,
      arguments: arguments,
      environment: environment,
      initializationOptions: initializationOptions
    )
  }
}
#endif
