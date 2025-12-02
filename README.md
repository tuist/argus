# Argus

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
   BUILD_TRACE_ID=$(uuidgen)
   XCBBUILDSERVICE_PATH=$(which argus) BUILD_TRACE_ID=$BUILD_TRACE_ID xcodebuild build -scheme MyScheme

2. Query build results using the session ID:
   argus trace summary --build $BUILD_TRACE_ID
   argus trace errors --build $BUILD_TRACE_ID
   argus trace slowest-targets --build $BUILD_TRACE_ID --limit 5
   argus trace bottlenecks --build $BUILD_TRACE_ID

   Or use "latest" to query the most recent build:
   argus trace summary --build latest

3. Use --json flag for programmatic access:
   argus trace summary --build $BUILD_TRACE_ID --json

4. Run `argus trace --help` to discover all available commands.
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

## License

See https://swift.org/LICENSE.txt for license information.
