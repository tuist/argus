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
import SWBUtil
import os

/// Performance logger for task execution during builds
/// Logs to a fixed path for debugging and LLM-assisted performance analysis
final class TaskExecutionLogger: @unchecked Sendable {
    private let fileHandle: FileHandle?
    private let lock = Lock()
    private let logPath: String

    static let shared = TaskExecutionLogger()

    private init() {
        // Log to /tmp for easy access and debugging
        logPath = "/tmp/swb-task-execution-perf.log"

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
            Task Execution Performance Log
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

    /// Log task execution with timing and details
    func logTaskExecution(
        ruleInfo: [String],
        actionType: String,
        duration: TimeInterval,
        result: String,
        metrics: (utime: TimeInterval, stime: TimeInterval, maxRSS: Int)? = nil
    ) {
        lock.withLock {
            guard let handle = fileHandle else { return }

            let timestamp = ISO8601DateFormatter().string(from: Date())

            var logEntry = """
            [\(timestamp)] Task Executed: \(ruleInfo.joined(separator: " "))
              Action Type: \(actionType)
              Duration: \(String(format: "%.3f", duration))s (\(String(format: "%.0f", duration * 1000))ms)
              Result: \(result)
            """

            if let metrics = metrics {
                logEntry += """

                  Metrics:
                    User Time: \(String(format: "%.3f", metrics.utime))s
                    System Time: \(String(format: "%.3f", metrics.stime))s
                    Max RSS: \(metrics.maxRSS) bytes
                """
            }

            logEntry += "\n\n"

            if let data = logEntry.data(using: .utf8) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
