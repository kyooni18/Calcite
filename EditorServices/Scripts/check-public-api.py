#!/usr/bin/env python3
"""Fails if the supported editor and source-workspace API disappears."""

import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
graph_root = root / ".build"

def load(module: str) -> tuple[Path, set[str]]:
    graphs = sorted(graph_root.glob(f"**/symbolgraph/{module}.symbols.json"))
    if not graphs:
        print(f"{module} symbol graph was not generated", file=sys.stderr)
        sys.exit(1)
    path = graphs[-1]
    data = json.loads(path.read_text())
    symbols = {".".join(symbol.get("pathComponents", [])) for symbol in data.get("symbols", [])}
    return path, symbols

services_path, services = load("EditorServices")
workspace_path, workspace = load("EditorWorkspace")
service_kit_path, service_kit = load("EditorServiceKit")
core_path, core = load("EditorCore")
tree_sitter_path, tree_sitter = load("EditorTreeSitter")
lsp_path, lsp = load("EditorLSP")

required_services = {
    "SwiftEditorBackend",
    "SwiftEditorBackend.makeSwift(workspaceURL:)",
    "SwiftEditorBackend.makeMultiLanguage(configuration:)",
    "MultiLanguageEditorBackendConfiguration",
    "ExternalLanguageServerConfiguration",
    "ExternalLanguageServerPresets.custom(id:executable:arguments:languageIDs:fileExtensions:initializationOptions:priority:)",
    "SwiftEditorBackend.openFile(at:)",
    "SwiftEditorBackend.openFile(at:languageID:)",
    "SwiftEditorBackend.openDocument(at:text:languageID:)",
    "SwiftEditorBackend.openDocumentSession(at:text:languageID:)",
    "SwiftEditorBackend.openFileSession(at:languageID:)",
    "SwiftEditorBackend.documentLanguageID(at:)",
    "SwiftEditorDocumentSession.languageID",
    "SwiftEditorBackend.languageServiceRouter",
    "EditorBackendBuilder",
    "EditorBackendBuilder.addingLanguageService(_:)",
    "EditorBackendBuilder.build()",
    "EditorBackendBuilder.withContextualSyntaxFactory(_:)",
    "SwiftEditorBackend.applyUTF16Edit(_:replacement:to:)",
    "SwiftEditorBackend.completions(in:at:triggerCharacter:)",
    "SwiftEditorBackend.signatureHelp(in:at:)",
    "SwiftEditorBackend.documentSymbols(in:)",
    "SwiftEditorBackend.codeActions(in:range:diagnostics:only:)",
    "SwiftEditorBackend.inlayHints(in:range:)",
    "SwiftEditorBackend.applyWorkspaceEdit(_:openMissingFiles:)",
    "SwiftEditorBackend.scanSourceWorkspace()",
    "SwiftEditorBackend.sourceWorkspaceSnapshot()",
    "SwiftEditorBackend.sourceWorkspaceArchive()",
    "SwiftEditorBackend.sourceWorkspaceMetrics()",
    "SwiftEditorBackend.sourceFile(at:)",
    "SwiftEditorBackend.sourceFileSession(id:)",
    "SwiftEditorBackend.createSourceFile(at:content:languageID:persistImmediately:openInEditor:)",
    "SwiftEditorBackend.setSourceFileContentsAtomically(_:)",
    "SwiftEditorBackend.applySourceFileEditsAtomically(_:)",
    "SwiftEditorBackend.searchSource(_:options:)",
    "SwiftEditorBackend.replaceAllSource(_:with:options:)",
    "SwiftEditorBackend.saveAllSourceFiles(overwriteExternalChanges:)",
    "SwiftEditorBackend.restoreSourceWorkspace(from:policy:mode:closeOpenDocuments:)",
    "SwiftEditorBackend.startSourceWorkspaceMonitoring(every:)",
    "SwiftSourceFileSession",
    "SwiftSourceFileSession.move(to:)",
    "SwiftSourceFileSession.save(overwriteExternalChanges:)",
    "SwiftEditorBackend.startLLDBDebugger(executablePath:arguments:environment:initializeArguments:)",
    "EditorDocumentPipeline.open(backend:at:languageID:configuration:)",
    "EditorIDEWorkspace.openDocument(at:languageID:)",
    "SwiftEditorBackend.shutdown()",
}
required_workspace = {
    "SourceWorkspace",
    "SourceCodeFile",
    "SourceCodeFile.content",
    "SourceCodeFile.name",
    "SourceCodeFile.relativePath",
    "SourceCodeFile.url",
    "SourceCodeFile.state",
    "SourceWorkspaceSnapshot",
    "SourceWorkspaceSnapshot.tree",
    "SourceWorkspaceArchive",
    "SourceWorkspaceMetrics",
    "SourceWorkspaceConfiguration.languageCatalog",
    "SourceReplacementPreview",
    "SourceFileContentUpdate",
    "SourceFileEditBatch",
}

