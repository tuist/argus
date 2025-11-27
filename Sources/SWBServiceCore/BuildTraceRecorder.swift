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

import Foundation
public import SWBProtocol
import SWBUtil

/// Records build operation messages to a SQLite database for observability and analysis.
///
/// The recorder captures structured build data that can be queried by AI agents
/// or other tools to understand build performance, failures, and patterns.
///
/// Enable recording by setting the `SWB_BUILD_TRACE_PATH` environment variable
/// to the path where the SQLite database should be created.
///
/// Optionally set `SWB_BUILD_TRACE_ID` to provide a custom build identifier
/// for correlating builds with external invocations.
public final class BuildTraceRecorder: @unchecked Sendable {
    /// The shared recorder instance, if recording is enabled.
    public static let shared: BuildTraceRecorder? = {
        guard let path = ProcessInfo.processInfo.environment["SWB_BUILD_TRACE_PATH"] else {
            return nil
        }
        do {
            return try BuildTraceRecorder(databasePath: path)
        } catch {
            fputs("Warning: Failed to initialize build trace recorder: \(error)\n", stderr)
            return nil
        }
    }()

    private let database: BuildTraceDatabase
    private let buildTraceId: String

    /// Creates a new build trace recorder.
    ///
    /// - Parameters:
    ///   - databasePath: Path to the SQLite database file.
    /// - Throws: If the database cannot be created or initialized.
    public init(databasePath: String) throws {
        self.database = try BuildTraceDatabase(path: databasePath)
        self.buildTraceId = ProcessInfo.processInfo.environment["SWB_BUILD_TRACE_ID"]
            ?? UUID().uuidString
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
                startedAt: timestamp
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

        default:
            break
        }
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
