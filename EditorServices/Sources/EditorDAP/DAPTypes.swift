import Foundation

public struct EmptyArguments: Codable, Hashable, Sendable { public init() {} }

public struct InitializeArguments: Codable, Hashable, Sendable {
    public var clientID: String?
    public var clientName: String?
    public var adapterID: String
    public var pathFormat: String
    public var linesStartAt1: Bool
    public var columnsStartAt1: Bool
    public var supportsVariableType: Bool
    public var supportsVariablePaging: Bool
    public var supportsRunInTerminalRequest: Bool
    public init(
        adapterID: String,
        clientID: String? = nil,
        clientName: String? = nil,
        supportsRunInTerminalRequest: Bool = false
    ) {
        self.clientID = clientID; self.clientName = clientName; self.adapterID = adapterID
        self.pathFormat = "path"; self.linesStartAt1 = true; self.columnsStartAt1 = true
        self.supportsVariableType = true; self.supportsVariablePaging = true
        self.supportsRunInTerminalRequest = supportsRunInTerminalRequest
    }
}

public struct Capabilities: Codable, Hashable, Sendable {
    public var supportsConfigurationDoneRequest: Bool?
    public var supportsFunctionBreakpoints: Bool?
    public var supportsConditionalBreakpoints: Bool?
    public var supportsHitConditionalBreakpoints: Bool?
    public var supportsEvaluateForHovers: Bool?
    public var supportsStepBack: Bool?
    public var supportsSetVariable: Bool?
    public var supportsRestartFrame: Bool?
    public var supportsRestartRequest: Bool?
    public var supportsExceptionInfoRequest: Bool?
    public var supportsLoadedSourcesRequest: Bool?
    public var supportsModulesRequest: Bool?
    public var supportsTerminateRequest: Bool?
    public init() {}
}

public struct Source: Codable, Hashable, Sendable {
    public var name: String?
    public var path: String?
    public var sourceReference: Int?
    public init(name: String? = nil, path: String? = nil, sourceReference: Int? = nil) {
        self.name = name; self.path = path; self.sourceReference = sourceReference
    }
}
public struct SourceBreakpoint: Codable, Hashable, Sendable {
    public var line: Int; public var column: Int?; public var condition: String?; public var hitCondition: String?; public var logMessage: String?
    public init(line: Int, column: Int? = nil, condition: String? = nil, hitCondition: String? = nil, logMessage: String? = nil) {
        self.line = line; self.column = column; self.condition = condition; self.hitCondition = hitCondition; self.logMessage = logMessage
    }
}
public struct Breakpoint: Codable, Hashable, Sendable {
    public var id: Int?; public var verified: Bool; public var message: String?; public var source: Source?; public var line: Int?; public var column: Int?
    public init(id: Int? = nil, verified: Bool, message: String? = nil, source: Source? = nil, line: Int? = nil, column: Int? = nil) {
        self.id=id; self.verified=verified; self.message=message; self.source=source; self.line=line; self.column=column
    }
}
public struct SetBreakpointsArguments: Codable, Hashable, Sendable { public var source: Source; public var breakpoints: [SourceBreakpoint]; public var sourceModified: Bool?; public init(source: Source, breakpoints: [SourceBreakpoint], sourceModified: Bool? = nil) { self.source=source; self.breakpoints=breakpoints; self.sourceModified=sourceModified } }
public struct SetBreakpointsResponseBody: Codable, Hashable, Sendable { public var breakpoints: [Breakpoint]; public init(breakpoints: [Breakpoint]) { self.breakpoints=breakpoints } }

public struct FunctionBreakpoint: Codable, Hashable, Sendable { public var name: String; public var condition: String?; public var hitCondition: String?; public init(name: String, condition: String? = nil, hitCondition: String? = nil) { self.name=name; self.condition=condition; self.hitCondition=hitCondition } }
public struct SetFunctionBreakpointsArguments: Codable, Hashable, Sendable { public var breakpoints: [FunctionBreakpoint]; public init(breakpoints: [FunctionBreakpoint]) { self.breakpoints=breakpoints } }
public struct SetExceptionBreakpointsArguments: Codable, Hashable, Sendable { public var filters: [String]; public init(filters: [String]) { self.filters=filters } }

