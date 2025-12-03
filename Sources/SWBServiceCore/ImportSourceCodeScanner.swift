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

import Foundation

/// Supported programming languages for import scanning.
enum SourceLanguage {
    case swift
    case objc

    /// Determines the language from a file extension.
    static func from(extension ext: String) -> SourceLanguage? {
        switch ext.lowercased() {
        case "swift":
            return .swift
        case "m", "mm", "h", "c", "cpp", "cc", "cxx":
            return .objc
        default:
            return nil
        }
    }
}

/// Extracts import statements from Swift and Objective-C source files.
///
/// This scanner uses regex patterns to identify import statements and extract
/// the module names being imported. It handles:
/// - Swift `import` statements (including specific imports like `import struct Foo.Bar`)
/// - Objective-C `@import` statements
/// - C/Objective-C `#import` and `#include` statements
final class ImportSourceCodeScanner {

    /// Extracts all imported module names from source code.
    ///
    /// - Parameters:
    ///   - sourceCode: The source code content to scan.
    ///   - language: The programming language of the source code.
    /// - Returns: A set of unique module names that are imported.
    /// - Throws: If regex compilation fails.
    func extractImports(from sourceCode: String, language: SourceLanguage) throws -> Set<String> {
        let codeWithoutComments = try removeComments(from: sourceCode)

        let pattern: String
        switch language {
        case .swift:
            // Matches: import Foundation, import struct Foo.Bar, etc.
            pattern = #"import\s+(?:struct\s+|enum\s+|class\s+|protocol\s+|func\s+|var\s+|let\s+|typealias\s+)?([\w]+)"#
        case .objc:
            // Matches: @import Module; or #import <Module/Header.h> or #include <Module/Header.h>
            pattern = #"@import\s+([A-Za-z_0-9]+)|#(?:import|include)\s+<([A-Za-z_0-9-]+)/"#
        }

        let regex = try NSRegularExpression(pattern: pattern, options: [])

        var imports = Set<String>()

        for line in codeWithoutComments.components(separatedBy: .newlines) {
            let range = NSRange(location: 0, length: line.utf16.count)
            let matches = regex.matches(in: line, options: [], range: range)

            for match in matches {
                if let moduleName = extractModuleName(from: match, line: line, language: language) {
                    imports.insert(moduleName)
                }
            }
        }

        return imports
    }

    /// Extracts imports from a file at the given path.
    ///
    /// - Parameter path: The file path to read and scan.
    /// - Returns: A set of imported module names, or nil if the file couldn't be read or language not detected.
    func extractImports(fromFileAt path: String) -> Set<String>? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension

        guard let language = SourceLanguage.from(extension: ext) else {
            return nil
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        return try? extractImports(from: content, language: language)
    }

    // MARK: - Private

    private func extractModuleName(from match: NSTextCheckingResult, line: String, language: SourceLanguage) -> String? {
        switch language {
        case .swift:
            // Group 1 contains the module name
            guard let moduleRange = Range(match.range(at: 1), in: line) else { return nil }
            let fullModule = String(line[moduleRange])
            // Handle submodules like ModuleA.Submodule - extract just the root module
            return fullModule.split(separator: ".").first.map(String.init)

        case .objc:
            // Try group 1 (@import Module)
            if let range = Range(match.range(at: 1), in: line), match.range(at: 1).location != NSNotFound {
                return String(line[range])
            }
            // Try group 2 (#import <Module/...)
            if let range = Range(match.range(at: 2), in: line), match.range(at: 2).location != NSNotFound {
                return String(line[range])
            }
            return nil
        }
    }

    private func removeComments(from code: String) throws -> String {
        // Remove both single-line (//) and multi-line (/* */) comments
        let regexPattern = #"//.*?$|/\*[\s\S]*?\*/"#
        let regex = try NSRegularExpression(pattern: regexPattern, options: [.anchorsMatchLines])
        let range = NSRange(location: 0, length: code.utf16.count)

        let result = regex.stringByReplacingMatches(in: code, options: [], range: range, withTemplate: "")
        // Remove empty lines that resulted from comment removal
        return result.replacingOccurrences(of: #"(?m)^\s*\n"#, with: "", options: .regularExpression)
    }
}

#endif // canImport(SQLite3)
