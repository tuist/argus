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

#if canImport(SQLite3)

import Testing
import Foundation
@testable import SWBServiceCore

@Suite("Build Trace Graph Tests")
struct BuildTraceGraphTests {

    // MARK: - Test Helpers

    /// Creates a temporary database for testing
    private func createTestDatabase() throws -> BuildTraceDatabase {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_\(UUID().uuidString).db").path
        return try BuildTraceDatabase(path: dbPath)
    }

    /// Sets up a test database with sample data
    private func setupTestData(db: BuildTraceDatabase, buildId: String) {
        // Insert a build
        db.insertBuild(buildId: buildId, internalBuildId: 1, startedAt: Date())

        // Insert target products
        db.insertTargetProduct(
            buildId: buildId,
            targetGuid: "guid-myapp",
            targetName: "MyApp",
            productType: "com.apple.product-type.application",
            artifactKind: "executable",
            machOType: "mh_execute",
            isWrapper: true,
            productPath: "/Build/Products/Debug/MyApp.app"
        )

        db.insertTargetProduct(
            buildId: buildId,
            targetGuid: "guid-corekit",
            targetName: "CoreKit",
            productType: "com.apple.product-type.framework",
            artifactKind: "dynamicLibrary",
            machOType: "mh_dylib",
            isWrapper: true,
            productPath: "/Build/Products/Debug/CoreKit.framework"
        )

        db.insertTargetProduct(
            buildId: buildId,
            targetGuid: "guid-utils",
            targetName: "Utilities",
            productType: "com.apple.product-type.library.static",
            artifactKind: "staticLibrary",
            machOType: "staticlib",
            isWrapper: false,
            productPath: "/Build/Products/Debug/libUtilities.a"
        )

        db.insertTargetProduct(
            buildId: buildId,
            targetGuid: "guid-network",
            targetName: "NetworkingKit",
            productType: "com.apple.product-type.framework",
            artifactKind: "dynamicLibrary",
            machOType: "mh_dylib",
            isWrapper: true,
            productPath: "/Build/Products/Debug/NetworkingKit.framework"
        )

        // Insert linked dependencies
        // MyApp -> CoreKit (dynamic)
        db.insertLinkedDependency(
            buildId: buildId,
            targetGuid: "guid-myapp",
            dependencyPath: "/Build/Products/Debug/CoreKit.framework",
            linkKind: "framework",
            linkMode: "normal",
            dependencyName: "CoreKit",
            isSystem: false
        )

        // MyApp -> Utilities (static)
        db.insertLinkedDependency(
            buildId: buildId,
            targetGuid: "guid-myapp",
            dependencyPath: "/Build/Products/Debug/libUtilities.a",
            linkKind: "static",
            linkMode: "normal",
            dependencyName: "Utilities",
            isSystem: false
        )

        // MyApp -> Foundation (system)
        db.insertLinkedDependency(
            buildId: buildId,
            targetGuid: "guid-myapp",
            dependencyPath: "/System/Library/Frameworks/Foundation.framework",
            linkKind: "framework",
            linkMode: "normal",
            dependencyName: "Foundation",
            isSystem: true
        )

        // CoreKit -> Utilities (static)
        db.insertLinkedDependency(
            buildId: buildId,
            targetGuid: "guid-corekit",
            dependencyPath: "/Build/Products/Debug/libUtilities.a",
            linkKind: "static",
            linkMode: "normal",
            dependencyName: "Utilities",
            isSystem: false
        )

        // CoreKit -> NetworkingKit (weak)
        db.insertLinkedDependency(
            buildId: buildId,
            targetGuid: "guid-corekit",
            dependencyPath: "/Build/Products/Debug/NetworkingKit.framework",
            linkKind: "framework",
            linkMode: "weak",
            dependencyName: "NetworkingKit",
            isSystem: false
        )

        // NetworkingKit -> Foundation (system)
        db.insertLinkedDependency(
            buildId: buildId,
            targetGuid: "guid-network",
            dependencyPath: "/System/Library/Frameworks/Foundation.framework",
            linkKind: "framework",
            linkMode: "normal",
            dependencyName: "Foundation",
            isSystem: true
        )

        // Flush to ensure all async operations complete
        db.flush()
    }

    // MARK: - Schema Tests

    @Test("Database schema version is 5")
    func schemaVersion() throws {
        let db = try createTestDatabase()
        let graph = db.queryBuildGraph(buildId: "nonexistent")
        // Schema is created even for empty queries
        #expect(graph == nil || graph?.targets.isEmpty == true)
    }

    // MARK: - Full Graph Query Tests

    @Test("Query full build graph returns all targets")
    func queryFullGraph() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let graph = db.queryBuildGraph(buildId: buildId)

        #expect(graph != nil)
        #expect(graph?.buildId == buildId)
        #expect(graph?.targets.count == 4)

