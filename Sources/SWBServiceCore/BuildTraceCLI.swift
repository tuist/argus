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

public import ArgumentParser
import Foundation
import ToonFormat

// MARK: - Output Format

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case json
    case toon
}

// MARK: - Dependency Labels

enum DependencyLabel: String, ExpressibleByArgument, CaseIterable {
    case target
    case package
    case framework
    case xcframework
    case sdk
    case bundle
}

// MARK: - Graph Fields

enum GraphField: String, ExpressibleByArgument, CaseIterable {
    case name
    case type
    case linking
    case status
    case path
    case platform
    case product
}

// MARK: - Common Options

struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: "Build ID or 'latest'")
    var build: String = "latest"

    @Option(name: .long, help: "Limit results")
    var limit: Int = 10

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .json
}

// MARK: - Database Helper

private let defaultDatabasePath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Developer/Xcode/BuildTraces/traces.db"
}()

private func openDatabase() -> BuildTraceDatabase? {
    do {
        return try BuildTraceDatabase(path: defaultDatabasePath)
    } catch {
        print("Error: Could not open build trace database at \(defaultDatabasePath)")
        print("Details: \(error)")
        print("Make sure you have run at least one build with tracing enabled.")
        return nil
    }
}

private func output<T: Encodable>(_ value: T, json: Bool) {
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

private func outputWithFormat<T: Encodable>(_ value: T, format: OutputFormat) {
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

// MARK: - Main Command

public struct TraceCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "trace",
        abstract: "Query build trace data",
        subcommands: [
            Summary.self,
            Errors.self,
            Warnings.self,
            SlowestTargets.self,
            SlowestTasks.self,
            Bottlenecks.self,
            CriticalPath.self,
            SearchErrors.self,
            Projects.self,
            Builds.self,
            Imports.self,
            ImplicitDeps.self,
            RedundantDeps.self,
            Graph.self,
        ]
    )

    public init() {}
}

// MARK: - Summary Command

struct Summary: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show build summary"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }

        guard let summary = db.queryBuildSummary(buildId: options.build) else {
            print("No build found")
            return
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
    }
}

// MARK: - Errors Command

struct Errors: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show build errors"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let errors = db.queryErrors(buildId: options.build)

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
    }
}

// MARK: - Warnings Command

struct Warnings: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show build warnings"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let warnings = db.queryWarnings(buildId: options.build)

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
    }
}

// MARK: - Slowest Targets Command

struct SlowestTargets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slowest-targets",
        abstract: "Show slowest targets"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let targets = db.querySlowestTargets(buildId: options.build, limit: options.limit)

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
    }
}

// MARK: - Slowest Tasks Command

struct SlowestTasks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slowest-tasks",
        abstract: "Show slowest tasks"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let tasks = db.querySlowestTasks(buildId: options.build, limit: options.limit)

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
    }
}

// MARK: - Bottlenecks Command

struct Bottlenecks: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show parallelization bottlenecks"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let bottlenecks = db.queryBottlenecks(buildId: options.build)

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
    }
}

// MARK: - Critical Path Command

struct CriticalPath: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "critical-path",
        abstract: "Show critical path through build"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let path = db.queryCriticalPath(buildId: options.build)

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
    }
}

// MARK: - Search Errors Command

struct SearchErrors: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-errors",
        abstract: "Search for errors matching a pattern"
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "Search pattern")
    var pattern: String

    func run() throws {
        guard let db = openDatabase() else { return }
        let results = db.searchErrors(pattern: pattern)

        if options.json {
            output(results, json: true)
        } else {
            if results.isEmpty {
                print("No errors matching '\(pattern)' found")
            } else {
                print("Errors matching '\(pattern)' (\(results.count) found)")
                print(String(repeating: "=", count: 40))
                for result in results {
                    print("\nBuild: \(result.buildId) (\(result.buildStartedAt))")
                    if let path = result.filePath, let line = result.line {
                        print("  \(path):\(line)")
                    }
                    print("  \(result.message)")
                }
            }
        }
    }
}

// MARK: - Projects Command

struct Projects: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all projects with build history"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
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
    }
}

// MARK: - Builds Command

struct Builds: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List builds for a project"
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "Filter by project ID")
    var project: String?

    @Option(name: .long, help: "Filter by workspace path")
    var workspace: String?

    func run() throws {
        guard let db = openDatabase() else { return }

        if project == nil && workspace == nil {
            print("Error: --project or --workspace is required for builds command")
            print("Use 'trace projects' to list available projects")
            return
        }

        let builds = db.queryBuildsForProject(
            projectId: project,
            workspacePath: workspace,
            limit: options.limit
        )

        if options.json {
            output(builds, json: true)
        } else {
            if builds.isEmpty {
                print("No builds found for the specified project")
            } else {
                let projectName = project ?? workspace ?? "Unknown"
                print("Builds for \(projectName)")
                print(String(repeating: "=", count: 40))
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
    }
}

// MARK: - Imports Command

struct Imports: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show imports per target"
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "Filter by target name")
    var target: String?

    func run() throws {
        guard let db = openDatabase() else { return }
        let imports = db.queryTargetImports(buildId: options.build, targetName: target)

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
    }
}