public struct DAPThread: Codable, Hashable, Sendable { public var id: Int; public var name: String; public init(id: Int, name: String) { self.id=id; self.name=name } }
public struct ThreadsResponseBody: Codable, Hashable, Sendable { public var threads: [DAPThread]; public init(threads: [DAPThread]) { self.threads=threads } }
public struct StackFrame: Codable, Hashable, Sendable { public var id: Int; public var name: String; public var source: Source?; public var line: Int; public var column: Int; public var endLine: Int?; public var endColumn: Int?; public init(id: Int, name: String, source: Source? = nil, line: Int, column: Int) { self.id=id; self.name=name; self.source=source; self.line=line; self.column=column } }
public struct StackTraceArguments: Codable, Hashable, Sendable { public var threadId: Int; public var startFrame: Int?; public var levels: Int?; public init(threadId: Int, startFrame: Int? = nil, levels: Int? = nil) { self.threadId=threadId; self.startFrame=startFrame; self.levels=levels } }
public struct StackTraceResponseBody: Codable, Hashable, Sendable { public var stackFrames: [StackFrame]; public var totalFrames: Int?; public init(stackFrames: [StackFrame], totalFrames: Int? = nil) { self.stackFrames=stackFrames; self.totalFrames=totalFrames } }
public struct Scope: Codable, Hashable, Sendable { public var name: String; public var presentationHint: String?; public var variablesReference: Int; public var namedVariables: Int?; public var indexedVariables: Int?; public var expensive: Bool; public init(name: String, variablesReference: Int, expensive: Bool = false) { self.name=name; self.variablesReference=variablesReference; self.expensive=expensive } }
public struct ScopesArguments: Codable, Hashable, Sendable { public var frameId: Int; public init(frameId: Int) { self.frameId=frameId } }
public struct ScopesResponseBody: Codable, Hashable, Sendable { public var scopes: [Scope]; public init(scopes: [Scope]) { self.scopes=scopes } }
public struct Variable: Codable, Hashable, Sendable { public var name: String; public var value: String; public var type: String?; public var evaluateName: String?; public var variablesReference: Int; public var namedVariables: Int?; public var indexedVariables: Int?; public init(name: String, value: String, type: String? = nil, variablesReference: Int = 0) { self.name=name; self.value=value; self.type=type; self.variablesReference=variablesReference } }
public struct VariablesArguments: Codable, Hashable, Sendable { public var variablesReference: Int; public var filter: String?; public var start: Int?; public var count: Int?; public init(variablesReference: Int, filter: String? = nil, start: Int? = nil, count: Int? = nil) { self.variablesReference=variablesReference; self.filter=filter; self.start=start; self.count=count } }
public struct VariablesResponseBody: Codable, Hashable, Sendable { public var variables: [Variable]; public init(variables: [Variable]) { self.variables=variables } }
public struct SetVariableArguments: Codable, Hashable, Sendable { public var variablesReference: Int; public var name: String; public var value: String; public init(variablesReference: Int, name: String, value: String) { self.variablesReference=variablesReference; self.name=name; self.value=value } }
public struct SetVariableResponseBody: Codable, Hashable, Sendable { public var value: String; public var type: String?; public var variablesReference: Int?; public init(value: String, type: String? = nil, variablesReference: Int? = nil) { self.value=value; self.type=type; self.variablesReference=variablesReference } }

public struct ThreadControlArguments: Codable, Hashable, Sendable { public var threadId: Int; public var singleThread: Bool?; public init(threadId: Int, singleThread: Bool? = nil) { self.threadId=threadId; self.singleThread=singleThread } }
public struct ContinueResponseBody: Codable, Hashable, Sendable { public var allThreadsContinued: Bool?; public init(allThreadsContinued: Bool? = nil) { self.allThreadsContinued=allThreadsContinued } }
public struct EvaluateArguments: Codable, Hashable, Sendable { public var expression: String; public var frameId: Int?; public var context: String?; public init(expression: String, frameId: Int? = nil, context: String? = nil) { self.expression=expression; self.frameId=frameId; self.context=context } }
public struct EvaluateResponseBody: Codable, Hashable, Sendable { public var result: String; public var type: String?; public var variablesReference: Int; public init(result: String, type: String? = nil, variablesReference: Int = 0) { self.result=result; self.type=type; self.variablesReference=variablesReference } }

public struct ExceptionInfoArguments: Codable, Hashable, Sendable { public var threadId: Int; public init(threadId: Int) { self.threadId=threadId } }
public struct ExceptionDetails: Codable, Hashable, Sendable { public var message: String?; public var typeName: String?; public var fullTypeName: String?; public var evaluateName: String?; public var stackTrace: String?; public var innerException: [ExceptionDetails]?; public init(message: String? = nil) { self.message=message } }
public struct ExceptionInfoResponseBody: Codable, Hashable, Sendable { public var exceptionId: String; public var description: String?; public var breakMode: String; public var details: ExceptionDetails?; public init(exceptionId: String, description: String? = nil, breakMode: String, details: ExceptionDetails? = nil) { self.exceptionId=exceptionId; self.description=description; self.breakMode=breakMode; self.details=details } }
public struct SourceArguments: Codable, Hashable, Sendable { public var source: Source?; public var sourceReference: Int; public init(source: Source? = nil, sourceReference: Int) { self.source=source; self.sourceReference=sourceReference } }
public struct SourceResponseBody: Codable, Hashable, Sendable { public var content: String; public var mimeType: String?; public init(content: String, mimeType: String? = nil) { self.content=content; self.mimeType=mimeType } }
public struct DAPModule: Codable, Hashable, Sendable { public var id: DAPValue; public var name: String; public var path: String?; public var version: String?; public var symbolStatus: String?; public init(id: DAPValue, name: String, path: String? = nil) { self.id=id; self.name=name; self.path=path } }
public struct ModulesArguments: Codable, Hashable, Sendable { public var startModule: Int?; public var moduleCount: Int?; public init(startModule: Int? = nil, moduleCount: Int? = nil) { self.startModule=startModule; self.moduleCount=moduleCount } }
public struct ModulesResponseBody: Codable, Hashable, Sendable { public var modules: [DAPModule]; public var totalModules: Int?; public init(modules: [DAPModule], totalModules: Int? = nil) { self.modules=modules; self.totalModules=totalModules } }
public struct LoadedSourcesResponseBody: Codable, Hashable, Sendable { public var sources: [Source]; public init(sources: [Source]) { self.sources=sources } }
public struct RestartFrameArguments: Codable, Hashable, Sendable { public var frameId: Int; public init(frameId: Int) { self.frameId=frameId } }
public struct DisconnectArguments: Codable, Hashable, Sendable { public var restart: Bool?; public var terminateDebuggee: Bool?; public var suspendDebuggee: Bool?; public init(restart: Bool? = nil, terminateDebuggee: Bool? = nil, suspendDebuggee: Bool? = nil) { self.restart=restart; self.terminateDebuggee=terminateDebuggee; self.suspendDebuggee=suspendDebuggee } }
