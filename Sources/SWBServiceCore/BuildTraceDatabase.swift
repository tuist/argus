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
import SWBProtocol
import SQLite3

/// A SQLite database for storing build trace data.
///
/// The database schema is designed for efficient querying by AI agents,
/// with pre-computed summaries and indexed columns for common access patterns.
final class BuildTraceDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.apple.swiftbuild.tracedb")

    /// Waits for all pending database operations to complete.
    ///
    /// This should be called before the database is closed to ensure
    /// all async operations finish writing to the database.
    func flush() {
        queue.sync {}
    }

    /// Current schema version for migrations.
    private static let schemaVersion = 5

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
        // Ensure all pending async operations complete before closing
        flush()
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
            cache_miss_count INTEGER DEFAULT 0,
            project_id TEXT,
            workspace_path TEXT
        );

        -- Details layer: Individual targets with timing data and product info.
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
            -- Product info (populated when available)
            product_type TEXT,
            artifact_kind TEXT,
            mach_o_type TEXT,
            is_wrapper INTEGER DEFAULT 0,
            product_path TEXT,
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
            depends_on_name TEXT,
            FOREIGN KEY (build_id) REFERENCES builds(id)
        );

        -- Source imports: Tracks which modules each source file imports.
        CREATE TABLE IF NOT EXISTS source_imports (
            id INTEGER PRIMARY KEY,
            build_id TEXT NOT NULL,
            target_id INTEGER NOT NULL,
            target_name TEXT NOT NULL,
            target_guid TEXT,
            source_file TEXT NOT NULL,
            imported_module TEXT NOT NULL,
            FOREIGN KEY (build_id) REFERENCES builds(id)
        );

        -- Linked dependencies: What each target links and how.
        CREATE TABLE IF NOT EXISTS linked_dependencies (
            id INTEGER PRIMARY KEY,
            build_id TEXT NOT NULL,
            target_guid TEXT NOT NULL,
            dependency_path TEXT NOT NULL,
            link_kind TEXT NOT NULL,
            link_mode TEXT NOT NULL,
            dependency_name TEXT,
            is_system INTEGER DEFAULT 0,
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
        CREATE INDEX IF NOT EXISTS idx_source_imports_build_id ON source_imports(build_id);
        CREATE INDEX IF NOT EXISTS idx_source_imports_target ON source_imports(build_id, target_name);
        CREATE INDEX IF NOT EXISTS idx_source_imports_module ON source_imports(build_id, imported_module);
        CREATE INDEX IF NOT EXISTS idx_build_targets_artifact_kind ON build_targets(artifact_kind);
        CREATE INDEX IF NOT EXISTS idx_linked_deps_build ON linked_dependencies(build_id);
        CREATE INDEX IF NOT EXISTS idx_linked_deps_target ON linked_dependencies(target_guid);
        CREATE INDEX IF NOT EXISTS idx_linked_deps_kind ON linked_dependencies(link_kind);

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

        -- Aggregated imports per target
        CREATE VIEW IF NOT EXISTS target_imports AS
        SELECT build_id, target_name, target_guid, imported_module, COUNT(*) as import_count
        FROM source_imports
        GROUP BY build_id, target_name, target_guid, imported_module;
        """

        try execute(schema)
    }

    /// Runs database migrations to update schema from older versions.
    ///
    /// Migration strategy:
    /// - Version 1: Original schema (no project_id/workspace_path)
    /// - Version 2: Added project_id and workspace_path columns to builds table
    /// - Version 3: Added source_imports table for import tracking
    private func runMigrations() throws {
        // Check current schema version
        let currentVersion = querySchemaVersion()

        if currentVersion < 2 {
            // Migration to version 2: Add project_id and workspace_path columns
            // SQLite doesn't support multiple statements in ALTER TABLE via exec,
            // so we execute each separately.
            // Use try? to ignore errors if columns already exist (e.g., from updated schema)
            try? execute("ALTER TABLE builds ADD COLUMN project_id TEXT")
            try? execute("ALTER TABLE builds ADD COLUMN workspace_path TEXT")
        }

        if currentVersion < 3 {
            // Migration to version 3: Add source_imports table
            // The table is created in createTables() via CREATE TABLE IF NOT EXISTS,
            // so we just need to ensure indexes and views exist
            try execute("CREATE INDEX IF NOT EXISTS idx_source_imports_build_id ON source_imports(build_id)")
            try execute("CREATE INDEX IF NOT EXISTS idx_source_imports_target ON source_imports(build_id, target_name)")
            try execute("CREATE INDEX IF NOT EXISTS idx_source_imports_module ON source_imports(build_id, imported_module)")
        }

        if currentVersion < 4 {
            // Migration to version 4: Add depends_on_name column to target_dependencies
            // This allows matching dependencies by name instead of GUID, which is needed
            // because PackageProductTargets have different GUIDs than the actual targets
            // that build, but share the same name.
            try? execute("ALTER TABLE target_dependencies ADD COLUMN depends_on_name TEXT")
        }

        // Migration to version 5: Add product info columns to build_targets and linked_dependencies table.
        // These track product type information and linking relationships for AI agent optimization analysis.
        //
        // Note: We always run addColumnIfNotExists() regardless of schema version because during development,
        // schema version 5 was initially implemented with a separate target_products table, then refactored
        // to merge columns into build_targets. This ensures databases from both development versions work correctly.
        addColumnIfNotExists(table: "build_targets", column: "product_type", type: "TEXT")
        addColumnIfNotExists(table: "build_targets", column: "artifact_kind", type: "TEXT")
        addColumnIfNotExists(table: "build_targets", column: "mach_o_type", type: "TEXT")
        addColumnIfNotExists(table: "build_targets", column: "is_wrapper", type: "INTEGER", defaultValue: "0")
        addColumnIfNotExists(table: "build_targets", column: "product_path", type: "TEXT")

        // Create indexes for the new columns and linked_dependencies table
        try? execute("CREATE INDEX IF NOT EXISTS idx_build_targets_artifact_kind ON build_targets(artifact_kind)")
        try? execute("CREATE INDEX IF NOT EXISTS idx_linked_deps_build ON linked_dependencies(build_id)")
        try? execute("CREATE INDEX IF NOT EXISTS idx_linked_deps_target ON linked_dependencies(target_guid)")
        try? execute("CREATE INDEX IF NOT EXISTS idx_linked_deps_kind ON linked_dependencies(link_kind)")

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

    /// Checks if a column exists in a table.
    private func columnExists(table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(statement, 1) {
                let name = String(cString: namePtr)
                if name == column {
                    return true
                }
            }
        }
        return false
    }

    /// Adds a column to a table if it doesn't already exist.
    private func addColumnIfNotExists(table: String, column: String, type: String, defaultValue: String? = nil) {
        guard !columnExists(table: table, column: column) else { return }
        var sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(type)"
        if let defaultValue = defaultValue {
            sql += " DEFAULT \(defaultValue)"
        }
        try? execute(sql)
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

    func insertDependencyGraph(buildId: String, adjacencyList: [String: [String]], targetNames: [String: String] = [:]) {
        queue.async { [weak self] in
            for (targetGuid, dependencies) in adjacencyList {
                for dependsOnGuid in dependencies {
                    let dependsOnName = targetNames[dependsOnGuid]
                    self?.executeInsert(
                        """
                        INSERT INTO target_dependencies (build_id, target_guid, depends_on_guid, depends_on_name)
                        VALUES (?, ?, ?, ?)
                        """,
                        buildId, targetGuid, dependsOnGuid, dependsOnName
                    )
                }
            }
        }
    }

    func insertSourceImport(
        buildId: String,
        targetId: Int,
        targetName: String,
        targetGuid: String?,
        sourceFile: String,
        importedModule: String
    ) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO source_imports (build_id, target_id, target_name, target_guid, source_file, imported_module)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                buildId, targetId, targetName, targetGuid, sourceFile, importedModule
            )
        }
    }

    func updateTargetProductInfo(
        buildId: String,
        targetGuid: String,
        productType: String?,
        artifactKind: String?,
        machOType: String?,
        isWrapper: Bool,
        productPath: String?
    ) {
        queue.async { [weak self] in
            self?.executeUpdate(
                """
                UPDATE build_targets SET
                    product_type = ?,
                    artifact_kind = ?,
                    mach_o_type = ?,
                    is_wrapper = ?,
                    product_path = ?
                WHERE build_id = ? AND guid = ?
                """,
                productType, artifactKind, machOType, isWrapper ? 1 : 0, productPath, buildId, targetGuid
            )
        }
    }

    /// Inserts a target with product info in one call (for testing or when target info is known upfront)
    func insertTargetWithProductInfo(
        buildId: String,
        targetId: Int,
        guid: String,
        name: String,
        projectName: String?,
        configurationName: String?,
        startedAt: Date,
        productType: String?,
        artifactKind: String?,
        machOType: String?,
        isWrapper: Bool,
        productPath: String?
    ) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO build_targets (build_id, target_id, guid, name, project_name, configuration_name, started_at, product_type, artifact_kind, mach_o_type, is_wrapper, product_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                buildId, targetId, guid, name, projectName, configurationName, startedAt.iso8601String, productType, artifactKind, machOType, isWrapper ? 1 : 0, productPath
            )
        }
    }

    func insertLinkedDependency(
        buildId: String,
        targetGuid: String,
        dependencyPath: String,
        linkKind: String,
        linkMode: String,
        dependencyName: String?,
        isSystem: Bool
    ) {
        queue.async { [weak self] in
            self?.executeInsert(
                """
                INSERT INTO linked_dependencies (build_id, target_guid, dependency_path, link_kind, link_mode, dependency_name, is_system)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                buildId, targetGuid, dependencyPath, linkKind, linkMode, dependencyName, isSystem ? 1 : 0
            )
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

            var memo: [String: (Double, [String])] = [:]

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

            var criticalGuid: String? = nil
            var criticalDuration = 0.0

            for guid in targetDurations.keys {
                let (duration, _) = longestPath(guid)
                if duration > criticalDuration {
                    criticalDuration = duration
                    criticalGuid = guid
                }
            }

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

    // MARK: - Import queries

    /// Queries all imports aggregated by target for a build.
    func queryTargetImports(buildId: String, targetName: String? = nil) -> [TargetImportInfo] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            var sql = """
                SELECT target_name, target_guid, imported_module, import_count
                FROM target_imports
                WHERE build_id = ?
                """
            var bindings: [Any] = [resolvedBuildId]

            if let targetName = targetName {
                sql += " AND target_name = ?"
                bindings.append(targetName)
            }

            sql += " ORDER BY target_name, import_count DESC"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            for (index, binding) in bindings.enumerated() {
                let position = Int32(index + 1)
                if let value = binding as? String {
                    sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }

            var results: [TargetImportInfo] = []
            var currentTarget: String? = nil
            var currentImports: [ImportInfo] = []
            var currentGuid: String? = nil

            while sqlite3_step(statement) == SQLITE_ROW {
                let targetName = String(cString: sqlite3_column_text(statement, 0))
                let targetGuid = sqlite3_column_type(statement, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 1)) : nil
                let moduleName = String(cString: sqlite3_column_text(statement, 2))
                let importCount = Int(sqlite3_column_int(statement, 3))

                if currentTarget != targetName {
                    // Save previous target if exists
                    if let target = currentTarget {
                        results.append(TargetImportInfo(
                            targetName: target,
                            targetGuid: currentGuid,
                            imports: currentImports
                        ))
                    }
                    currentTarget = targetName
                    currentGuid = targetGuid
                    currentImports = []
                }

                currentImports.append(ImportInfo(
                    moduleName: moduleName,
                    fileCount: importCount
                ))
            }

            // Don't forget the last target
            if let target = currentTarget {
                results.append(TargetImportInfo(
                    targetName: target,
                    targetGuid: currentGuid,
                    imports: currentImports
                ))
            }

            return results
        }
    }

    /// Queries implicit dependencies: modules that are imported but not declared as dependencies.
    func queryImplicitDependencies(buildId: String) -> [ImplicitDependency] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            // Find all targets that import modules matching other target names in the build,
            // but where there's no corresponding entry in target_dependencies.
            //
            // We match dependencies by NAME instead of GUID because PackageProductTargets
            // have different GUIDs than the actual library targets that build, but they
            // share the same name. This ensures that dependencies declared in Package.swift
            // manifests are properly recognized.
            let sql = """
                SELECT DISTINCT
                    si.target_name,
                    si.target_guid,
                    si.imported_module,
                    GROUP_CONCAT(DISTINCT si.source_file) as importing_files
                FROM source_imports si
                INNER JOIN build_targets bt ON si.build_id = bt.build_id AND si.imported_module = bt.name
                LEFT JOIN target_dependencies td ON
                    si.build_id = td.build_id AND
                    si.target_guid = td.target_guid AND
                    td.depends_on_name = si.imported_module
                WHERE si.build_id = ?
                    AND td.id IS NULL
                    AND si.target_name != si.imported_module
                GROUP BY si.target_name, si.target_guid, si.imported_module
                ORDER BY si.target_name, si.imported_module
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var results: [ImplicitDependency] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let targetName = String(cString: sqlite3_column_text(statement, 0))
                let importedModule = String(cString: sqlite3_column_text(statement, 2))
                let filesStr = sqlite3_column_type(statement, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(statement, 3)) : ""
                let files = filesStr.split(separator: ",").map(String.init)

                results.append(ImplicitDependency(
                    targetName: targetName,
                    importedModule: importedModule,
                    importingFiles: files,
                    suggestion: "Add dependency: \(targetName) -> \(importedModule)"
                ))
            }

            return results
        }
    }

    /// Queries redundant dependencies: declared dependencies that are never imported.
    func queryRedundantDependencies(buildId: String) -> [RedundantDependency] {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return [] }

            // Find dependencies in target_dependencies that have no matching imports
            let sql = """
                SELECT DISTINCT
                    bt1.name as target_name,
                    bt2.name as dependency_name
                FROM target_dependencies td
                INNER JOIN build_targets bt1 ON td.build_id = bt1.build_id AND td.target_guid = bt1.guid
                INNER JOIN build_targets bt2 ON td.build_id = bt2.build_id AND td.depends_on_guid = bt2.guid
                LEFT JOIN source_imports si ON
                    td.build_id = si.build_id AND
                    bt1.name = si.target_name AND
                    bt2.name = si.imported_module
                WHERE td.build_id = ?
                    AND si.id IS NULL
                ORDER BY bt1.name, bt2.name
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var results: [RedundantDependency] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let targetName = String(cString: sqlite3_column_text(statement, 0))
                let dependencyName = String(cString: sqlite3_column_text(statement, 1))

                results.append(RedundantDependency(
                    targetName: targetName,
                    declaredDependency: dependencyName,
                    suggestion: "Consider removing: \(targetName) -> \(dependencyName)"
                ))
            }

            return results
        }
    }

    // MARK: - Build graph queries (Tuist-style interface)

    /// Maps label strings to link_kind values in the database
    private func labelToLinkKind(_ label: String) -> String? {
        switch label {
        case "target": return nil  // Targets are in build_targets, not linked_dependencies
        case "package": return "static"  // Swift packages typically link statically
        case "framework": return "framework"
        case "xcframework": return "framework"  // XCFrameworks appear as frameworks
        case "sdk": return "dynamic"  // SDK frameworks are dynamic
        case "bundle": return nil  // Bundles don't link
        default: return nil
        }
    }

    /// Filters dependencies by label types
    private func filterDependencies(_ deps: [GraphDependency], labels: [String]) -> [GraphDependency] {
        guard !labels.isEmpty else { return deps }

        return deps.filter { dep in
            for label in labels {
                switch label {
                case "target":
                    // Check if dependency name matches a known target
                    if dep.name != nil { return true }
                case "package":
                    if dep.kind == "static" && !dep.isSystem { return true }
                case "framework":
                    if dep.kind == "framework" || dep.kind == "dynamic" { return true }
                case "xcframework":
                    if dep.path.hasSuffix(".xcframework") { return true }
                case "sdk":
                    if dep.isSystem { return true }
                case "bundle":
                    if dep.path.hasSuffix(".bundle") { return true }
                default:
                    break
                }
            }
            return false
        }
    }

    /// Projects dependency fields based on requested field list
    private func projectDependency(_ dep: GraphDependency, fields: [String]) -> GraphDependency {
        // If no fields specified, return all
        guard !fields.isEmpty else { return dep }

        return GraphDependency(
            name: fields.contains("name") ? dep.name : nil,
            path: fields.contains("path") ? dep.path : "",
            kind: fields.contains("type") || fields.contains("linking") ? dep.kind : "",
            mode: fields.contains("linking") ? dep.mode : "",
            isSystem: dep.isSystem
        )
    }

    /// Queries the full build graph with optional label filtering and field projection.
    func queryBuildGraph(buildId: String, labels: [String] = [], fields: [String] = []) -> BuildGraph? {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return nil }

            // First, get all targets with their product info
            var targetsByGuid: [String: GraphTarget] = [:]
            let productsSql = """
                SELECT guid, name, product_type, artifact_kind, mach_o_type, is_wrapper, product_path
                FROM build_targets
                WHERE build_id = ?
                """
            var productsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, productsSql, -1, &productsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(productsStatement) }

            sqlite3_bind_text(productsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(productsStatement) == SQLITE_ROW {
                let guid = String(cString: sqlite3_column_text(productsStatement, 0))
                let name = String(cString: sqlite3_column_text(productsStatement, 1))
                let productType = sqlite3_column_type(productsStatement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(productsStatement, 2)) : nil
                let artifactKind = sqlite3_column_type(productsStatement, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(productsStatement, 3)) : nil
                let machOType = sqlite3_column_type(productsStatement, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(productsStatement, 4)) : nil
                let isWrapper = sqlite3_column_int(productsStatement, 5) == 1
                let productPath = sqlite3_column_type(productsStatement, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(productsStatement, 6)) : nil

                targetsByGuid[guid] = GraphTarget(
                    name: name,
                    guid: guid,
                    productType: productType,
                    artifactKind: artifactKind,
                    machOType: machOType,
                    isWrapper: isWrapper,
                    productPath: productPath,
                    dependencies: []
                )
            }

            // Then, get all linked dependencies and attach them to targets
            let depsSql = """
                SELECT target_guid, dependency_path, link_kind, link_mode, dependency_name, is_system
                FROM linked_dependencies
                WHERE build_id = ?
                """
            var depsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, depsSql, -1, &depsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(depsStatement) }

            sqlite3_bind_text(depsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var dependenciesByGuid: [String: [GraphDependency]] = [:]
            while sqlite3_step(depsStatement) == SQLITE_ROW {
                let targetGuid = String(cString: sqlite3_column_text(depsStatement, 0))
                let path = String(cString: sqlite3_column_text(depsStatement, 1))
                let kind = String(cString: sqlite3_column_text(depsStatement, 2))
                let mode = String(cString: sqlite3_column_text(depsStatement, 3))
                let name = sqlite3_column_type(depsStatement, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(depsStatement, 4)) : nil
                let isSystem = sqlite3_column_int(depsStatement, 5) == 1

                let dep = GraphDependency(name: name, path: path, kind: kind, mode: mode, isSystem: isSystem)
                dependenciesByGuid[targetGuid, default: []].append(dep)
            }

            // Combine targets with their dependencies, applying filters
            let targets = targetsByGuid.values.map { target in
                let deps = dependenciesByGuid[target.guid] ?? []
                let filteredDeps = filterDependencies(deps, labels: labels)
                let projectedDeps = filteredDeps.map { projectDependency($0, fields: fields) }

                return GraphTarget(
                    name: target.name,
                    guid: target.guid,
                    productType: fields.isEmpty || fields.contains("product") ? target.productType : nil,
                    artifactKind: fields.isEmpty || fields.contains("type") ? target.artifactKind : nil,
                    machOType: target.machOType,
                    isWrapper: target.isWrapper,
                    productPath: fields.isEmpty || fields.contains("path") ? target.productPath : nil,
                    dependencies: projectedDeps
                )
            }.sorted { $0.name < $1.name }

            return BuildGraph(buildId: resolvedBuildId, targets: targets)
        }
    }

    /// Queries what a specific target depends on (--source option).
    /// - Parameters:
    ///   - buildId: The build ID to query
    ///   - source: The source target name
    ///   - labels: Filter by dependency type
    ///   - fields: Control output projection
    ///   - directOnly: If true, only return direct dependencies. If false (default), return all transitive dependencies.
    func queryGraphSource(buildId: String, source: String, labels: [String] = [], fields: [String] = [], directOnly: Bool = false) -> SourceResult? {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return nil }

            // Build target name -> GUID mapping and GUID -> name mapping
            var guidToName: [String: String] = [:]
            var nameToGuid: [String: String] = [:]

            let productsSql = "SELECT guid, name FROM build_targets WHERE build_id = ?"
            var productsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, productsSql, -1, &productsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(productsStatement) }

            sqlite3_bind_text(productsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(productsStatement) == SQLITE_ROW {
                let guid = String(cString: sqlite3_column_text(productsStatement, 0))
                let name = String(cString: sqlite3_column_text(productsStatement, 1))
                guidToName[guid] = name
                nameToGuid[name] = guid
            }

            guard let sourceGuid = nameToGuid[source] else { return nil }

            // Build dependency graph: targetGuid -> [dependency info]
            var dependencyGraph: [String: [GraphDependency]] = [:]

            let depsSql = """
                SELECT target_guid, dependency_path, link_kind, link_mode, dependency_name, is_system
                FROM linked_dependencies
                WHERE build_id = ?
                """
            var depsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, depsSql, -1, &depsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(depsStatement) }

            sqlite3_bind_text(depsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(depsStatement) == SQLITE_ROW {
                let targetGuid = String(cString: sqlite3_column_text(depsStatement, 0))
                let path = String(cString: sqlite3_column_text(depsStatement, 1))
                let kind = String(cString: sqlite3_column_text(depsStatement, 2))
                let mode = String(cString: sqlite3_column_text(depsStatement, 3))
                let name = sqlite3_column_type(depsStatement, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(depsStatement, 4)) : nil
                let isSystem = sqlite3_column_int(depsStatement, 5) == 1

                let dep = GraphDependency(name: name, path: path, kind: kind, mode: mode, isSystem: isSystem)
                dependencyGraph[targetGuid, default: []].append(dep)
            }

            var dependencies: [GraphDependency] = []

            if directOnly {
                // Only direct dependencies
                dependencies = dependencyGraph[sourceGuid] ?? []
            } else {
                // Transitive dependencies: collect all dependencies recursively
                var seen: Set<String> = []  // Track by dependency name/path to avoid duplicates
                var toVisit: [String] = [sourceGuid]

                while !toVisit.isEmpty {
                    let currentGuid = toVisit.removeFirst()
                    guard let deps = dependencyGraph[currentGuid] else { continue }

                    for dep in deps {
                        let key = dep.name ?? dep.path  // Use name if available, otherwise path
                        if !seen.contains(key) {
                            seen.insert(key)
                            dependencies.append(dep)

                            // If this dependency is a known target, add it to visit queue
                            if let depName = dep.name, let depGuid = nameToGuid[depName] {
                                toVisit.append(depGuid)
                            }
                        }
                    }
                }
            }

            let filteredDeps = filterDependencies(dependencies, labels: labels)
            let projectedDeps = filteredDeps.map { projectDependency($0, fields: fields) }

            return SourceResult(source: source, dependencies: projectedDeps)
        }
    }

    /// Queries what targets depend on a specific target (--sink option).
    /// - Parameters:
    ///   - buildId: The build ID to query
    ///   - sink: The sink target name
    ///   - labels: Filter by dependency type
    ///   - fields: Control output projection
    ///   - directOnly: If true, only return direct dependents. If false (default), return all transitive dependents.
    func queryGraphSink(buildId: String, sink: String, labels: [String] = [], fields: [String] = [], directOnly: Bool = false) -> SinkResult? {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return nil }

            // Build target name -> GUID mapping
            var nameToGuid: [String: String] = [:]
            var guidToName: [String: String] = [:]
            var guidToArtifactKind: [String: String?] = [:]

            let productsSql = "SELECT guid, name, artifact_kind FROM build_targets WHERE build_id = ?"
            var productsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, productsSql, -1, &productsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(productsStatement) }

            sqlite3_bind_text(productsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(productsStatement) == SQLITE_ROW {
                let guid = String(cString: sqlite3_column_text(productsStatement, 0))
                let name = String(cString: sqlite3_column_text(productsStatement, 1))
                let artifactKind = sqlite3_column_type(productsStatement, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(productsStatement, 2)) : nil
                nameToGuid[name] = guid
                guidToName[guid] = name
                guidToArtifactKind[guid] = artifactKind
            }

            // Build reverse dependency graph: dependency name -> [(dependent guid, linkKind, linkMode)]
            var reverseDeps: [String: [(guid: String, linkKind: String, linkMode: String)]] = [:]

            let depsSql = """
                SELECT target_guid, dependency_name, link_kind, link_mode
                FROM linked_dependencies
                WHERE build_id = ? AND dependency_name IS NOT NULL
                """
            var depsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, depsSql, -1, &depsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(depsStatement) }

            sqlite3_bind_text(depsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(depsStatement) == SQLITE_ROW {
                let targetGuid = String(cString: sqlite3_column_text(depsStatement, 0))
                let depName = String(cString: sqlite3_column_text(depsStatement, 1))
                let linkKind = String(cString: sqlite3_column_text(depsStatement, 2))
                let linkMode = String(cString: sqlite3_column_text(depsStatement, 3))

                reverseDeps[depName, default: []].append((targetGuid, linkKind, linkMode))
            }

            var dependents: [DependentInfo] = []

            if directOnly {
                // Only direct dependents
                for (guid, linkKind, linkMode) in reverseDeps[sink] ?? [] {
                    if let name = guidToName[guid] {
                        let artifactKind = guidToArtifactKind[guid] ?? nil
                        let info = DependentInfo(
                            name: fields.isEmpty || fields.contains("name") ? name : "",
                            type: fields.isEmpty || fields.contains("type") ? artifactKind : nil,
                            linking: fields.isEmpty || fields.contains("linking") ? linkKind : nil,
                            mode: fields.isEmpty || fields.contains("linking") ? linkMode : nil
                        )
                        dependents.append(info)
                    }
                }
            } else {
                // Transitive dependents: find all targets that transitively depend on sink
                var seen: Set<String> = []  // Track by target name to avoid duplicates
                var toVisit: [String] = [sink]

                while !toVisit.isEmpty {
                    let current = toVisit.removeFirst()
                    guard let directDependents = reverseDeps[current] else { continue }

                    for (guid, linkKind, linkMode) in directDependents {
                        if let name = guidToName[guid], !seen.contains(name) {
                            seen.insert(name)
                            let artifactKind = guidToArtifactKind[guid] ?? nil
                            let info = DependentInfo(
                                name: fields.isEmpty || fields.contains("name") ? name : "",
                                type: fields.isEmpty || fields.contains("type") ? artifactKind : nil,
                                linking: fields.isEmpty || fields.contains("linking") ? linkKind : nil,
                                mode: fields.isEmpty || fields.contains("linking") ? linkMode : nil
                            )
                            dependents.append(info)
                            toVisit.append(name)  // Add to visit queue to find its dependents
                        }
                    }
                }
            }

            dependents.sort { $0.name < $1.name }
            return SinkResult(sink: sink, dependents: dependents)
        }
    }

    /// Queries the path between two targets (--source and --sink together).
    func queryGraphPath(buildId: String, source: String, sink: String, labels: [String] = [], fields: [String] = []) -> PathResult? {
        queue.sync {
            let resolvedBuildId = buildId == "latest" ? queryLatestBuildId() : buildId
            guard let resolvedBuildId else { return nil }

            // Build a dependency graph and find path using BFS
            // First, load all targets and their dependencies
            var graph: [String: [String]] = [:]  // target name -> dependency names
            var allTargets: Set<String> = []

            // Load targets
            let targetsSql = "SELECT name FROM build_targets WHERE build_id = ?"
            var targetsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, targetsSql, -1, &targetsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(targetsStatement) }

            sqlite3_bind_text(targetsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(targetsStatement) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(targetsStatement, 0))
                allTargets.insert(name)
                graph[name] = []
            }

            // Verify source and sink exist
            guard allTargets.contains(source) else { return nil }
            guard allTargets.contains(sink) else { return nil }

            // Load dependencies
            let depsSql = """
                SELECT bt.name, ld.dependency_name
                FROM linked_dependencies ld
                INNER JOIN build_targets bt ON ld.build_id = bt.build_id AND ld.target_guid = bt.guid
                WHERE ld.build_id = ? AND ld.dependency_name IS NOT NULL
                """
            var depsStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, depsSql, -1, &depsStatement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(depsStatement) }

            sqlite3_bind_text(depsStatement, 1, resolvedBuildId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(depsStatement) == SQLITE_ROW {
                let targetName = String(cString: sqlite3_column_text(depsStatement, 0))
                let depName = String(cString: sqlite3_column_text(depsStatement, 1))
                graph[targetName, default: []].append(depName)
            }

            // BFS to find path from source to sink
            var queue: [[String]] = [[source]]
            var visited: Set<String> = [source]

            while !queue.isEmpty {
                let path = queue.removeFirst()
                let current = path.last!

                if current == sink {
                    // Found path
                    return PathResult(source: source, sink: sink, path: path)
                }

                for neighbor in graph[current] ?? [] {
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        queue.append(path + [neighbor])
                    }
                }
            }

            // No path found
            return nil
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