// MARK: - Implicit Deps Command

struct ImplicitDeps: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "implicit-deps",
        abstract: "Show implicit dependencies (imported but not declared)"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let implicitDeps = db.queryImplicitDependencies(buildId: options.build)

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
    }
}

// MARK: - Redundant Deps Command

struct RedundantDeps: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "redundant-deps",
        abstract: "Show redundant dependencies (declared but not imported)"
    )

    @OptionGroup var options: CommonOptions

    func run() throws {
        guard let db = openDatabase() else { return }
        let redundantDeps = db.queryRedundantDependencies(buildId: options.build)

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
    }
}

// MARK: - Graph Command

struct Graph: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Query build graph with targets and linking info",
        discussion: """
        Query the build dependency graph using Tuist-style options inspired by Mix xref.

        Examples:
          trace graph                                    # Full graph
          trace graph --source MyApp                     # All deps of MyApp (transitive)
          trace graph --source MyApp --direct            # Only direct deps of MyApp
          trace graph --sink CoreKit                     # What depends on CoreKit?
          trace graph --source MyApp --label package     # MyApp's package dependencies
          trace graph --source MyApp --sink CoreKit      # Path between targets
        """
    )

    @Option(name: .long, help: "Build ID or 'latest'")
    var build: String = "latest"

    @Option(name: .long, help: "What does this target depend on?")
    var source: String?

    @Option(name: .long, help: "What depends on this target?")
    var sink: String?

    @Flag(name: .long, help: "Show only direct dependencies (not transitive)")
    var direct: Bool = false

    @Option(name: .long, parsing: .upToNextOption, help: "Filter by dependency type")
    var label: [DependencyLabel] = []

    @Option(name: .long, help: "Control output projection (comma-separated)")
    var fields: String?

    @Option(name: .long, help: "Output format")
    var format: OutputFormat = .json

    func run() throws {
        guard let db = openDatabase() else { return }

        let parsedFields = fields?.split(separator: ",").compactMap { GraphField(rawValue: String($0)) } ?? []

        // Determine query mode based on options
        if let source = source, let sink = sink {
            // Path between two targets
            guard let path = db.queryGraphPath(
                buildId: build,
                source: source,
                sink: sink,
                labels: label.map { $0.rawValue },
                fields: parsedFields.map { $0.rawValue }
            ) else {
                print("No path found between '\(source)' and '\(sink)'")
                return
            }
            outputWithFormat(path, format: format)

        } else if let source = source {
            // What does this target depend on? (--source)
            guard let result = db.queryGraphSource(
                buildId: build,
                source: source,
                labels: label.map { $0.rawValue },
                fields: parsedFields.map { $0.rawValue },
                directOnly: direct
            ) else {
                print("Target '\(source)' not found in build")
                return
            }
            if result.dependencies.isEmpty {
                let depType = direct ? "direct dependencies" : "dependencies"
                print("Target '\(source)' has no \(depType)")
            } else {
                outputWithFormat(result, format: format)
            }

        } else if let sink = sink {
            // What depends on this target? (--sink)
            guard let result = db.queryGraphSink(
                buildId: build,
                sink: sink,
                labels: label.map { $0.rawValue },
                fields: parsedFields.map { $0.rawValue },
                directOnly: direct
            ) else {
                print("Target '\(sink)' not found in build")
                return
            }
            if result.dependents.isEmpty {
                let depType = direct ? "direct dependents" : "dependents"
                print("No targets are \(depType) of '\(sink)'")
            } else {
                outputWithFormat(result, format: format)
            }

        } else {
            // Full graph
            guard let graph = db.queryBuildGraph(
                buildId: build,
                labels: label.map { $0.rawValue },
                fields: parsedFields.map { $0.rawValue }
            ) else {
                print("No build graph data found")
                print("\nProduct type and linking information is recorded during builds.")
                print("Make sure you have run at least one build with tracing enabled.")
                return
            }

            if graph.targets.isEmpty {
                print("No targets with product information found")
                print("\nThis feature requires product type data to be recorded during builds.")
                return
            }

            outputWithFormat(graph, format: format)
        }
    }
}

// MARK: - Legacy Entry Point

/// Legacy entry point for backwards compatibility.
/// Prefer using TraceCommand.main() directly.
public enum BuildTraceCLI {
    public static func run(arguments: [String]) -> Bool {
        do {
            var command = try TraceCommand.parseAsRoot(arguments)
            try command.run()
            return true
        } catch {
            TraceCommand.exit(withError: error)
        }
    }
}

#endif // canImport(SQLite3)
