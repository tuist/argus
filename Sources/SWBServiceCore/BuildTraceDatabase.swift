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
@_implementationOnly import SwiftToolchainCSQLite
#endif

/// A SQLite database for storing build trace data.
///
/// The database schema is designed for efficient querying by AI agents,
/// with pre-computed summaries and indexed columns for common access patterns.
final class BuildTraceDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.apple.swiftbuild.tracedb")

    /// Current schema version for migrations.
    private static let schemaVersion = 2

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
        try runMigrations()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private func createTables() throws {
        let schema = """
        -- Summary layer: One row per build with pre-computed metrics.
        -- An agent can get a high-level view of any build with minimal tokens.
        CREATE TABLE IF NOT EXISTS builds (
            id TEXT PRIMARY KEY,
            build_id INTEGER,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            status TEXT,
            duration_seconds REAL,
            target_count INTEGER DEFAULT 0,
            task_count INTEGER DEFAULT 0,
            error_count INTEGER DEFAULT 0,
            warning_count INTEGER DEFAULT 0,
            cache_hit_count INTEGER DEFAULT 0,
            cache_miss_count INTEGER DEFAULT 0
        );

        -- Details layer: Individual targets with timing data.
        CREATE TABLE IF NOT EXISTS build_targets (
            id INTEGER PRIMARY KEY,
            build_id TEXT NOT NULL,
            target_id INTEGER NOT NULL,
            guid TEXT NOT NULL,
            name TEXT NOT NULL,
            project_name TEXT,
            configuration_name TEXT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            duration_seconds REAL,
            task_count INTEGER DEFAULT 0,
            status TEXT,
            FOREIGN KEY (build_id) REFERENCES builds(id)
        );

        -- Details layer: Individual tasks with timing and resource metrics.
        CREATE TABLE IF NOT EXISTS build_tasks (
            id INTEGER PRIMARY KEY,
            build_id TEXT NOT NULL,
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
            utime_usec INTEGER,
            stime_usec INTEGER,
            max_rss_bytes INTEGER,
            was_cache_hit INTEGER DEFAULT 0,
            FOREIGN KEY (build_id) REFERENCES builds(id)
        );

        -- Details layer: Structured diagnostics with file locations.
        CREATE TABLE IF NOT EXISTS build_diagnostics (
            id INTEGER PRIMARY KEY,
            build_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            message TEXT NOT NULL,
            file_path TEXT,
            line INTEGER,
            column_number INTEGER,
            target_id INTEGER,
            task_id INTEGER,
            timestamp TEXT NOT NULL,
            FOREIGN KEY (build_id) REFERENCES builds(id)
        );

        -- Raw layer: Original messages as JSON for debugging.
        CREATE TABLE IF NOT EXISTS build_messages (
            id INTEGER PRIMARY KEY,
            build_id TEXT NOT NULL,
            message_type TEXT NOT NULL,
            message_json TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            FOREIGN KEY (build_id) REFERENCES builds(id)
        );

        -- Dependency graph: Target dependencies for bottleneck analysis.
        CREATE TABLE IF NOT EXISTS target_dependencies (
            id INTEGER PRIMARY KEY,
            build_id TEXT NOT NULL,
            target_guid TEXT NOT NULL,
            depends_on_guid TEXT NOT NULL,
            FOREIGN KEY (build_id) REFERENCES builds(id)
        );

        -- Indexes for common queries
        CREATE INDEX IF NOT EXISTS idx_build_targets_build_id ON build_targets(build_id);
        CREATE INDEX IF NOT EXISTS idx_build_tasks_build_id ON build_tasks(build_id);
        CREATE INDEX IF NOT EXISTS idx_build_tasks_target_id ON build_tasks(target_id);
        CREATE INDEX IF NOT EXISTS idx_build_tasks_duration ON build_tasks(duration_seconds DESC);
        CREATE INDEX IF NOT EXISTS idx_build_diagnostics_build_id ON build_diagnostics(build_id);
        CREATE INDEX IF NOT EXISTS idx_build_diagnostics_kind ON build_diagnostics(kind);
        CREATE INDEX IF NOT EXISTS idx_build_messages_build_id ON build_messages(build_id);
        CREATE INDEX IF NOT EXISTS idx_target_dependencies_build_id ON target_dependencies(build_id);
        CREATE INDEX IF NOT EXISTS idx_target_dependencies_target ON target_dependencies(target_guid);
        CREATE INDEX IF NOT EXISTS idx_build_targets_guid ON build_targets(guid);
        CREATE INDEX IF NOT EXISTS idx_builds_project_id ON builds(project_id);
        CREATE INDEX IF NOT EXISTS idx_builds_workspace_path ON builds(workspace_path);

        -- Top-N layer: Views for common agent queries
        -- Slowest targets per build (pre-sorted)
        CREATE VIEW IF NOT EXISTS slowest_targets AS
        SELECT build_id, name, project_name, duration_seconds, task_count, status
        FROM build_targets
        WHERE duration_seconds IS NOT NULL
        ORDER BY build_id, duration_seconds DESC;

        -- Slowest tasks per build (pre-sorted)
        CREATE VIEW IF NOT EXISTS slowest_tasks AS
        SELECT build_id, task_name, execution_description, interesting_path,
               duration_seconds, utime_usec, stime_usec, max_rss_bytes
        FROM build_tasks
        WHERE duration_seconds IS NOT NULL AND was_cache_hit = 0
        ORDER BY build_id, duration_seconds DESC;

        -- Recent errors per build
        CREATE VIEW IF NOT EXISTS recent_errors AS
        SELECT build_id, message, file_path, line, column_number, timestamp
        FROM build_diagnostics
        WHERE kind = 'error'
        ORDER BY build_id, timestamp DESC;

        -- Recent warnings per build
        CREATE VIEW IF NOT EXISTS recent_warnings AS
        SELECT build_id, message, file_path, line, column_number, timestamp
        FROM build_diagnostics
        WHERE kind = 'warning'
        ORDER BY build_id, timestamp DESC;
        """

        try execute(schema)
    }

    /// Runs database migrations to update schema from older versions.
    ///
    /// Migration strategy:
    /// - Version 1: Original schema (no project_id/workspace_path)
    /// - Version 2: Added project_id and workspace_path columns to builds table
    private func runMigrations() throws {
        // Check current schema version
        let currentVersion = querySchemaVersion()

        if currentVersion < 2 {
            // Migration to version 2: Add project_id and workspace_path columns
            let migration = """
                ALTER TABLE builds ADD COLUMN project_id TEXT;
                ALTER TABLE builds ADD COLUMN workspace_path TEXT;
                """
            // SQLite doesn't support multiple statements in ALTER TABLE via exec,
            // so we execute each separately
            try execute("ALTER TABLE builds ADD COLUMN project_id TEXT")
            try execute("ALTER TABLE builds ADD COLUMN workspace_path TEXT")
        }

        // Update schema version
        try setSchemaVersion(Self.schemaVersion)
    }

    private func querySchemaVersion() -> Int {
        var statement: OpaquePointer?
        let sql = "PRAGMA user_version"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func setSchemaVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: - Insert operations

    func insertBuild(buildId: String, internalBuildId: Int, startedAt: Date, projectId: String? = nil, workspacePath: String? = nil) {
        queue.async { [weak self] in
            self?.executeInsert(
                "INSERT OR REPLACE INTO builds (id, build_id, started_at, project_id, workspace_path) VALUES (?, ?, ?, ?, ?)",
                buildId, internalBuildId, startedAt.iso8601String, projectId, workspacePath
            )
        }
    }

    func updateBuildEnded(buildId: String, endedAt: Date, status: String, metrics: BuildOperationMetrics?) {
        queue.async { [weak self] in
            self?.executeUpdate(
                """
                UPDATE builds SET
                    ended_at = ?,
                    status = ?,
                    duration_seconds = (julianday(?) - julianday(started_at)) * 86400.0,
                    target_count = (SELECT COUNT(*) FROM build_targets WHERE build_targets.build_id = builds.id),
                    task_count = (SELECT COUNT(*) FROM build_tasks WHERE build_tasks.build_id = builds.id),
                    error_count = (SELECT COUNT(*) FROM build_diagnostics WHERE build_diagnostics.build_id = builds.id AND kind = 'error'),
                    warning_count = (SELECT COUNT(*) FROM build_diagnostics WHERE build_diagnostics.build_id = builds.id AND kind = 'warning'),
                    cache_hit_count = (SELECT COUNT(*) FROM build_tasks WHERE build_tasks.build_id = builds.id AND was_cache_hit = 1),
                    cache_miss_count = (SELECT COUNT(*) FROM build_tasks WHERE build_tasks.build_id = builds.id AND was_cache_hit = 0)
                WHERE id = ?
                """,
                endedAt.iso8601String, status, endedAt.iso8601String, buildId
            )
        }
    }

    func insertTarget(
        buildId: String,
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
                INSERT INTO build_targets (build_id, target_id, guid, name, project_name, configuration_name, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                buildId, targetId, guid, name, projectName, configurationName, startedAt.iso8601String
            )
        }
    }

    func updateTargetEnded(buildId: String, targetId: Int, endedAt: Date, status: String) {
        queue.async { [weak self] in
            self?.executeUpdate(
                """
                UPDATE build_targets SET
                    ended_at = ?,
                    status = ?,
                    duration_seconds = (julianday(?) - julianday(started_at)) * 86400.0,
                    task_count = (SELECT COUNT(*) FROM build_tasks WHERE build_tasks.target_id = ? AND build_tasks.build_id = ?)
                WHERE target_id = ? AND build_id = ? AND ended_at IS NULL
                """,
                endedAt.iso8601String, status, endedAt.iso8601String, targetId, buildId, targetId, buildId
            )
        }
    }

    func insertTask(
        buildId: String,
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
                INSERT INTO build_tasks (build_id, task_id, target_id, parent_id, task_name, rule_info, execution_description, interesting_path, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                buildId, taskId, targetId, parentId, taskName, ruleInfo, executionDescription, interestingPath, startedAt.iso8601String
            )
        }
    }

    func updateTaskEnded(buildId: String, taskId: Int, endedAt: Date, status: String, metrics: BuildOperationTaskEnded.Metrics?) {
        queue.async { [weak self] in
            self?.executeUpdate(
                """
                UPDATE build_tasks SET
                    ended_at = ?,
                    status = ?,
                    duration_seconds = (julianday(?) - julianday(started_at)) * 86400.0,
                    utime_usec = ?,
                    stime_usec = ?,
                    max_rss_bytes = ?
                WHERE task_id = ? AND build_id = ? AND ended_at IS NULL
                """,
                endedAt.iso8601String, status, endedAt.iso8601String,
                metrics?.utime, metrics?.stime, metrics?.maxRSS,
                taskId, buildId
            )
        }
    }

    func insertTaskUpToDate(buildId: String, targetId: Int?, parentId: Int?, timestamp: Date) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO build_tasks (build_id, task_id, target_id, parent_id, started_at, was_cache_hit)
                VALUES (?, 0, ?, ?, ?, 1)
                """,
                buildId, targetId, parentId, timestamp.iso8601String
            )
        }
    }

    func insertDiagnostic(
        buildId: String,
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
                INSERT INTO build_diagnostics (build_id, kind, message, file_path, line, column_number, target_id, task_id, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                buildId, kind, message, filePath, line, column, targetId, taskId, timestamp.iso8601String
            )
        }
    }

    func insertRawMessage(buildId: String, messageType: String, messageJson: String, timestamp: Date) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO build_messages (build_id, message_type, message_json, timestamp)
                VALUES (?, ?, ?, ?)
                """,
                buildId, messageType, messageJson, timestamp.iso8601String
            )
        }
    }

    func insertDependencyGraph(buildId: String, adjacencyList: [String: [String]]) {
        queue.async { [weak self] in
            for (targetGuid, dependencies) in adjacencyList {
                for dependsOnGuid in dependencies {
                    self?.executeInsert(
                        """
                        INSERT INTO target_dependencies (build_id, target_guid, depends_on_guid)
                        VALUES (?, ?, ?)
                        """,
                        buildId, targetGuid, dependsOnGuid
                    )
                }
            }
        }
    }

    // MARK: - Query operations

    func queryBuildSummary(buildId: String) -> BuildSummary? {
        queue.sync {
            let sql = buildId == "latest"
                ? "SELECT * FROM builds ORDER BY started_at DESC LIMIT 1"
                : "SELECT * FROM builds WHERE id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }

            if buildId != "latest" {
                sqlite3_bind_text(statement, 1, buildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return BuildSummary(
                id: String(cString: sqlite3_column_text(statement, 0)),
                startedAt: String(cString: sqlite3_column_text(statement, 2)),
                endedAt: sqlite3_column_type(statement, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 3)) : nil,
                status: sqlite3_column_type(statement, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 4)) : nil,
                durationSeconds: sqlite3_column_type(statement, 5) != SQLITE_NULL ? sqlite3_column_double(statement, 5) : nil,
                targetCount: Int(sqlite3_column_int(statement, 6)),
                taskCount: Int(sqlite3_column_int(statement, 7)),
                errorCount: Int(sqlite3_column_int(statement, 8)),
                warningCount: Int(sqlite3_column_int(statement, 9)),
                cacheHitCount: Int(sqlite3_column_int(statement, 10)),
                cacheMissCount: Int(sqlite3_column_int(statement, 11))
            )
        }
    }

    func queryErrors(buildId: String) -> [DiagnosticInfo] {
        queryDiagnostics(buildId: buildId, kind: "error")
    }

    func queryWarnings(buildId: String) -> [DiagnosticInfo] {
        queryDiagnostics(buildId: buildId, kind: "warning")
    }

    private func queryDiagnostics(buildId: String, kind: String) -> [DiagnosticInfo] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            let sql = "SELECT message, file_path, line, column_number FROM build_diagnostics WHERE build_id = ? AND kind = ? ORDER BY timestamp DESC"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var results: [DiagnosticInfo] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(DiagnosticInfo(
                    message: String(cString: sqlite3_column_text(statement, 0)),
                    filePath: sqlite3_column_type(statement, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 1)) : nil,
                    line: sqlite3_column_type(statement, 2) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 2)) : nil,
                    column: sqlite3_column_type(statement, 3) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 3)) : nil
                ))
            }
            return results
        }
    }

    func querySlowestTargets(buildId: String, limit: Int) -> [TargetTiming] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            let sql = "SELECT name, project_name, duration_seconds, task_count, status FROM slowest_targets WHERE build_id = ? LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(statement, 2, Int32(limit))

            var results: [TargetTiming] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(TargetTiming(
                    name: String(cString: sqlite3_column_text(statement, 0)),
                    projectName: sqlite3_column_type(statement, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 1)) : nil,
                    durationSeconds: sqlite3_column_double(statement, 2),
                    taskCount: Int(sqlite3_column_int(statement, 3)),
                    status: sqlite3_column_type(statement, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 4)) : nil
                ))
            }
            return results
        }
    }

    func querySlowestTasks(buildId: String, limit: Int) -> [TaskTiming] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            let sql = "SELECT task_name, execution_description, interesting_path, duration_seconds, max_rss_bytes FROM slowest_tasks WHERE build_id = ? LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(statement, 2, Int32(limit))

            var results: [TaskTiming] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(TaskTiming(
                    taskName: sqlite3_column_type(statement, 0) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 0)) : nil,
                    executionDescription: sqlite3_column_type(statement, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 1)) : nil,
                    interestingPath: sqlite3_column_type(statement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 2)) : nil,
                    durationSeconds: sqlite3_column_double(statement, 3),
                    maxRssBytes: sqlite3_column_type(statement, 4) != SQLITE_NULL ? Int64(sqlite3_column_int64(statement, 4)) : nil
                ))
            }
            return results
        }
    }

    func queryBottlenecks(buildId: String) -> [TargetBottleneck] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            // Find targets that are bottlenecks using the actual dependency graph.
            // A bottleneck is a target that:
            // 1. Takes a long time to compile
            // 2. Has many other targets depending on it (blocking them from starting)
            // The bottleneck_score = duration * dependent_count shows the total "cost" of this target
            let sql = """
                SELECT
                    t.name as target_name,
                    t.project_name,
                    t.duration_seconds,
                    COUNT(td.target_guid) as dependent_count,
                    GROUP_CONCAT(t2.name) as blocked_targets,
                    ROUND(t.duration_seconds * COUNT(td.target_guid), 2) as bottleneck_score
                FROM build_targets t
                LEFT JOIN target_dependencies td ON t.guid = td.depends_on_guid AND t.build_id = td.build_id
                LEFT JOIN build_targets t2 ON td.target_guid = t2.guid AND td.build_id = t2.build_id
                WHERE t.build_id = ? AND t.duration_seconds IS NOT NULL
                GROUP BY t.guid, t.name, t.project_name, t.duration_seconds
                HAVING dependent_count > 0
                ORDER BY bottleneck_score DESC
                LIMIT 10
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var results: [TargetBottleneck] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let blockedTargetsStr = sqlite3_column_type(statement, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 4)) : ""
                results.append(TargetBottleneck(
                    targetName: String(cString: sqlite3_column_text(statement, 0)),
                    durationSeconds: sqlite3_column_double(statement, 2),
                    blockedCount: Int(sqlite3_column_int(statement, 3)),
                    blockedTargets: blockedTargetsStr.split(separator: ",").map(String.init)
                ))
            }
            return results
        }
    }

    func queryCriticalPath(buildId: String) -> [CriticalPathNode] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            // Build the dependency graph and compute the critical path.
            // The critical path is the longest chain of dependencies that determines
            // the minimum possible build time.

            // First, get all targets with their durations
            var targetDurations: [String: (name: String, projectName: String?, duration: Double, guid: String)] = [:]
            let targetsSql = """
                SELECT guid, name, project_name, duration_seconds
                FROM build_targets
                WHERE build_id = ? AND duration_seconds IS NOT NULL
                """
            var targetsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, targetsSql, -1, &targetsStatement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(targetsStatement) }

            sqlite3_bind_text(targetsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(targetsStatement) == SQLITE_ROW {
                let guid = String(cString: sqlite3_column_text(targetsStatement, 0))
                let name = String(cString: sqlite3_column_text(targetsStatement, 1))
                let projectName = sqlite3_column_type(targetsStatement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(targetsStatement, 2)) : nil
                let duration = sqlite3_column_double(targetsStatement, 3)
                targetDurations[guid] = (name, projectName, duration, guid)
            }

            // Get dependencies
            var dependencies: [String: [String]] = [:]
            let depsSql = """
                SELECT target_guid, depends_on_guid
                FROM target_dependencies
                WHERE build_id = ?
                """
            var depsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, depsSql, -1, &depsStatement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(depsStatement) }

            sqlite3_bind_text(depsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(depsStatement) == SQLITE_ROW {
                let targetGuid = String(cString: sqlite3_column_text(depsStatement, 0))
                let dependsOnGuid = String(cString: sqlite3_column_text(depsStatement, 1))
                dependencies[targetGuid, default: []].append(dependsOnGuid)
            }

            // Compute longest path to each target using dynamic programming
            var memo: [String: (Double, [String])] = [:] // guid -> (total_duration, path)

            func longestPath(_ guid: String) -> (Double, [String]) {
                if let cached = memo[guid] { return cached }
                guard let target = targetDurations[guid] else { return (0, []) }

                let deps = dependencies[guid] ?? []
                if deps.isEmpty {
                    let result = (target.duration, [guid])
                    memo[guid] = result
                    return result
                }

                var maxDuration = 0.0
                var maxPath: [String] = []
                for dep in deps {
                    let (depDuration, depPath) = longestPath(dep)
                    if depDuration > maxDuration {
                        maxDuration = depDuration
                        maxPath = depPath
                    }
                }

                let result = (maxDuration + target.duration, maxPath + [guid])
                memo[guid] = result
                return result
            }

            // Find the target with the longest total path
            var criticalGuid: String? = nil
            var criticalDuration = 0.0

            for guid in targetDurations.keys {
                let (duration, _) = longestPath(guid)
                if duration > criticalDuration {
                    criticalDuration = duration
                    criticalGuid = guid
                }
            }

            // Build the result
            guard let finalGuid = criticalGuid else { return [] }
            let (_, path) = longestPath(finalGuid)

            return path.compactMap { guid in
                guard let target = targetDurations[guid] else { return nil }
                return CriticalPathNode(
                    targetName: target.name,
                    projectName: target.projectName,
                    durationSeconds: target.duration
                )
            }
        }
    }

    func searchErrors(pattern: String) -> [ErrorSearchResult] {
        queue.sync {
            let sql = """
                SELECT b.id, b.started_at, d.message, d.file_path, d.line
                FROM build_diagnostics d
                JOIN builds b ON d.build_id = b.id
                WHERE d.kind = 'error' AND d.message LIKE ?
                ORDER BY b.started_at DESC
                LIMIT 20
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            let likePattern = "%\(pattern)%"
            sqlite3_bind_text(statement, 1, likePattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var results: [ErrorSearchResult] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(ErrorSearchResult(
                    buildId: String(cString: sqlite3_column_text(statement, 0)),
                    buildStartedAt: String(cString: sqlite3_column_text(statement, 1)),
                    message: String(cString: sqlite3_column_text(statement, 2)),
                    filePath: sqlite3_column_type(statement, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 3)) : nil,
                    line: sqlite3_column_type(statement, 4) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 4)) : nil
                ))
            }
            return results
        }
    }

    func queryProjects() -> [ProjectInfo] {
        queue.sync {
            let sql = """
                SELECT
                    COALESCE(project_id, workspace_path, 'unknown') as project_identifier,
                    project_id,
                    workspace_path,
                    COUNT(*) as build_count,
                    MAX(started_at) as last_build_at,
                    SUM(CASE WHEN status = 'succeeded' THEN 1 ELSE 0 END) as success_count,
                    SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failure_count
                FROM builds
                GROUP BY COALESCE(project_id, workspace_path, id)
                ORDER BY last_build_at DESC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            var results: [ProjectInfo] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(ProjectInfo(
                    identifier: String(cString: sqlite3_column_text(statement, 0)),
                    projectId: sqlite3_column_type(statement, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 1)) : nil,
                    workspacePath: sqlite3_column_type(statement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 2)) : nil,
                    buildCount: Int(sqlite3_column_int(statement, 3)),
                    lastBuildAt: String(cString: sqlite3_column_text(statement, 4)),
                    successCount: Int(sqlite3_column_int(statement, 5)),
                    failureCount: Int(sqlite3_column_int(statement, 6))
                ))
            }
            return results
        }
    }

    func queryBuildsForProject(projectId: String?, workspacePath: String?, limit: Int) -> [BuildSummary] {
        queue.sync {
            var conditions: [String] = []
            var bindings: [Any?] = []

            if let projectId = projectId {
                conditions.append("project_id = ?")
                bindings.append(projectId)
            }
            if let workspacePath = workspacePath {
                conditions.append("workspace_path = ?")
                bindings.append(workspacePath)
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " OR ")
            let sql = """
                SELECT id, started_at, ended_at, status, duration_seconds,
                       target_count, task_count, error_count, warning_count, cache_hit_count, cache_miss_count
                FROM builds
                \(whereClause)
                ORDER BY started_at DESC
                LIMIT ?
                """
            bindings.append(limit)

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            for (index, binding) in bindings.enumerated() {
                let position = Int32(index + 1)
                switch binding {
                case let value as String:
                    sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                case let value as Int:
                    sqlite3_bind_int(statement, position, Int32(value))
                default:
                    sqlite3_bind_null(statement, position)
                }
            }

            var results: [BuildSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(BuildSummary(
                    id: String(cString: sqlite3_column_text(statement, 0)),
                    startedAt: String(cString: sqlite3_column_text(statement, 1)),
                    endedAt: sqlite3_column_type(statement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 2)) : nil,
                    status: sqlite3_column_type(statement, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 3)) : nil,
                    durationSeconds: sqlite3_column_type(statement, 4) != SQLITE_NULL ? sqlite3_column_double(statement, 4) : nil,
                    targetCount: Int(sqlite3_column_int(statement, 5)),
                    taskCount: Int(sqlite3_column_int(statement, 6)),
                    errorCount: Int(sqlite3_column_int(statement, 7)),
                    warningCount: Int(sqlite3_column_int(statement, 8)),
                    cacheHitCount: Int(sqlite3_column_int(statement, 9)),
                    cacheMissCount: Int(sqlite3_column_int(statement, 10))
                ))
            }
            return results
        }
    }

    private func queryLatestBuildId() -> String? {
        let sql = "SELECT id FROM builds ORDER BY started_at DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
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

// MARK: - Query result types

struct BuildSummary: Codable {
    let id: String
    let startedAt: String
    let endedAt: String?
    let status: String?
    let durationSeconds: Double?
    let targetCount: Int
    let taskCount: Int
    let errorCount: Int
    let warningCount: Int
    let cacheHitCount: Int
    let cacheMissCount: Int
}

struct DiagnosticInfo: Codable {
    let message: String
    let filePath: String?
    let line: Int?
    let column: Int?
}

struct TargetTiming: Codable {
    let name: String
    let projectName: String?
    let durationSeconds: Double
    let taskCount: Int
    let status: String?
}

struct TaskTiming: Codable {
    let taskName: String?
    let executionDescription: String?
    let interestingPath: String?
    let durationSeconds: Double
    let maxRssBytes: Int64?
}

struct TargetBottleneck: Codable {
    let targetName: String
    let durationSeconds: Double
    let blockedCount: Int
    let blockedTargets: [String]
}

struct CriticalPathNode: Codable {
    let targetName: String
    let projectName: String?
    let durationSeconds: Double
}

struct ErrorSearchResult: Codable {
    let buildId: String
    let buildStartedAt: String
    let message: String
    let filePath: String?
    let line: Int?
}

struct ProjectInfo: Codable {
    let identifier: String
    let projectId: String?
    let workspacePath: String?
    let buildCount: Int
    let lastBuildAt: String
    let successCount: Int
    let failureCount: Int
}
