# Argus

> [!IMPORTANT]
> This is an experiment. We don't plan to maintain it long-term, but the learnings will feed back into Tuist, where we'll collect and expose build data in a structured, convenient format.

> [!WARNING]
> Argus is a fork of [swift-build](https://github.com/swiftlang/swift-build) that provides an agentic interface for AI agents to help you understand and optimize your Xcode builds. Since it relies on internal Xcode protocols, it may not work with all Xcode versions.

Learn more about the motivation and technical details in our blog post: [Teaching AI to Read Xcode Builds](https://tuist.dev/blog/2025/11/27/teaching-ai-to-read-xcode-builds)

## Installation

Install Argus globally using [mise](https://mise.jdx.dev/):

```bash
mise use -g github:tuist/argus
```

> **Note:** Use the `github:` backend (not `ubi:`) to ensure all required resource bundles are extracted.

## Usage with AI Agents

Add the following to your agent's memory or system prompt to enable build observability:

```
When running Xcode builds, use Argus to capture and analyze build data:

1. Run builds with Argus and a session ID for correlation:
   SWB_BUILD_TRACE_ID=$(uuidgen)
   XCBBUILDSERVICE_PATH=$(which argus) SWB_BUILD_TRACE_ID=$SWB_BUILD_TRACE_ID xcodebuild build -scheme MyScheme

2. Query build results using the session ID:
   argus trace summary --build $SWB_BUILD_TRACE_ID
   argus trace errors --build $SWB_BUILD_TRACE_ID
   argus trace slowest-targets --build $SWB_BUILD_TRACE_ID --limit 5
   argus trace bottlenecks --build $SWB_BUILD_TRACE_ID

   Or use "latest" to query the most recent build:
   argus trace summary --build latest

3. Analyze dependency health:
   argus trace implicit-deps --build latest    # Find missing dependencies
   argus trace redundant-deps --build latest   # Find unused dependencies

4. Use --json flag for programmatic access:
   argus trace summary --build $SWB_BUILD_TRACE_ID --json

5. Run `argus trace --help` to discover all available commands.
```

## Project Correlation

To group builds by project or workspace, set additional environment variables:

```bash
# Group builds by a custom project identifier
XCBBUILDSERVICE_PATH=$(which argus) \
  SWB_BUILD_PROJECT_ID=my-app \
  SWB_BUILD_WORKSPACE_PATH=$(pwd) \
  xcodebuild build -scheme MyScheme

# List all projects with build history
argus trace projects

# View builds for a specific project
argus trace builds --project my-app --limit 10

# View builds for a specific workspace path
argus trace builds --workspace /path/to/project --limit 10
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `SWB_BUILD_TRACE_ID` | Custom build identifier for external correlation |
| `SWB_BUILD_PROJECT_ID` | Project identifier for grouping related builds |
| `SWB_BUILD_WORKSPACE_PATH` | Workspace path for grouping builds by workspace |
| `SWB_BUILD_TRACE_PATH` | Override the default database path |
| `SWB_BUILD_TRACE_ENABLED` | Set to `0` to disable recording |

## Implicit Dependency Detection

Argus can analyze your builds to detect implicit dependencies (modules imported but not declared as dependencies) and redundant dependencies (declared but never imported):

```bash
# Find implicit dependencies - modules imported without being declared
argus trace implicit-deps --build latest

# Find redundant dependencies - declared but never imported
argus trace redundant-deps --build latest

# Use JSON output for programmatic access
argus trace implicit-deps --build latest --json
```

### Example Output

```
Implicit Dependencies Found (3)

These modules are imported but not declared as dependencies:

| Target      | Imports     | Files Affected |
|-------------|-------------|----------------|
| MyApp       | Analytics   | 5 files        |
| MyApp       | Networking  | 12 files       |
| MyFeature   | Utilities   | 3 files        |
```

This helps you:
- **Catch missing dependencies** that might cause build failures in clean builds
- **Remove unused dependencies** to reduce build times
- **Audit your dependency graph** for architectural issues

> **Note:** The detection works with both Xcode project dependencies and Swift Package dependencies declared in `Package.swift` manifests.

## Build Graph Analysis

Argus can query your build's dependency graph to understand target relationships and linking information. This is useful for AI agents to make optimization recommendations for binary size and startup time.

```bash
# Full dependency graph with all targets and their linking info
argus trace graph --build latest

# What does MyApp depend on? (transitive dependencies by default)
argus trace graph --source MyApp

# Only direct dependencies (not transitive)
argus trace graph --source MyApp --direct

# What depends on CoreKit? (reverse dependency lookup)
argus trace graph --sink CoreKit

# Find the dependency path between two targets
argus trace graph --source MyApp --sink CoreKit

# Filter by dependency type
argus trace graph --source MyApp --label package      # Swift packages only
argus trace graph --source MyApp --label framework    # Frameworks only
argus trace graph --source MyApp --label sdk          # System SDKs only

# Control output fields
argus trace graph --source MyApp --fields name,type,linking

# Output formats: json (default) or toon (token-efficient for LLMs)
argus trace graph --source MyApp --format toon
```

### Example Output

```json
{
  "source": "MyApp",
  "dependencies": [
    { "name": "NetworkingKit", "path": "...", "kind": "dynamic", "mode": "normal", "isSystem": false },
    { "name": "CoreUtilities", "path": "...", "kind": "static", "mode": "normal", "isSystem": false },
    { "name": "Foundation", "path": "...", "kind": "dynamic", "mode": "normal", "isSystem": true }
  ]
}
```

### Linking Modes

The graph shows how each dependency is linked:

| Kind | Description |
|------|-------------|
| `static` | Statically linked library |
| `dynamic` | Dynamically linked library |
| `framework` | Framework bundle |

| Mode | Description |
|------|-------------|
| `normal` | Standard linking |
| `weak` | Weak linking (optional at runtime) |
| `reexport` | Re-exported symbols |
| `merge` | Merged into the binary |

## License

See https://swift.org/LICENSE.txt for license information.
