//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// Build tracing is only available on Apple platforms where SQLite3 is available
#if canImport(SQLite3)

import Foundation
public import SWBProtocol
import SWBUtil

/// Records build operation messages to a SQLite database for observability and analysis.
///
/// The recorder captures structured build data that can be queried by AI agents
/// or other tools to understand build performance, failures, and patterns.
///
/// Recording is enabled by default, storing traces at:
/// `~/Library/Developer/Xcode/BuildTraces/traces.db`
///
/// Environment variables:
/// - `SWB_BUILD_TRACE_PATH`: Override the database path
/// - `SWB_BUILD_TRACE_ENABLED=0`: Disable recording
/// - `SWB_BUILD_TRACE_ID`: Custom build identifier for external correlation
/// - `SWB_BUILD_PROJECT_ID`: Project identifier for grouping related builds
/// - `SWB_BUILD_WORKSPACE_PATH`: Workspace path for grouping builds by workspace
public final class BuildTraceRecorder: @unchecked Sendable {
    /// The default path for the build trace database.
    private static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Developer/Xcode/BuildTraces/traces.db"
    }()

    /// The shared recorder instance, if recording is enabled.
    public static let shared: BuildTraceRecorder? = {
        if ProcessInfo.processInfo.environment["SWB_BUILD_TRACE_ENABLED"] == "0" {
            return nil
        }
        let path = ProcessInfo.processInfo.environment["SWB_BUILD_TRACE_PATH"] ?? defaultPath
        do {
            // Ensure the directory exists
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return try BuildTraceRecorder(databasePath: path)
        } catch {
            FileHandle.standardError.write(Data("Warning: Failed to initialize build trace recorder: \(error)\n".utf8))
            return nil
        }
    }()

    private let database: BuildTraceDatabase
    private let buildTraceId: String
    private let projectId: String?
    private let workspacePath: String?

    /// Cache of target info: targetID -> (name, guid)
    private var targetInfo: [Int: (name: String, guid: String)] = [:]
    private let targetInfoLock = NSLock()

    /// Import scanner for extracting imports from source files
    private let importScanner = ImportSourceCodeScanner()

    /// Whether import scanning is enabled (can be disabled via environment variable)
    private let importScanningEnabled: Bool

    /// Creates a new build trace recorder.
    ///
    /// - Parameters:
    ///   - databasePath: Path to the SQLite database file.
    /// - Throws: If the database cannot be created or initialized.
    public init(databasePath: String) throws {
        self.database = try BuildTraceDatabase(path: databasePath)
        self.buildTraceId = ProcessInfo.processInfo.environment["SWB_BUILD_TRACE_ID"]
            ?? UUID().uuidString
        self.projectId = ProcessInfo.processInfo.environment["SWB_BUILD_PROJECT_ID"]
        self.workspacePath = ProcessInfo.processInfo.environment["SWB_BUILD_WORKSPACE_PATH"]
        // Import scanning can be disabled via environment variable for performance
        self.importScanningEnabled = ProcessInfo.processInfo.environment["SWB_BUILD_TRACE_IMPORTS"] != "0"
    }

    /// Flushes all pending database operations.
    ///
    /// This should be called before the service shuts down to ensure
    /// all recorded data is written to the database.
    public func flush() {
        database.flush()
    }

    /// Records a build operation message.
    ///
    /// This method is called for every message sent by the build service.
    /// It extracts relevant build operation messages and records them to the database.
    ///
    /// - Parameter message: The message to record.
    public func record(_ message: any Message) {
        let timestamp = Date()

        switch message {
        case let msg as BuildOperationStarted:
            database.insertBuild(
                buildId: buildTraceId,
                internalBuildId: msg.id,
                startedAt: timestamp,
                projectId: projectId,
                workspacePath: workspacePath
            )

        case let msg as BuildOperationEnded:
            database.updateBuildEnded(
                buildId: buildTraceId,
                endedAt: timestamp,
                status: msg.status.traceDescription,
                metrics: msg.metrics
            )

        case let msg as BuildOperationTargetStarted:
            database.insertTarget(
                buildId: buildTraceId,
                targetId: msg.id,
                guid: msg.guid,
                name: msg.info.name,
                projectName: msg.info.projectInfo.name,
                configurationName: msg.info.configurationName,
                startedAt: timestamp
            )
            // Cache target info for import scanning
            targetInfoLock.lock()
            targetInfo[msg.id] = (name: msg.info.name, guid: msg.guid)
            targetInfoLock.unlock()

        case let msg as BuildOperationTargetEnded:
            database.updateTargetEnded(
                buildId: buildTraceId,
                targetId: msg.id,
                endedAt: timestamp,
                status: "succeeded"
            )

        case let msg as BuildOperationTaskStarted:
            database.insertTask(
                buildId: buildTraceId,
                taskId: msg.id,
                targetId: msg.targetID,
                parentId: msg.parentID,
                taskName: msg.info.taskName,
                ruleInfo: msg.info.ruleInfo,
                executionDescription: msg.info.executionDescription,
                interestingPath: msg.info.interestingPath?.str,
                startedAt: timestamp
            )

            // Extract imports from compile tasks
            if importScanningEnabled {
                recordImportsIfCompileTask(msg: msg)
            }

            // Extract linked dependencies from linker tasks
            recordLinkedDependenciesIfLinkerTask(msg: msg)

        case let msg as BuildOperationTaskEnded:
            database.updateTaskEnded(
                buildId: buildTraceId,
                taskId: msg.id,
                endedAt: timestamp,
                status: msg.status.traceDescription,
                metrics: msg.metrics
            )

        case let msg as BuildOperationTaskUpToDate:
            database.insertTaskUpToDate(
                buildId: buildTraceId,
                targetId: msg.targetID,
                parentId: msg.parentID,
                timestamp: timestamp
            )

        case let msg as BuildOperationDiagnosticEmitted:
            let (filePath, line, column) = msg.location.traceLocationDetails
            database.insertDiagnostic(
                buildId: buildTraceId,
                kind: msg.kind.traceDescription,
                message: msg.message,
                filePath: filePath,
                line: line,
                column: column,
                targetId: msg.locationContext.traceTargetID,
                taskId: msg.locationContext.traceTaskID,
                timestamp: timestamp
            )

        case let msg as DependencyGraphResponse:
            let stringAdjacencyList = Dictionary(
                uniqueKeysWithValues: msg.adjacencyList.map { (key, value) in
                    (key.rawValue, value.map { $0.rawValue })
                }
            )
            let stringTargetNames = Dictionary(
                uniqueKeysWithValues: msg.targetNames.map { (key, value) in
                    (key.rawValue, value)
                }
            )
            database.insertDependencyGraph(
                buildId: buildTraceId,
                adjacencyList: stringAdjacencyList,
                targetNames: stringTargetNames
            )

        default:
            break
        }
    }

    // MARK: - Import scanning

    /// Checks if a task is a compile task and extracts imports if so.
    private func recordImportsIfCompileTask(msg: BuildOperationTaskStarted) {
        // Check if this is a compile task
        let ruleInfo = msg.info.ruleInfo
        guard ruleInfo.hasPrefix("SwiftCompile") ||
              ruleInfo.hasPrefix("CompileSwift") ||
              ruleInfo.hasPrefix("CompileC") ||
              ruleInfo.hasPrefix("CompileSwiftSources") ||
              ruleInfo.hasPrefix("Compile") else {
            return
        }

        // Get the source file path
        guard let sourcePath = msg.info.interestingPath?.str else {
            return
        }

        // Get target info
        guard let targetId = msg.targetID else {
            return
        }

        targetInfoLock.lock()
        let cachedTargetInfo = targetInfo[targetId]
        targetInfoLock.unlock()

        guard let (targetName, targetGuid) = cachedTargetInfo else {
            return
        }

        // Extract imports asynchronously to avoid blocking
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            guard let imports = self.importScanner.extractImports(fromFileAt: sourcePath) else {
                return
            }

            for importedModule in imports {
                self.database.insertSourceImport(
                    buildId: self.buildTraceId,
                    targetId: targetId,
                    targetName: targetName,
                    targetGuid: targetGuid,
                    sourceFile: sourcePath,
                    importedModule: importedModule
                )
            }
        }
    }

    // MARK: - Linker dependency extraction

    /// Checks if a task is a linker task and extracts linked dependencies if so.
    private func recordLinkedDependenciesIfLinkerTask(msg: BuildOperationTaskStarted) {
        // Check if this is a linker task (Ld for dynamic linking, Libtool for static archives)
        let ruleInfo = msg.info.ruleInfo
        guard ruleInfo.hasPrefix("Ld ") || ruleInfo.hasPrefix("Libtool ") else {
            return
        }

        // Get the command line
        guard let commandLine = msg.info.commandLineDisplayString else {
            return
        }

        // Get target info
        guard let targetId = msg.targetID else {
            return
        }

        targetInfoLock.lock()
        let cachedTargetInfo = targetInfo[targetId]
        targetInfoLock.unlock()

        guard let (_, targetGuid) = cachedTargetInfo else {
            return
        }

        // Parse linker dependencies asynchronously
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let dependencies = LinkerCommandParser.parseLinkedDependencies(from: commandLine)

            for dep in dependencies {
                self.database.insertLinkedDependency(
                    buildId: self.buildTraceId,
                    targetGuid: targetGuid,
                    dependencyPath: dep.path,
                    linkKind: dep.kind,
                    linkMode: dep.mode,
                    dependencyName: dep.name,
                    isSystem: dep.isSystem
                )
            }
        }
    }
}