// MARK: - Import analysis result types

struct TargetImportInfo: Codable {
    let targetName: String
    let targetGuid: String?
    let imports: [ImportInfo]
}

struct ImportInfo: Codable {
    let moduleName: String
    let fileCount: Int
}

struct ImplicitDependency: Codable {
    let targetName: String
    let importedModule: String
    let importingFiles: [String]
    let suggestion: String
}

struct RedundantDependency: Codable {
    let targetName: String
    let declaredDependency: String
    let suggestion: String
}

// MARK: - Build graph result types

struct GraphTarget: Codable {
    let name: String
    let guid: String
    let productType: String?
    let artifactKind: String?
    let machOType: String?
    let isWrapper: Bool
    let productPath: String?
    let dependencies: [GraphDependency]
}

struct GraphDependency: Codable {
    let name: String?
    let path: String
    let kind: String
    let mode: String
    let isSystem: Bool
}

struct BuildGraph: Codable {
    let buildId: String
    let targets: [GraphTarget]
}

struct DepsResult: Codable {
    let target: String
    let dependencies: [GraphDependency]
}

struct CallersResult: Codable {
    let target: String
    let callers: [CallerInfo]
}

struct CallerInfo: Codable {
    let name: String
    let kind: String
    let mode: String
}

// MARK: - Tuist-style graph query result types

/// Result for --source queries: what does this target depend on?
struct SourceResult: Codable {
    let source: String
    let dependencies: [GraphDependency]
}

/// Result for --sink queries: what depends on this target?
struct SinkResult: Codable {
    let sink: String
    let dependents: [DependentInfo]
}

/// Information about a target that depends on the sink
struct DependentInfo: Codable {
    let name: String
    let type: String?
    let linking: String?
    let mode: String?
}

/// Result for path queries: path between --source and --sink
struct PathResult: Codable {
    let source: String
    let sink: String
    let path: [String]
}

#endif // canImport(SQLite3)