required_service_kit = {
    "LanguageServiceID",
    "LanguageServiceRole",
    "LanguageServiceSelector",
    "LanguageServiceRegistration",
    "LanguageServiceDescriptor",
    "LanguageServiceRouter",
    "LanguageServiceRouter.register(_:)",
    "LanguageServiceRouter.unregister(_:shutDown:)",
    "LanguageServiceRouter.registrations()",
    "LanguageServiceRouter.boundServiceIDs(for:)",
    "LanguageServiceRouter.rebindDocument(at:)",
    "LanguageServiceRouter.shutdown()",
    "LanguageServiceRouterError.shutdown",
}
required_core = {
    "EditorLanguageDefinition",
    "EditorLanguageCatalog",
    "EditorLanguageCatalog.standard",
    "EditorLanguageCatalog.languageID(forPath:)",
    "EditorSyntaxServiceContext",
    "Completion.serviceIdentifier",
    "EditorCommand.serviceIdentifier",
    "DiagnosticBatch.serviceIdentifier",
    "LanguageServerMessage.serviceIdentifier",
    "IncrementalUTF8Decoder",
    "IncrementalUTF8Decoder.init()",
    "IncrementalUTF8Decoder.hasPendingBytes",
    "IncrementalUTF8Decoder.decode(_:)",
    "IncrementalUTF8Decoder.finish()",
    "IncrementalUTF8Decoder.reset()",
}


required_tree_sitter = {
    "TreeSitterLanguageRegistration",
    "TreeSitterLanguageRegistry",
    "TreeSitterLanguageRegistry.register(_:)",
    "TreeSitterLanguageRegistry.unregister(_:)",
    "TreeSitterLanguageRegistry.makeService(uri:languageID:)",
    "TreeSitterLanguageRegistry.swiftRegistration(priority:)",
    "TreeSitterQuerySet.load(highlightsURL:foldsURL:)",
}
if sys.platform.startswith("linux") or sys.platform == "darwin":
    required_tree_sitter.update({
        "DynamicTreeSitterLanguage",
        "DynamicTreeSitterLanguage.init(libraryURL:symbol:)",
        "DynamicTreeSitterLanguage.registration(id:languageIDs:fileExtensions:priority:queries:)",
    })

required_lsp = {
    "LSPProcessConfiguration",
    "LSPProcessConnection",
    "LSPProcessConnection.init(workspaceURL:configuration:workspaceURLs:capabilities:configurationProvider:workspaceEditHandler:)",
    "LSPProcessConnection.shutdown()",
    "LSPExecutableResolver.resolve(_:environment:)",
    "LanguageServerPresets.custom(executable:arguments:environment:initializationOptions:)",
}

failures: list[tuple[str, list[str]]] = []
for module, required, actual in (
    ("EditorServices", required_services, services),
    ("EditorWorkspace", required_workspace, workspace),
    ("EditorServiceKit", required_service_kit, service_kit),
    ("EditorCore", required_core, core),
    ("EditorTreeSitter", required_tree_sitter, tree_sitter),
    ("EditorLSP", required_lsp, lsp),
):
    missing = sorted(required - actual)
    if missing:
        failures.append((module, missing))

if failures:
    for module, missing in failures:
        print(f"Missing required public API in {module}:", file=sys.stderr)
        for value in missing:
            print(f"- {value}", file=sys.stderr)
    sys.exit(1)

count = (
    len(required_services)
    + len(required_workspace)
    + len(required_service_kit)
    + len(required_core)
    + len(required_tree_sitter)
    + len(required_lsp)
)
print(f"Verified {count} required public symbols")
print(f"- {services_path}")
print(f"- {workspace_path}")
print(f"- {service_kit_path}")
print(f"- {core_path}")
print(f"- {tree_sitter_path}")
print(f"- {lsp_path}")
