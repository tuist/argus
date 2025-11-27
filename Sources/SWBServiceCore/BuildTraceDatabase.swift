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
import SWBProtocol

#if canImport(SQLite3)
import SQLite3
#elseif os(Linux) || os(Windows)
@_implementationOnly import CSQLite
#endif

/// A SQLite database for storing build trace data.
///
/// The database schema is designed for efficient querying by AI agents,
/// with pre-computed summaries and indexed columns for common access patterns.
final class BuildTraceDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.apple.swiftbuild.tracedb")

    /// Creates or opens a build trace database at the given path.
    ///
    /// - Parameter path: Path to the SQLite database file.
    /// - Throws: If the database cannot be created or initialized.
    init(path: String) throws {
        var db: OpaquePointer?
        let result = sqlite3_open(path, &db)
        guard result == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw BuildTraceDatabaseError.openFailed(message)
        }
        self.db = db
        try createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private func createTables() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS builds (
            trace_id TEXT PRIMARY KEY,
            build_id INTEGER,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            status TEXT,
            duration_seconds REAL,
            target_count INTEGER DEFAULT 0,
            task_count INTEGER DEFAULT 0,
            error_count INTEGER DEFAULT 0,
            warning_count INTEGER DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS targets (
            id INTEGER PRIMARY KEY,
            trace_id TEXT NOT NULL,
            target_id INTEGER NOT NULL,
            guid TEXT NOT NULL,
            name TEXT NOT NULL,
            project_name TEXT,
            configuration_name TEXT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            duration_seconds REAL,
            task_count INTEGER DEFAULT 0,
            up_to_date INTEGER DEFAULT 0,
            FOREIGN KEY (trace_id) REFERENCES builds(trace_id)
        );

        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY,
            trace_id TEXT NOT NULL,
            task_id INTEGER NOT NULL,
            target_id INTEGER,
            parent_id INTEGER,
            task_name TEXT,
            rule_info TEXT,
            execution_description TEXT,
            interesting_path TEXT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            status TEXT,
            duration_seconds REAL,
            utime_microseconds INTEGER,
            stime_microseconds INTEGER,
            max_rss_bytes INTEGER,
            up_to_date INTEGER DEFAULT 0,
            FOREIGN KEY (trace_id) REFERENCES builds(trace_id)
        );

        CREATE TABLE IF NOT EXISTS diagnostics (
            id INTEGER PRIMARY KEY,
            trace_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            message TEXT NOT NULL,
            file_path TEXT,
            line INTEGER,
            column_number INTEGER,
            target_id INTEGER,
            task_id INTEGER,
            timestamp TEXT NOT NULL,
            FOREIGN KEY (trace_id) REFERENCES builds(trace_id)
        );

        CREATE TABLE IF NOT EXISTS progress (
            id INTEGER PRIMARY KEY,
            trace_id TEXT NOT NULL,
            target_name TEXT,
            status_message TEXT,
            percent_complete REAL,
            timestamp TEXT NOT NULL,
            FOREIGN KEY (trace_id) REFERENCES builds(trace_id)
        );

        CREATE INDEX IF NOT EXISTS idx_targets_trace_id ON targets(trace_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_trace_id ON tasks(trace_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_target_id ON tasks(target_id);
        CREATE INDEX IF NOT EXISTS idx_diagnostics_trace_id ON diagnostics(trace_id);
        CREATE INDEX IF NOT EXISTS idx_diagnostics_kind ON diagnostics(kind);
        """

        try execute(schema)
    }

    // MARK: - Insert operations

    func insertBuild(traceId: String, buildId: Int, startedAt: Date) {
        queue.async { [weak self] in
            self?.executeInsert(
                "INSERT OR REPLACE INTO builds (trace_id, build_id, started_at) VALUES (?, ?, ?)",
                traceId, buildId, startedAt.iso8601String
            )
        }
    }

    func updateBuildEnded(buildId: Int, endedAt: Date, status: String, metrics: BuildOperationMetrics?) {
        queue.async { [weak self] in
            self?.executeUpdate(
                """
                UPDATE builds SET
                    ended_at = ?,
                    status = ?,
                    duration_seconds = (julianday(?) - julianday(started_at)) * 86400.0,
                    target_count = (SELECT COUNT(*) FROM targets WHERE targets.trace_id = builds.trace_id),
                    task_count = (SELECT COUNT(*) FROM tasks WHERE tasks.trace_id = builds.trace_id),
                    error_count = (SELECT COUNT(*) FROM diagnostics WHERE diagnostics.trace_id = builds.trace_id AND kind = 'error'),
                    warning_count = (SELECT COUNT(*) FROM diagnostics WHERE diagnostics.trace_id = builds.trace_id AND kind = 'warning')
                WHERE build_id = ?
                """,
                endedAt.iso8601String, status, endedAt.iso8601String, buildId
            )
        }
    }

    func insertTarget(
        buildTraceId: String,
        targetId: Int,
        guid: String,
        name: String,
        projectName: String?,
        configurationName: String?,
        startedAt: Date
    ) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO targets (trace_id, target_id, guid, name, project_name, configuration_name, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                buildTraceId, targetId, guid, name, projectName, configurationName, startedAt.iso8601String
            )
        }
    }

    func updateTargetEnded(targetId: Int, endedAt: Date) {
        queue.async { [weak self] in
            self?.executeUpdate(
                """
                UPDATE targets SET
                    ended_at = ?,
                    duration_seconds = (julianday(?) - julianday(started_at)) * 86400.0,
                    task_count = (SELECT COUNT(*) FROM tasks WHERE tasks.target_id = ?)
                WHERE target_id = ? AND ended_at IS NULL
                """,
                endedAt.iso8601String, endedAt.iso8601String, targetId, targetId
            )
        }
    }

    func insertTargetUpToDate(buildTraceId: String, guid: String, timestamp: Date) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO targets (trace_id, target_id, guid, name, started_at, up_to_date)
                VALUES (?, 0, ?, '', ?, 1)
                """,
                buildTraceId, guid, timestamp.iso8601String
            )
        }
    }

    func insertTask(
        buildTraceId: String,
        taskId: Int,
        targetId: Int?,
        parentId: Int?,
        taskName: String,
        ruleInfo: String,
        executionDescription: String,
        interestingPath: String?,
        startedAt: Date
    ) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO tasks (trace_id, task_id, target_id, parent_id, task_name, rule_info, execution_description, interesting_path, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                buildTraceId, taskId, targetId, parentId, taskName, ruleInfo, executionDescription, interestingPath, startedAt.iso8601String
            )
        }
    }

    func updateTaskEnded(taskId: Int, endedAt: Date, status: String, metrics: BuildOperationTaskEnded.Metrics?) {
        queue.async { [weak self] in
            self?.executeUpdate(
                """
                UPDATE tasks SET
                    ended_at = ?,
                    status = ?,
                    duration_seconds = (julianday(?) - julianday(started_at)) * 86400.0,
                    utime_microseconds = ?,
                    stime_microseconds = ?,
                    max_rss_bytes = ?
                WHERE task_id = ? AND ended_at IS NULL
                """,
                endedAt.iso8601String, status, endedAt.iso8601String,
                metrics?.utime, metrics?.stime, metrics?.maxRSS,
                taskId
            )
        }
    }

    func insertTaskUpToDate(buildTraceId: String, targetId: Int?, parentId: Int?, timestamp: Date) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO tasks (trace_id, task_id, target_id, parent_id, started_at, up_to_date)
                VALUES (?, 0, ?, ?, ?, 1)
                """,
                buildTraceId, targetId, parentId, timestamp.iso8601String
            )
        }
    }

    func insertDiagnostic(
        buildTraceId: String,
        kind: String,
        message: String,
        filePath: String?,
        line: Int?,
        column: Int?,
        targetId: Int?,
        taskId: Int?,
        timestamp: Date
    ) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO diagnostics (trace_id, kind, message, file_path, line, column_number, target_id, task_id, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                buildTraceId, kind, message, filePath, line, column, targetId, taskId, timestamp.iso8601String
            )
        }
    }

    func insertProgress(
        buildTraceId: String,
        targetName: String?,
        statusMessage: String,
        percentComplete: Double,
        timestamp: Date
    ) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO progress (trace_id, target_name, status_message, percent_complete, timestamp)
                VALUES (?, ?, ?, ?, ?)
                """,
                buildTraceId, targetName, statusMessage, percentComplete, timestamp.iso8601String
            )
        }
    }

    // MARK: - SQL execution helpers

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw BuildTraceDatabaseError.executionFailed(message)
        }
    }

    private func executeInsert(_ sql: String, _ args: Any?...) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        bindParameters(statement: statement, args: args)
        sqlite3_step(statement)
    }

    private func executeUpdate(_ sql: String, _ args: Any?...) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        bindParameters(statement: statement, args: args)
        sqlite3_step(statement)
    }

    private func bindParameters(statement: OpaquePointer?, args: [Any?]) {
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            switch arg {
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let value as Int:
                sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, position, value)
            case let value as UInt64:
                sqlite3_bind_int64(statement, position, Int64(bitPattern: value))
            case let value as Double:
                sqlite3_bind_double(statement, position, value)
            case nil:
                sqlite3_bind_null(statement, position)
            default:
                sqlite3_bind_null(statement, position)
            }
        }
    }
}

// MARK: - Errors

enum BuildTraceDatabaseError: Error {
    case openFailed(String)
    case executionFailed(String)
}

// MARK: - Date formatting

private extension Date {
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }
}
