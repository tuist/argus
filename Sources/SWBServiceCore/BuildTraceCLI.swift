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
import ToonFormat

/// CLI for querying build trace data.
///
/// Usage: SWBBuildService trace <command> [options]
public enum BuildTraceCLI {
    /// The default path for the build trace database.
    private static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Developer/Xcode/BuildTraces/traces.db"
    }()

    /// Runs the trace CLI with the given arguments.
    ///
    /// - Parameter arguments: Command line arguments (excluding "trace").
    /// - Returns: `true` if the command was handled, `false` otherwise.
    public static func run(arguments: [String]) -> Bool {
        guard !arguments.isEmpty else {
            printUsage()
            return true
        }

        let command = arguments[0]
        let remainingArgs = Array(arguments.dropFirst())

        switch command {
        case "summary":
            return handleSummary(arguments: remainingArgs)
        case "errors":
            return handleErrors(arguments: remainingArgs)
        case "warnings":
            return handleWarnings(arguments: remainingArgs)
        case "slowest-targets":
            return handleSlowestTargets(arguments: remainingArgs)
        case "slowest-tasks":
            return handleSlowestTasks(arguments: remainingArgs)
        case "bottlenecks":
            return handleBottlenecks(arguments: remainingArgs)
        case "critical-path":
            return handleCriticalPath(arguments: remainingArgs)
        case "search-errors":
            return handleSearchErrors(arguments: remainingArgs)
        case "projects":
            return handleProjects(arguments: remainingArgs)
        case "builds":
            return handleBuilds(arguments: remainingArgs)
        case "imports":
            return handleImports(arguments: remainingArgs)
        case "implicit-deps":
            return handleImplicitDeps(arguments: remainingArgs)
        case "redundant-deps":
            return handleRedundantDeps(arguments: remainingArgs)
        case "graph":
            return handleGraph(arguments: remainingArgs)
        case "help", "--help", "-h":
            printUsage()
            return true
        default:
            print("Unknown command: \(command)")
            printUsage()
            return true
        }
    }

    private static func printUsage() {
        print("""
        Usage: SWBBuildService trace <command> [options]

        Commands:
          summary             Show build summary
          errors              Show build errors
          warnings            Show build warnings
          slowest-targets     Show slowest targets
          slowest-tasks       Show slowest tasks
          bottlenecks         Show parallelization bottlenecks
          critical-path       Show critical path through build
          search-errors       Search for errors matching a pattern
          projects            List all projects with build history
          builds              List builds for a project
          imports             Show imports per target (requires import scanning)
          implicit-deps       Show implicit dependencies (imported but not declared)
          redundant-deps      Show redundant dependencies (declared but not imported)
          graph               Query build graph with targets and linking info

        General Options:
          --build <id>        Build ID or "latest" (default: latest)
          --limit <n>         Limit results (default: 10)
          --pattern <text>    Search pattern (for search-errors)
          --project <id>      Filter by project ID
          --workspace <path>  Filter by workspace path
          --target <name>     Filter by target name (for imports command)
          --json              Output as JSON
          --format <fmt>      Output format: json or toon (default: json)

        Graph Options (inspired by Mix xref):
          --source <target>   What does this target depend on? (transitive by default)
          --sink <target>     What depends on this target? (transitive by default)
          --direct            Show only direct dependencies (not transitive)
          --label <type>      Filter by dependency type
          --fields <list>     Control output projection (comma-separated)

        Label Values: target, package, framework, xcframework, sdk, bundle

        Field Values: name, type, linking, status, path, platform, product

        Environment Variables (set when running xcodebuild):
          SWB_BUILD_TRACE_ID         Custom build identifier
          SWB_BUILD_PROJECT_ID       Project identifier for grouping builds
          SWB_BUILD_WORKSPACE_PATH   Workspace path for grouping builds
          SWB_BUILD_TRACE_IMPORTS=0  Disable import scanning (for performance)

        Examples:
          # Build analysis
          SWBBuildService trace summary --build latest
          SWBBuildService trace errors --build latest
          SWBBuildService trace slowest-targets --limit 5

          # Dependency analysis
          SWBBuildService trace implicit-deps --build latest
          SWBBuildService trace redundant-deps --build latest

          # Graph queries (Tuist-style)
          SWBBuildService trace graph                                    # Full graph
          SWBBuildService trace graph --source MyApp                     # All deps of MyApp (transitive)
          SWBBuildService trace graph --source MyApp --direct            # Only direct deps of MyApp
          SWBBuildService trace graph --sink CoreKit                     # What depends on CoreKit?
          SWBBuildService trace graph --source MyApp --label package     # MyApp's package dependencies
          SWBBuildService trace graph --sink CoreKit --fields name,linking
          SWBBuildService trace graph --source MyApp --sink CoreKit      # Path between targets
          SWBBuildService trace graph --fields name,type,linking         # All deps with specific fields
        """)
    }

    private static func openDatabase() -> BuildTraceDatabase? {
        do {
            return try BuildTraceDatabase(path: defaultPath)
        } catch {
            print("Error: Could not open build trace database at \(defaultPath)")
            print("Make sure you have run at least one build with tracing enabled.")
            return nil
        }
    }

    enum OutputFormat: String {
        case json
        case toon
    }

    /// Dependency label types for filtering
    enum DependencyLabel: String, CaseIterable {
        case target
        case package
        case framework
        case xcframework
        case sdk
        case bundle
    }

    /// Available fields for output projection
    enum GraphField: String, CaseIterable {
        case name
        case type
        case linking
        case status
        case path
        case platform
        case product
    }

    struct GraphOptions {
        var source: String? = nil      // --source: What does this target depend on?
        var sink: String? = nil        // --sink: What depends on this target?
        var labels: [DependencyLabel] = []  // --label: Filter by dependency type
        var fields: [GraphField] = []  // --fields: Control output projection
        var format: OutputFormat = .json
        var buildId: String = "latest"
        var directOnly: Bool = false   // --direct: Only show direct dependencies (default: transitive)
    }

    private static func parseGraphOptions(_ arguments: [String]) -> GraphOptions {
        var options = GraphOptions()

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--source":
                if i + 1 < arguments.count {
                    options.source = arguments[i + 1]
                    i += 1
                }
            case "--sink":
                if i + 1 < arguments.count {
                    options.sink = arguments[i + 1]
                    i += 1
                }
            case "--label":
                if i + 1 < arguments.count {
                    let labelStr = arguments[i + 1]
                    if let label = DependencyLabel(rawValue: labelStr) {
                        options.labels.append(label)
                    }
                    i += 1
                }
            case "--fields":
                if i + 1 < arguments.count {
                    let fieldsStr = arguments[i + 1]
                    options.fields = fieldsStr.split(separator: ",").compactMap {
                        GraphField(rawValue: String($0))
                    }
                    i += 1
                }
            case "--format":
                if i + 1 < arguments.count {
                    if let f = OutputFormat(rawValue: arguments[i + 1]) {
                        options.format = f
                    }
                    i += 1
                }
            case "--build":
                if i + 1 < arguments.count {
                    options.buildId = arguments[i + 1]
                    i += 1
                }
            case "--direct":
                options.directOnly = true
            default:
                break
            }
            i += 1
        }

        return options
    }

    private static func parseOptions(_ arguments: [String]) -> (buildId: String, limit: Int, pattern: String?, projectId: String?, workspacePath: String?, targetName: String?, json: Bool, format: OutputFormat) {
        var buildId = "latest"
        var limit = 10
        var pattern: String? = nil
        var projectId: String? = nil
        var workspacePath: String? = nil
        var targetName: String? = nil
        var json = false
        var format: OutputFormat = .json

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--build":
                if i + 1 < arguments.count {
                    buildId = arguments[i + 1]
                    i += 1
                }
            case "--limit":
                if i + 1 < arguments.count, let n = Int(arguments[i + 1]) {
                    limit = n
                    i += 1
                }
            case "--pattern":
                if i + 1 < arguments.count {
                    pattern = arguments[i + 1]
                    i += 1
                }
            case "--project":
                if i + 1 < arguments.count {
                    projectId = arguments[i + 1]
                    i += 1
                }
            case "--workspace":
                if i + 1 < arguments.count {
                    workspacePath = arguments[i + 1]
                    i += 1
                }
            case "--target":
                if i + 1 < arguments.count {
                    targetName = arguments[i + 1]
                    i += 1
                }
            case "--json":
                json = true
                format = .json
            case "--format":
                if i + 1 < arguments.count {
                    if let f = OutputFormat(rawValue: arguments[i + 1]) {
                        format = f
                    }
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        return (buildId, limit, pattern, projectId, workspacePath, targetName, json, format)
    }

    private static func output<T: Encodable>(_ value: T, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } else {
            print(String(describing: value))
        }
    }

    private static func outputWithFormat<T: Encodable>(_ value: T, format: OutputFormat) {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        case .toon:
            let encoder = TOONEncoder()
            if let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        }
    }

    // MARK: - Command handlers

    private static func handleSummary(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)

        guard let summary = db.queryBuildSummary(buildId: options.buildId) else {
            print("No build found")
            return true
        }

        if options.json {
            output(summary, json: true)
        } else {
            print("Build Summary")
            print("=============")
            print("ID:            \(summary.id)")
            print("Status:        \(summary.status ?? "in progress")")
            if let duration = summary.durationSeconds {
                print("Duration:      \(String(format: "%.2f", duration))s")
            }
            print("Targets:       \(summary.targetCount)")
            print("Tasks:         \(summary.taskCount)")
            print("Errors:        \(summary.errorCount)")
            print("Warnings:      \(summary.warningCount)")
            let totalTasks = summary.cacheHitCount + summary.cacheMissCount
            if totalTasks > 0 {
                let hitRate = Double(summary.cacheHitCount) / Double(totalTasks) * 100
                print("Cache hits:    \(summary.cacheHitCount)/\(totalTasks) (\(String(format: "%.1f", hitRate))%)")
            }
        }
        return true
    }

    private static func handleErrors(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let errors = db.queryErrors(buildId: options.buildId)

        if options.json {
            output(errors, json: true)
        } else {
            if errors.isEmpty {
                print("No errors found")
            } else {
                print("Errors (\(errors.count))")
                print("======")
                for error in errors {
                    if let path = error.filePath, let line = error.line {
                        print("\(path):\(line): \(error.message)")
                    } else {
                        print(error.message)
                    }
                }
            }
        }
        return true
    }

    private static func handleWarnings(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let warnings = db.queryWarnings(buildId: options.buildId)

        if options.json {
            output(warnings, json: true)
        } else {
            if warnings.isEmpty {
                print("No warnings found")
            } else {
                print("Warnings (\(warnings.count))")
                print("========")
                for warning in warnings {
                    if let path = warning.filePath, let line = warning.line {
                        print("\(path):\(line): \(warning.message)")
                    } else {
                        print(warning.message)
                    }
                }
            }
        }
        return true
    }

    private static func handleSlowestTargets(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let targets = db.querySlowestTargets(buildId: options.buildId, limit: options.limit)

        if options.json {
            output(targets, json: true)
        } else {
            if targets.isEmpty {
                print("No target timing data found")
            } else {
                print("Slowest Targets")
                print("===============")
                for (i, target) in targets.enumerated() {
                    let project = target.projectName.map { " (\($0))" } ?? ""
                    print("\(i + 1). \(target.name)\(project): \(String(format: "%.2f", target.durationSeconds))s (\(target.taskCount) tasks)")
                }
            }
        }
        return true
    }

    private static func handleSlowestTasks(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let tasks = db.querySlowestTasks(buildId: options.buildId, limit: options.limit)

        if options.json {
            output(tasks, json: true)
        } else {
            if tasks.isEmpty {
                print("No task timing data found")
            } else {
                print("Slowest Tasks")
                print("=============")
                for (i, task) in tasks.enumerated() {
                    let description = task.executionDescription ?? task.taskName ?? "Unknown"
                    var line = "\(i + 1). \(description): \(String(format: "%.2f", task.durationSeconds))s"
                    if let rss = task.maxRssBytes {
                        let mb = Double(rss) / 1_000_000
                        line += " (\(String(format: "%.1f", mb)) MB)"
                    }
                    print(line)
                }
            }
        }
        return true
    }

    private static func handleBottlenecks(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let bottlenecks = db.queryBottlenecks(buildId: options.buildId)

        if options.json {
            output(bottlenecks, json: true)
        } else {
            if bottlenecks.isEmpty {
                print("No bottlenecks detected")
            } else {
                print("Parallelization Bottlenecks")
                print("===========================")
                for bottleneck in bottlenecks {
                    print("\(bottleneck.targetName): \(String(format: "%.2f", bottleneck.durationSeconds))s, blocked \(bottleneck.blockedCount) targets")
                    if !bottleneck.blockedTargets.isEmpty {
                        print("  Blocked: \(bottleneck.blockedTargets.joined(separator: ", "))")
                    }
                }
            }
        }
        return true
    }

    private static func handleCriticalPath(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let path = db.queryCriticalPath(buildId: options.buildId)

        if options.json {
            output(path, json: true)
        } else {
            if path.isEmpty {
                print("No critical path data found")
            } else {
                print("Critical Path")
                print("=============")
                var totalDuration = 0.0
                for (i, node) in path.enumerated() {
                    let project = node.projectName.map { " (\($0))" } ?? ""
                    let arrow = i < path.count - 1 ? " ->" : ""
                    print("\(node.targetName)\(project): \(String(format: "%.2f", node.durationSeconds))s\(arrow)")
                    totalDuration += node.durationSeconds
                }
                print("\nTotal critical path duration: \(String(format: "%.2f", totalDuration))s")
            }
        }
        return true
    }

    private static func handleSearchErrors(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)

        guard let pattern = options.pattern else {
            print("Error: --pattern is required for search-errors")
            return true
        }

        let results = db.searchErrors(pattern: pattern)

        if options.json {
            output(results, json: true)
        } else {
            if results.isEmpty {
                print("No errors matching '\(pattern)' found")
            } else {
                print("Errors matching '\(pattern)' (\(results.count) found)")
                print("=".repeated(40))
                for result in results {
                    print("\nBuild: \(result.buildId) (\(result.buildStartedAt))")
                    if let path = result.filePath, let line = result.line {
                        print("  \(path):\(line)")
                    }
                    print("  \(result.message)")
                }
            }
        }
        return true
    }

    private static func handleProjects(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let projects = db.queryProjects()

        if options.json {
            output(projects, json: true)
        } else {
            if projects.isEmpty {
                print("No projects found")
                print("\nTo associate builds with a project, set environment variables when running xcodebuild:")
                print("  SWB_BUILD_PROJECT_ID=my-project xcodebuild ...")
                print("  SWB_BUILD_WORKSPACE_PATH=/path/to/workspace xcodebuild ...")
            } else {
                print("Projects")
                print("========")
                for project in projects {
                    let successRate = project.buildCount > 0
                        ? Double(project.successCount) / Double(project.buildCount) * 100
                        : 0
                    print("\n\(project.identifier)")
                    if let projectId = project.projectId {
                        print("  Project ID: \(projectId)")
                    }
                    if let workspace = project.workspacePath {
                        print("  Workspace: \(workspace)")
                    }
                    print("  Builds: \(project.buildCount) (\(String(format: "%.0f", successRate))% success)")
                    print("  Last build: \(project.lastBuildAt)")
                }
            }
        }
        return true
    }

    private static func handleBuilds(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)

        if options.projectId == nil && options.workspacePath == nil {
            print("Error: --project or --workspace is required for builds command")
            print("Use 'argus trace projects' to list available projects")
            return true
        }

        let builds = db.queryBuildsForProject(
            projectId: options.projectId,
            workspacePath: options.workspacePath,
            limit: options.limit
        )

        if options.json {
            output(builds, json: true)
        } else {
            if builds.isEmpty {
                print("No builds found for the specified project")
            } else {
                let projectName = options.projectId ?? options.workspacePath ?? "Unknown"
                print("Builds for \(projectName)")
                print("=".repeated(40))
                for build in builds {
                    let status = build.status ?? "in progress"
                    let duration = build.durationSeconds.map { String(format: "%.2fs", $0) } ?? "-"
                    print("\n\(build.id)")
                    print("  Status: \(status)")
                    print("  Duration: \(duration)")
                    print("  Started: \(build.startedAt)")
                    print("  Targets: \(build.targetCount), Tasks: \(build.taskCount)")
                    if build.errorCount > 0 {
                        print("  Errors: \(build.errorCount)")
                    }
                    if build.warningCount > 0 {
                        print("  Warnings: \(build.warningCount)")
                    }
                }
            }
        }
        return true
    }

    // MARK: - Import analysis commands

    private static func handleImports(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let imports = db.queryTargetImports(buildId: options.buildId, targetName: options.targetName)

        if options.json {
            output(imports, json: true)
        } else {
            if imports.isEmpty {
                print("No import data found")
                print("\nImport scanning may not have been enabled during the build.")
                print("Ensure SWB_BUILD_TRACE_IMPORTS is not set to '0' when building.")
            } else {
                print("Target Imports")
                print("==============")
                for targetImport in imports {
                    print("\n\(targetImport.targetName):")
                    for importInfo in targetImport.imports {
                        print("  - \(importInfo.moduleName) (\(importInfo.fileCount) files)")
                    }
                }
            }
        }
        return true
    }

    private static func handleImplicitDeps(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let implicitDeps = db.queryImplicitDependencies(buildId: options.buildId)

        if options.json {
            output(implicitDeps, json: true)
        } else {
            if implicitDeps.isEmpty {
                print("No implicit dependencies found")
                print("\nThis means all imports are properly declared as dependencies.")
            } else {
                print("Implicit Dependencies")
                print("=====================")
                print("These modules are imported but not declared as dependencies:\n")
                for dep in implicitDeps {
                    print("\(dep.targetName) imports \(dep.importedModule)")
                    print("  -> \(dep.suggestion)")
                    if !dep.importingFiles.isEmpty {
                        let fileCount = dep.importingFiles.count
                        let displayFiles = dep.importingFiles.prefix(3)
                        print("  Files: \(displayFiles.joined(separator: ", "))\(fileCount > 3 ? " (+\(fileCount - 3) more)" : "")")
                    }
                    print()
                }
            }
        }
        return true
    }

    private static func handleRedundantDeps(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseOptions(arguments)
        let redundantDeps = db.queryRedundantDependencies(buildId: options.buildId)

        if options.json {
            output(redundantDeps, json: true)
        } else {
            if redundantDeps.isEmpty {
                print("No redundant dependencies found")
                print("\nThis means all declared dependencies are being used.")
            } else {
                print("Redundant Dependencies")
                print("======================")
                print("These dependencies are declared but never imported:\n")
                for dep in redundantDeps {
                    print("\(dep.targetName) declares \(dep.declaredDependency) but never imports it")
                    print("  -> \(dep.suggestion)")
                    print()
                }
            }
        }
        return true
    }

    // MARK: - Build graph commands

    private static func handleGraph(arguments: [String]) -> Bool {
        guard let db = openDatabase() else { return true }
        let options = parseGraphOptions(arguments)

        // Determine query mode based on options
        if let source = options.source, let sink = options.sink {
            // Path between two targets
            guard let path = db.queryGraphPath(
                buildId: options.buildId,
                source: source,
                sink: sink,
                labels: options.labels.map { $0.rawValue },
                fields: options.fields.map { $0.rawValue }
            ) else {
                print("No path found between '\(source)' and '\(sink)'")
                return true
            }
            outputWithFormat(path, format: options.format)

        } else if let source = options.source {
            // What does this target depend on? (--source)
            guard let result = db.queryGraphSource(
                buildId: options.buildId,
                source: source,
                labels: options.labels.map { $0.rawValue },
                fields: options.fields.map { $0.rawValue },
                directOnly: options.directOnly
            ) else {
                print("Target '\(source)' not found in build")
                return true
            }
            if result.dependencies.isEmpty {
                let depType = options.directOnly ? "direct dependencies" : "dependencies"
                print("Target '\(source)' has no \(depType)")
            } else {
                outputWithFormat(result, format: options.format)
            }

        } else if let sink = options.sink {
            // What depends on this target? (--sink)
            guard let result = db.queryGraphSink(
                buildId: options.buildId,
                sink: sink,
                labels: options.labels.map { $0.rawValue },
                fields: options.fields.map { $0.rawValue },
                directOnly: options.directOnly
            ) else {
                print("Target '\(sink)' not found in build")
                return true
            }
            if result.dependents.isEmpty {
                let depType = options.directOnly ? "direct dependents" : "dependents"
                print("No targets are \(depType) of '\(sink)'")
            } else {
                outputWithFormat(result, format: options.format)
            }

        } else {
            // Full graph
            guard let graph = db.queryBuildGraph(
                buildId: options.buildId,
                labels: options.labels.map { $0.rawValue },
                fields: options.fields.map { $0.rawValue }
            ) else {
                print("No build graph data found")
                print("\nProduct type and linking information is recorded during builds.")
                print("Make sure you have run at least one build with tracing enabled.")
                return true
            }

            if graph.targets.isEmpty {
                print("No targets with product information found")
                print("\nThis feature requires product type data to be recorded during builds.")
                return true
            }

            outputWithFormat(graph, format: options.format)
        }

        return true
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}

#endif // canImport(SQLite3)