// MARK: - Linker Command Parser

/// Parses linker command lines to extract linked dependency information.
enum LinkerCommandParser {
    struct LinkedDependency {
        let path: String
        let kind: String      // static, dynamic, framework
        let mode: String      // normal, weak, reexport, merge
        let name: String?
        let isSystem: Bool
    }

    /// Parses a linker command line and extracts linked dependencies.
    static func parseLinkedDependencies(from commandLine: String) -> [LinkedDependency] {
        var dependencies: [LinkedDependency] = []
        let args = splitCommandLine(commandLine)

        var i = 0
        while i < args.count {
            let arg = args[i]

            // Framework flags
            if arg == "-framework" && i + 1 < args.count {
                let name = args[i + 1]
                dependencies.append(LinkedDependency(
                    path: name,
                    kind: "framework",
                    mode: "normal",
                    name: name,
                    isSystem: isSystemFramework(name)
                ))
                i += 2
                continue
            }

            if arg == "-weak_framework" && i + 1 < args.count {
                let name = args[i + 1]
                dependencies.append(LinkedDependency(
                    path: name,
                    kind: "framework",
                    mode: "weak",
                    name: name,
                    isSystem: isSystemFramework(name)
                ))
                i += 2
                continue
            }

            if arg == "-reexport_framework" && i + 1 < args.count {
                let name = args[i + 1]
                dependencies.append(LinkedDependency(
                    path: name,
                    kind: "framework",
                    mode: "reexport",
                    name: name,
                    isSystem: isSystemFramework(name)
                ))
                i += 2
                continue
            }

            // Library flags: -l<name>, -weak-l<name>, -reexport-l<name>
            if arg.hasPrefix("-reexport-l") {
                let name = String(arg.dropFirst("-reexport-l".count))
                if !name.isEmpty {
                    dependencies.append(LinkedDependency(
                        path: name,
                        kind: "dynamic",
                        mode: "reexport",
                        name: name,
                        isSystem: false
                    ))
                }
                i += 1
                continue
            }

            if arg.hasPrefix("-weak-l") {
                let name = String(arg.dropFirst("-weak-l".count))
                if !name.isEmpty {
                    dependencies.append(LinkedDependency(
                        path: name,
                        kind: "dynamic",
                        mode: "weak",
                        name: name,
                        isSystem: false
                    ))
                }
                i += 1
                continue
            }

            if arg.hasPrefix("-l") && !arg.hasPrefix("-lazy") {
                let name = String(arg.dropFirst("-l".count))
                if !name.isEmpty {
                    dependencies.append(LinkedDependency(
                        path: name,
                        kind: "dynamic",
                        mode: "normal",
                        name: name,
                        isSystem: false
                    ))
                }
                i += 1
                continue
            }

            // Direct file paths: .a (static), .dylib (dynamic), .tbd (text-based stub)
            if arg.hasSuffix(".a") && !arg.hasPrefix("-") {
                let name = extractLibraryName(from: arg)
                dependencies.append(LinkedDependency(
                    path: arg,
                    kind: "static",
                    mode: "normal",
                    name: name,
                    isSystem: isSystemPath(arg)
                ))
                i += 1
                continue
            }

            if arg.hasSuffix(".dylib") && !arg.hasPrefix("-") {
                let name = extractLibraryName(from: arg)
                dependencies.append(LinkedDependency(
                    path: arg,
                    kind: "dynamic",
                    mode: "normal",
                    name: name,
                    isSystem: isSystemPath(arg)
                ))
                i += 1
                continue
            }

            if arg.hasSuffix(".tbd") && !arg.hasPrefix("-") {
                let name = extractLibraryName(from: arg)
                dependencies.append(LinkedDependency(
                    path: arg,
                    kind: "dynamic",
                    mode: "normal",
                    name: name,
                    isSystem: isSystemPath(arg)
                ))
                i += 1
                continue
            }

            // Framework bundle paths (.framework)
            if arg.contains(".framework") && !arg.hasPrefix("-") {
                let name = extractFrameworkName(from: arg)
                dependencies.append(LinkedDependency(
                    path: arg,
                    kind: "framework",
                    mode: "normal",
                    name: name,
                    isSystem: isSystemPath(arg)
                ))
                i += 1
                continue
            }

            i += 1
        }

        return dependencies
    }

