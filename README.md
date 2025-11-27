# Argus

> [!WARNING]
> Argus is a fork of [swift-build](https://github.com/swiftlang/swift-build) that provides an agentic interface for AI agents to help you understand and optimize your Xcode builds. Since it relies on internal Xcode protocols, it may not work with all Xcode versions.

Learn more about the motivation and technical details in our blog post: [Teaching AI to Read Xcode Builds](https://tuist.dev/blog/2025/11/27/teaching-ai-to-read-xcode-builds)

## Installation

Install Argus globally using [mise](https://mise.jdx.dev/):

```bash
mise use -g ubi:tuist/argus
```

## Usage with AI Agents

Add the following to your agent's memory or system prompt to enable build observability:

```
When running Xcode builds, use Argus to capture and analyze build data:

1. Run builds with Argus:
   XCBBUILDSERVICE_PATH=$(which argus) xcodebuild build -scheme MyScheme

2. Query build results:
   argus trace summary --build latest
   argus trace errors --build latest
   argus trace slowest-targets --build latest --limit 5
   argus trace bottlenecks --build latest

3. Use --json flag for programmatic access:
   argus trace summary --build latest --json

4. Run `argus trace --help` to discover all available commands.
```

## License

See https://swift.org/LICENSE.txt for license information.
