# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.4] - 2025-11-27
### Details
#### <!-- 1 -->🐛 Bug Fixes
- Use SwiftyLab/setup-swift for development snapshots by @pepicrft

## [0.1.3] - 2025-11-27
### Details
#### <!-- 1 -->🐛 Bug Fixes
- Use Swift nightly toolchain for builds by @pepicrft in [#6](https://github.com/tuist/argus/pull/6)

## [0.1.2] - 2025-11-27
### Details
#### <!-- 1 -->🐛 Bug Fixes
- Use Swift 5 language mode to avoid concurrency errors by @pepicrft in [#5](https://github.com/tuist/argus/pull/5)

## [0.1.1] - 2025-11-27
### Details
#### <!-- 1 -->🐛 Bug Fixes
- Use Xcode 16.1 and macos-15 runners for release builds by @pepicrft in [#4](https://github.com/tuist/argus/pull/4)

## [0.1.0] - 2025-11-27
### Details
#### <!-- 0 -->🚀 Features
- Add build trace recording to SQLite for observability by @pepicrft in [#3](https://github.com/tuist/argus/pull/3)

#### <!-- 1 -->🐛 Bug Fixes
- Multiple properties in the SWBCore functions by @MojtabaHs
- `buildFilesContext.belongsToPreferredArch` anywhere in the package by @MojtabaHs
- A typo in `dependencyDataFormat` by @MojtabaHs
- A typo in `_OBSOLETE_MANUAL_BUILD_ORDER` everywhere by @MojtabaHs
- A typo in the warning explanation by @MojtabaHs

#### <!-- 10 -->💼 Other
- //164182636 Pass back PRODUCT_MODULE_NAME to previews as target dependency info by @jonathanpenn
- Resolve miscellaneous Swift 6 adoption issues by @owenv
- Vend counters as strings to avoid making SWBProtocol part of the public interface for SwiftBuild by @mirza-garibovic
- Remove mirza-garibovic by @mirza-garibovic
- Fix deduplication issue when parsing dependency trace v1 by @sina-mahdavi
- Handle empty dependency trace file in parsing by @sina-mahdavi
- Use better Regex/JSON decoding for parsing dependency trace files by @sina-mahdavi
- Support clang modules when parsing dependency validation info by @sina-mahdavi
- Fire metrics (rdar://150307704) + add unused header validation (rdar://159126160) by @mirza-garibovic
- Define metrics by @mirza-garibovic
- Generalize counters, ensure task counters are propagated to clients observing messages by @mirza-garibovic
- Add blocklist for builtin module verifier by @cyndyishida
- Add blocklist for builtin module verifier by @cyndyishida
- Propagate actual xcconfig final line/column number to fixits instead of using .max (rdar://159783939) by @mirza-garibovic
- Track xcconfig file end line/column numbers during parsing/loading by @mirza-garibovic
- Annotate clang trace decoding errors with file paths by @mirza-garibovic
- Handle empty clang trace by @mirza-garibovic
- Refactor Clang task action dependencies handling to share code between modular and non-modular compiles by @mirza-garibovic
- Support optional module dependencies by @mirza-garibovic
- Validate unused module dependencies by @mirza-garibovic
- Add OpenBSD support by @jakepetroules
- Add "Migrate" mode to some 6.2 language features by @AnthonyLatsis
- Enable additional Linux distributions by @jakepetroules
- Make xcconfig fix-its multi-line by @mirza-garibovic
- Emit warning instead of error if the Swift toolchain can't support VALIDATE_MODULE_DEPENDENCIES to match clang by @mirza-garibovic
- Include moduleDependenciesContext in the Swift compilation requirements signature by @mirza-garibovic
- Revert change to avoid dead code striping with debug dylib (rdar://154656898) by @jonathanpenn
- Validate Swift imports against MODULE_DEPENDENCIES and provide fix-its (rdar://150314567) by @mirza-garibovic
- Fix an issue where locations from xcconfig files are lost across condition binding by @mirza-garibovic
- //158239745 (Running `swift test` in `swift-build` crashes with Wonder XIP) by @owenv
- Add "Migrate" mode to some 6.2 language features by @AnthonyLatsis
- Extract Extension Point Definition and Extension's target extension point identifier from swift const values
- Add LM_ENABLE_APP_NAME_OVERRIDE option to AppIntentsMetadata spec
- //137934414 (Add register app groups build setting for group prefixed groups, when capability is enabled) by @baujla
- //142845111 (Turn on `AppSandboxConflictingValuesEmitsWarning` by default)
- Log a deprecated API warning for use of the UIRequiresFullScreen info.plist key when linked on or after v26 releases by @jakepetroules
- Attempt to bundle files for the modules by @compnerd
- Fix unused variable warning by @owenv
- Add missing imports required by MemberImportVisibility by @jakepetroules
- Add missing imports required by MemberImportVisibility by @jakepetroules
- Update dependencies path to use the `swiftlang` instead of `apple` by @MojtabaHs
- Initial support for building with CMake by @compnerd
- //144577495 Install name mapping not specifying the correct platform number by @jonathanpenn
- Narrow some imports by @compnerd
- Broaden scope of withExpressionInterningEnabled and keepAliveSettingsCache to include resolver inits, since those construct Settings too by @mirza-garibovic
- Insert a few more eager cancellation checks (rdar://142898873) by @mirza-garibovic
- Remove `@retroactive` by @compnerd
- Avoid some won't be executed warnings by @compnerd
- Avoid some deprecated Swift methods by @compnerd
- Update the dependencies for the plugins by @compnerd
- Repair the build on Windows by @compnerd
- Simplify some expectations (NFCI) by @compnerd
- //143411533 (Object files and module wrap output end up in the same location, stomping on each other) by @neonichu
- Silence C++17 deprecation warnings by @compnerd
- Make the module build on Windows by @compnerd
- Make the module build on Windows by @compnerd

#### <!-- 2 -->🚜 Refactor
- Fix static metadata `dependency` file list files by @MojtabaHs
- Fix job key `Indices` by @MojtabaHs

#### <!-- 3 -->📚 Documentation
- Fix all remaining comment typos in the source directory by @MojtabaHs
- Fix spelling errors in `SWBUniversalPlatform` documentation by @MojtabaHs
- Fix inline documentations of SBWCore by @MojtabaHs
- Fix a bunch of typos in SWBCore specs by @MojtabaHs
- Fix a typo in `connections` by @MojtabaHs
- Fix a typo in `artificial` by @MojtabaHs
- Fix a typo in `necessarily` by @MojtabaHs
- Fix a typo of `Represents` word by @MojtabaHs
- Fix a typo of `hierarchy` word by @MojtabaHs
- Fix `originally` spelling by @MojtabaHs
- Fix `programmatic` spelling by @MojtabaHs
- Fix `profile` spelling by @MojtabaHs
- Fix `substitution` spelling by @MojtabaHs
- Fix `evaluated` spelling by @MojtabaHs
- Fix `accommodate` spelling by @MojtabaHs
- Fix `accommodation` spelling by @MojtabaHs
- Fix `Append` spelling by @MojtabaHs
- Fix `evaluates` spelling by @MojtabaHs
- Fix `encompasses` spelling by @MojtabaHs
- Fix `condition` spelling by @MojtabaHs
- Fix `assignments` spelling by @MojtabaHs
- Fix a typo of `validate` word by @MojtabaHs
- Fix a typo of `occurrences` word by @MojtabaHs
- Fix `scanning` spelling by @MojtabaHs
- Fix `the` spelling by @MojtabaHs
- Fix `embedded` spelling by @MojtabaHs
- Fix `dependency` spelling by @MojtabaHs
- Fix `build` spelling by @MojtabaHs
- Fix `schedule` spelling by @MojtabaHs
- Fix `overridden` spelling by @MojtabaHs
- Fix a typo of `associating` word by @MojtabaHs
- Fix a typo of `should` word by @MojtabaHs
- Enhance SWBCore inline documentations of the project model by @MojtabaHs
- Enhance SWBBuildService inline documentations by @MojtabaHs
- Fix spelling of `support` by @MojtabaHs
- Fix spelling of `architecture` by @MojtabaHs
- Fix spelling of `underlying` by @MojtabaHs
- Enhance SWBApplePlatform inline documentations by @MojtabaHs

#### <!-- 7 -->⚙️ Miscellaneous Tasks
- Restrict GitHub workflow permissions by @incertum
- Remove unused field by @MojtabaHs

## New Contributors
* @pepicrft made their first contribution
* @neonichu made their first contribution
* @jakepetroules made their first contribution
* @bkhouri made their first contribution
* @owenv made their first contribution
* @mhrawdon made their first contribution
* @ahoppen made their first contribution
* @vsapsai made their first contribution
* @rconnell9 made their first contribution
* @jonathanpenn made their first contribution
* @kcieplak made their first contribution
* @Catfish-Man made their first contribution
* @cachemeifyoucan made their first contribution
* @daveinglis made their first contribution
* @matthewseaman made their first contribution
* @incertum made their first contribution
* @cyndyishida made their first contribution
* @Steelskin made their first contribution
* @xedin made their first contribution
* @egorzhdan made their first contribution
* @danliew-apple made their first contribution
* @DougGregor made their first contribution
* @mirza-garibovic made their first contribution
* @hamishknight made their first contribution
* @bob-wilson made their first contribution
* @cmcgee1024 made their first contribution
* @sina-mahdavi made their first contribution
* @shahmishal made their first contribution
* @brooke-callahan made their first contribution
* @plemarquand made their first contribution
* @bnbarham made their first contribution
* @AnthonyLatsis made their first contribution
* @jPaolantonio made their first contribution
* @tshortli made their first contribution
* @rauhul made their first contribution
* @baujla made their first contribution
* @devincoughlin made their first contribution
* @ made their first contribution
* @ian-twilightcoder made their first contribution
* @stephenverderame made their first contribution
* @xymus made their first contribution
* @jansvoboda11 made their first contribution
* @stmontgomery made their first contribution
* @artemcm made their first contribution
* @susmonteiro made their first contribution
* @cwakamo made their first contribution
* @ldaley made their first contribution
* @akyrtzi made their first contribution
* @compnerd made their first contribution
* @benlangmuir made their first contribution
* @usama54321 made their first contribution
* @aciidgh made their first contribution
* @thetruestblue made their first contribution
* @pmattos made their first contribution
* @swiftlysingh made their first contribution
* @3405691582 made their first contribution
* @MojtabaHs made their first contribution
* @saagarjha made their first contribution
* @ekeege made their first contribution
* @Rajveer100 made their first contribution
* @shawnhyam made their first contribution
* @kateinoigakukun made their first contribution
* @heckj made their first contribution
* @swift-ci made their first contribution
[0.1.4]: https://github.com/tuist/argus/compare/0.1.3..0.1.4
[0.1.3]: https://github.com/tuist/argus/compare/0.1.2..0.1.3
[0.1.2]: https://github.com/tuist/argus/compare/0.1.1..0.1.2
[0.1.1]: https://github.com/tuist/argus/compare/0.1.0..0.1.1

<!-- generated by git-cliff -->