    /// Splits a command line string into arguments, respecting quotes.
    private static func splitCommandLine(_ commandLine: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for char in commandLine {
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                } else {
                    current.append(char)
                }
            } else {
                if char == "\"" || char == "'" {
                    inQuote = true
                    quoteChar = char
                } else if char == " " || char == "\t" || char == "\n" {
                    if !current.isEmpty {
                        args.append(current)
                        current = ""
                    }
                } else {
                    current.append(char)
                }
            }
        }

        if !current.isEmpty {
            args.append(current)
        }

        return args
    }

    /// Extracts a library name from a path (e.g., libFoo.a -> Foo).
    private static func extractLibraryName(from path: String) -> String? {
        let filename = (path as NSString).lastPathComponent
        if filename.hasPrefix("lib") {
            let name = String(filename.dropFirst(3))
            if let dotIndex = name.lastIndex(of: ".") {
                return String(name[..<dotIndex])
            }
            return name
        }
        if let dotIndex = filename.lastIndex(of: ".") {
            return String(filename[..<dotIndex])
        }
        return filename
    }

    /// Extracts a framework name from a path (e.g., /path/to/Foo.framework/Foo -> Foo).
    private static func extractFrameworkName(from path: String) -> String? {
        // Look for .framework in the path
        if let range = path.range(of: ".framework") {
            let beforeFramework = path[..<range.lowerBound]
            if let lastSlash = beforeFramework.lastIndex(of: "/") {
                return String(beforeFramework[beforeFramework.index(after: lastSlash)...])
            }
            return String(beforeFramework)
        }
        return (path as NSString).lastPathComponent
    }

    /// Checks if a framework is a system framework.
    private static func isSystemFramework(_ name: String) -> Bool {
        // Common system frameworks
        let systemFrameworks: Set<String> = [
            "Foundation", "UIKit", "AppKit", "CoreFoundation", "CoreGraphics",
            "CoreData", "CoreLocation", "CoreMedia", "CoreVideo", "CoreAudio",
            "AVFoundation", "Security", "SystemConfiguration", "QuartzCore",
            "Metal", "MetalKit", "SpriteKit", "SceneKit", "GameplayKit",
            "WebKit", "SafariServices", "StoreKit", "CloudKit", "HealthKit",
            "HomeKit", "MapKit", "PassKit", "EventKit", "AddressBook",
            "Contacts", "ContactsUI", "Photos", "PhotosUI", "MediaPlayer",
            "AssetsLibrary", "Accelerate", "OpenGL", "OpenGLES", "GLKit",
            "AudioToolbox", "AudioUnit", "CoreAudioKit", "CoreMIDI",
            "CoreBluetooth", "ExternalAccessory", "MultipeerConnectivity",
            "NetworkExtension", "NotificationCenter", "Social", "Twitter",
            "Accounts", "AdSupport", "iAd", "GameKit", "GameController",
            "ReplayKit", "UserNotifications", "UserNotificationsUI",
            "FileProvider", "FileProviderUI", "Intents", "IntentsUI",
            "Speech", "Vision", "NaturalLanguage", "CoreML", "CreateML",
            "ARKit", "RealityKit", "Combine", "SwiftUI", "WidgetKit",
            "AppClip", "CarPlay", "ClassKit", "CoreNFC", "DeviceCheck",
            "IdentityLookup", "Messages", "MessageUI", "PencilKit",
            "PushKit", "WatchConnectivity", "WatchKit", "AuthenticationServices",
            "CryptoKit", "LocalAuthentication", "BackgroundTasks", "LinkPresentation",
            "UniformTypeIdentifiers", "OSLog", "os", "Darwin", "Dispatch",
            "ObjectiveC", "CoreServices", "ApplicationServices", "IOKit"
        ]
        return systemFrameworks.contains(name)
    }

    /// Checks if a path is a system path.
    private static func isSystemPath(_ path: String) -> Bool {
        return path.hasPrefix("/System/") ||
               path.hasPrefix("/usr/lib/") ||
               path.hasPrefix("/Library/Developer/CommandLineTools/") ||
               path.contains("/Xcode.app/Contents/Developer/Platforms/") ||
               path.contains("/SDKs/")
    }
}