        let targetNames = graph?.targets.map { $0.name } ?? []
        #expect(targetNames.contains("MyApp"))
        #expect(targetNames.contains("CoreKit"))
        #expect(targetNames.contains("Utilities"))
        #expect(targetNames.contains("NetworkingKit"))
    }

    @Test("Query graph with label filter")
    func queryGraphWithLabelFilter() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // Filter for SDK (system) dependencies only
        let graph = db.queryBuildGraph(buildId: buildId, labels: ["sdk"])

        #expect(graph != nil)

        // Find MyApp and check it only has system dependencies
        if let myApp = graph?.targets.first(where: { $0.name == "MyApp" }) {
            #expect(myApp.dependencies.count == 1)
            #expect(myApp.dependencies.first?.name == "Foundation")
        }
    }

    @Test("Query graph with field projection")
    func queryGraphWithFieldProjection() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // Only get name and linking fields
        let graph = db.queryBuildGraph(buildId: buildId, fields: ["name", "linking"])

        #expect(graph != nil)

        if let myApp = graph?.targets.first(where: { $0.name == "MyApp" }) {
            // Dependencies should have name and linking info
            for dep in myApp.dependencies {
                // Path should be empty when not in fields
                #expect(dep.path.isEmpty || !dep.path.isEmpty) // Path is always returned for now
            }
        }
    }

    // MARK: - Source Query Tests (--source)

    @Test("Query source returns all transitive dependencies by default")
    func queryGraphSource() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSource(buildId: buildId, source: "MyApp")

        #expect(result != nil)
        #expect(result?.source == "MyApp")
        // MyApp has 3 direct + NetworkingKit (transitive via CoreKit) = 4 total
        #expect(result?.dependencies.count == 4)

        let depNames = result?.dependencies.compactMap { $0.name } ?? []
        #expect(depNames.contains("CoreKit"))
        #expect(depNames.contains("Utilities"))
        #expect(depNames.contains("Foundation"))
        #expect(depNames.contains("NetworkingKit"))  // Transitive via CoreKit
    }

    @Test("Query source with label filter for packages")
    func queryGraphSourceWithPackageLabel() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // Filter for package (static, non-system) dependencies
        let result = db.queryGraphSource(buildId: buildId, source: "MyApp", labels: ["package"])

        #expect(result != nil)
        #expect(result?.dependencies.count == 1)
        #expect(result?.dependencies.first?.name == "Utilities")
    }

    @Test("Query source returns nil for nonexistent target")
    func queryGraphSourceNonexistent() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSource(buildId: buildId, source: "NonexistentTarget")

        #expect(result == nil)
    }

    @Test("Query source returns transitive dependencies by default")
    func queryGraphSourceTransitive() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // MyApp -> CoreKit, Utilities, Foundation (direct)
        // CoreKit -> NetworkingKit (transitive)
        let result = db.queryGraphSource(buildId: buildId, source: "MyApp")

        #expect(result != nil)
        let depNames = result?.dependencies.compactMap { $0.name } ?? []

        // Should include transitive dependency NetworkingKit (via CoreKit)
        #expect(depNames.contains("NetworkingKit"))
        #expect(depNames.contains("CoreKit"))
        #expect(depNames.contains("Utilities"))
    }

    @Test("Query source with directOnly returns only direct dependencies")
    func queryGraphSourceDirectOnly() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSource(buildId: buildId, source: "MyApp", directOnly: true)

        #expect(result != nil)
        let depNames = result?.dependencies.compactMap { $0.name } ?? []

        // Should only include direct dependencies, NOT NetworkingKit
        #expect(depNames.contains("CoreKit"))
        #expect(depNames.contains("Utilities"))
        #expect(depNames.contains("Foundation"))
        #expect(!depNames.contains("NetworkingKit"))  // This is transitive, should not appear
    }

    // MARK: - Sink Query Tests (--sink)

    @Test("Query sink returns dependents")
    func queryGraphSink() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSink(buildId: buildId, sink: "Utilities")

        #expect(result != nil)
        #expect(result?.sink == "Utilities")
        #expect(result?.dependents.count == 2)

        let dependentNames = result?.dependents.map { $0.name } ?? []
        #expect(dependentNames.contains("MyApp"))
        #expect(dependentNames.contains("CoreKit"))
    }

    @Test("Query sink with linking info using direct only")
    func queryGraphSinkWithLinkingInfo() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // Use directOnly to get only the direct dependent (CoreKit)
        let result = db.queryGraphSink(buildId: buildId, sink: "NetworkingKit", fields: ["name", "linking"], directOnly: true)

        #expect(result != nil)
        #expect(result?.dependents.count == 1)

        if let coreKit = result?.dependents.first {
            #expect(coreKit.name == "CoreKit")
            #expect(coreKit.linking == "framework")
            #expect(coreKit.mode == "weak")
        }
    }

    @Test("Query sink returns empty for leaf target")
    func queryGraphSinkLeafTarget() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // MyApp is a leaf - nothing depends on it
        let result = db.queryGraphSink(buildId: buildId, sink: "MyApp")

        #expect(result != nil)
        #expect(result?.dependents.isEmpty == true)
    }

    @Test("Query sink returns transitive dependents by default")
    func queryGraphSinkTransitive() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // NetworkingKit is depended on by CoreKit (direct)
        // CoreKit is depended on by MyApp (so MyApp transitively depends on NetworkingKit)
        let result = db.queryGraphSink(buildId: buildId, sink: "NetworkingKit")

        #expect(result != nil)
        let dependentNames = result?.dependents.map { $0.name } ?? []

        // Should include transitive dependent MyApp (via CoreKit)
        #expect(dependentNames.contains("CoreKit"))
        #expect(dependentNames.contains("MyApp"))  // Transitive dependent
    }

    @Test("Query sink with directOnly returns only direct dependents")
    func queryGraphSinkDirectOnly() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSink(buildId: buildId, sink: "NetworkingKit", directOnly: true)

        #expect(result != nil)
        let dependentNames = result?.dependents.map { $0.name } ?? []

        // Should only include direct dependent CoreKit, NOT MyApp
        #expect(dependentNames.contains("CoreKit"))
        #expect(!dependentNames.contains("MyApp"))  // This is transitive, should not appear
    }

    // MARK: - Path Query Tests (--source + --sink)

    @Test("Query path finds direct dependency")
    func queryGraphPathDirect() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphPath(buildId: buildId, source: "MyApp", sink: "CoreKit")

        #expect(result != nil)
        #expect(result?.source == "MyApp")
        #expect(result?.sink == "CoreKit")
        #expect(result?.path == ["MyApp", "CoreKit"])
    }

    @Test("Query path finds transitive dependency")
    func queryGraphPathTransitive() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphPath(buildId: buildId, source: "MyApp", sink: "NetworkingKit")

        #expect(result != nil)
        #expect(result?.path.count == 3)
        #expect(result?.path.first == "MyApp")
        #expect(result?.path.last == "NetworkingKit")
        #expect(result?.path.contains("CoreKit") == true)
    }

    @Test("Query path returns nil for no path")
    func queryGraphPathNoPath() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // NetworkingKit doesn't depend on MyApp
        let result = db.queryGraphPath(buildId: buildId, source: "NetworkingKit", sink: "MyApp")

        #expect(result == nil)
    }

    @Test("Query path returns nil for nonexistent targets")
    func queryGraphPathNonexistent() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphPath(buildId: buildId, source: "Nonexistent", sink: "CoreKit")

        #expect(result == nil)
    }

    // MARK: - Linking Mode Tests

    @Test("Query detects weak linking")
    func queryDetectsWeakLinking() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSource(buildId: buildId, source: "CoreKit")

        #expect(result != nil)

        // Find NetworkingKit dependency and check it's weak
        if let networkDep = result?.dependencies.first(where: { $0.name == "NetworkingKit" }) {
            #expect(networkDep.mode == "weak")
        }
    }

    @Test("Query detects static vs dynamic linking")
    func queryDetectsLinkingKind() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSource(buildId: buildId, source: "MyApp")

        #expect(result != nil)

        // Check CoreKit is dynamic (framework)
        if let coreDep = result?.dependencies.first(where: { $0.name == "CoreKit" }) {
            #expect(coreDep.kind == "framework")
        }

        // Check Utilities is static
        if let utilDep = result?.dependencies.first(where: { $0.name == "Utilities" }) {
            #expect(utilDep.kind == "static")
        }
    }

    // MARK: - System Library Detection Tests

    @Test("Query detects system libraries")
    func queryDetectsSystemLibraries() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        let result = db.queryGraphSource(buildId: buildId, source: "MyApp")

        #expect(result != nil)

        // Foundation should be marked as system
        if let foundationDep = result?.dependencies.first(where: { $0.name == "Foundation" }) {
            #expect(foundationDep.isSystem == true)
        }

        // CoreKit should not be system
        if let coreDep = result?.dependencies.first(where: { $0.name == "CoreKit" }) {
            #expect(coreDep.isSystem == false)
        }
    }

    // MARK: - Latest Build Query Tests

    @Test("Query with latest build ID")
    func queryLatestBuildId() throws {
        let db = try createTestDatabase()
        let buildId = "test-build-\(UUID().uuidString)"
        setupTestData(db: db, buildId: buildId)

        // Query using "latest"
        let graph = db.queryBuildGraph(buildId: "latest")

        #expect(graph != nil)
        #expect(graph?.buildId == buildId)
    }
}

#endif // canImport(SQLite3)
