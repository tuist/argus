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

package import Foundation
import SWBUtil
import os

/// Performance logger for build description operations
/// Logs to a fixed path for debugging and LLM-assisted performance analysis
package final class BuildDescriptionPerformanceLogger: @unchecked Sendable {
    private let fileHandle: FileHandle?
    private let lock = Lock()
    private let logPath: String

    package static let shared = BuildDescriptionPerformanceLogger()

    private init() {
        // Log to /tmp for easy access and debugging
        logPath = "/tmp/swb-build-description-perf.log"

        // Create or append to log file
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logPath) {
            fileManager.createFile(atPath: logPath, contents: nil)
        }

        fileHandle = FileHandle(forWritingAtPath: logPath)

        // Write session header
        if let handle = fileHandle {
            let header = """

            ================================================================================
            Build Description Performance Log
            Session started: \(ISO8601DateFormatter().string(from: Date()))
            PID: \(ProcessInfo.processInfo.processIdentifier)
            ================================================================================

            """
            if let data = header.data(using: .utf8) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Log a performance event with timing information
    package func log(
        _ operation: String,
        duration: TimeInterval,
        details: [String: String] = [:],
        file: String = #file,
        line: Int = #line
    ) {
        lock.withLock {
            guard let handle = fileHandle else { return }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let location = "\((file as NSString).lastPathComponent):\(line)"

            var logEntry = """
            [\(timestamp)] \(operation)
              Duration: \(String(format: "%.3f", duration))s (\(String(format: "%.0f", duration * 1000))ms)
              Location: \(location)
            """

            if !details.isEmpty {
                logEntry += "\n  Details:"
                for (key, value) in details.sorted(by: { $0.key < $1.key }) {
                    logEntry += "\n    \(key): \(value)"
                }
            }

            logEntry += "\n\n"

            if let data = logEntry.data(using: .utf8) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Log a phase start
    package func logPhaseStart(_ phase: String, details: [String: String] = [:]) {
        lock.withLock {
            guard let handle = fileHandle else { return }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            var logEntry = """
            [\(timestamp)] >>> PHASE START: \(phase)
            """

            if !details.isEmpty {
                logEntry += "\n  Details:"
                for (key, value) in details.sorted(by: { $0.key < $1.key }) {
                    logEntry += "\n    \(key): \(value)"
                }
            }

            logEntry += "\n\n"

            if let data = logEntry.data(using: .utf8) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Log a phase end
    package func logPhaseEnd(_ phase: String, duration: TimeInterval, details: [String: String] = [:]) {
        lock.withLock {
            guard let handle = fileHandle else { return }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            var logEntry = """
            [\(timestamp)] <<< PHASE END: \(phase)
              Total Duration: \(String(format: "%.3f", duration))s (\(String(format: "%.0f", duration * 1000))ms)
            """

            if !details.isEmpty {
                logEntry += "\n  Details:"
                for (key, value) in details.sorted(by: { $0.key < $1.key }) {
                    logEntry += "\n    \(key): \(value)"
                }
            }

            logEntry += "\n\n"

            if let data = logEntry.data(using: .utf8) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Measure and log a synchronous operation
    package func measure<T>(_ operation: String, details: [String: String] = [:], file: String = #file, line: Int = #line, block: () throws -> T) rethrows -> T {
        let start = Date()
        defer {
            let duration = Date().timeIntervalSince(start)
            log(operation, duration: duration, details: details, file: file, line: line)
        }
        return try block()
    }

    /// Measure and log an async operation
    package func measure<T>(_ operation: String, details: [String: String] = [:], file: String = #file, line: Int = #line, block: () async throws -> T) async rethrows -> T {
        let start = Date()
        defer {
            let duration = Date().timeIntervalSince(start)
            log(operation, duration: duration, details: details, file: file, line: line)
        }
        return try await block()
    }
}

/// Helper for tracking phase timing
package struct PerformancePhase {
    let name: String
    let startTime: Date
    var details: [String: String]

    package init(name: String, details: [String: String] = [:]) {
        self.name = name
        self.startTime = Date()
        self.details = details
        BuildDescriptionPerformanceLogger.shared.logPhaseStart(name, details: details)
    }

    package func end(additionalDetails: [String: String] = [:]) {
        let duration = Date().timeIntervalSince(startTime)
        var allDetails = details
        allDetails.merge(additionalDetails) { _, new in new }
        BuildDescriptionPerformanceLogger.shared.logPhaseEnd(name, duration: duration, details: allDetails)
    }
}