// MARK: - Trace description helpers

extension BuildOperationEnded.Status {
    var traceDescription: String {
        switch self {
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

extension BuildOperationTaskEnded.Status {
    var traceDescription: String {
        switch self {
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

extension BuildOperationDiagnosticEmitted.Kind {
    var traceDescription: String {
        switch self {
        case .note: return "note"
        case .warning: return "warning"
        case .error: return "error"
        case .remark: return "remark"
        }
    }
}

extension BuildOperationDiagnosticEmitted.LocationContext {
    var traceTargetID: Int? {
        switch self {
        case .target(let targetID), .task(_, _, let targetID):
            return targetID
        default:
            return nil
        }
    }

    var traceTaskID: Int? {
        switch self {
        case .task(let taskID, _, _), .globalTask(let taskID, _):
            return taskID
        default:
            return nil
        }
    }
}

extension Diagnostic.Location {
    var traceLocationDetails: (path: String?, line: Int?, column: Int?) {
        switch self {
        case .unknown:
            return (nil, nil, nil)
        case .path(let path, let fileLocation):
            switch fileLocation {
            case .textual(let line, let column):
                return (path.str, line, column)
            case .object:
                return (path.str, nil, nil)
            case nil:
                return (path.str, nil, nil)
            }
        case .buildSettings, .buildFiles:
            return (nil, nil, nil)
        }
    }
}

#endif // canImport(SQLite3)
