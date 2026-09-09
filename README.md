# AIWatching Capture

`AIWatching Capture` is a capture-only iPhone and Apple Watch foundation for intentional personal recordings. It records on either device, transfers Watch chunks through `WCSession`, stores a recoverable local session, and exports completed sessions to a user-selected folder through a security-scoped bookmark.

It deliberately stops there. This public repository contains no transcription, speaker identification, summarization, cloud credentials, recordings, browser artifacts, device registrations, or personal processing history.

## Data flow

```text
Watch capture -> chunked local audio -> WCSession transfer/retry -> iPhone staging --+
iPhone capture --------------------------------------------------------------+-> local session
                                                                            |
                                                                            v
                                                               SessionExport
                                                                            |
                                                                            v
                                                       user-selected destination
```

Each completed session has a `manifest.json`, an `audio/` directory of AAC chunks, and a `status.json`. The app owns a session until its status becomes `complete`; consumers can then process a copied session independently.

## Repository scope

- `Sources/`: iOS, watchOS, WidgetKit, shared capture, export, and transport code.
- `Tests/`: deterministic unit tests for capture state, chunking, transfer/import, and export behavior.
- `schema/`: public contracts for native iPhone/Watch capture sessions only.
- `project.yml`: XcodeGen project definition.

The original private product repository retains its own operational history and is intentionally not linked to this clean public source release.

## Build

Requirements: Xcode 26.6 or compatible Xcode 26 toolchain, XcodeGen, and an Apple development team selected locally for signing.

```bash
xcodegen generate
xcodebuild -project AIWatching.xcodeproj -scheme AIWatchingTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO test
```

The generated `.xcodeproj` and all local build products are ignored. To install on a physical iPhone or Apple Watch, set your own bundle identifiers and development team in `project.yml` or the generated project; do not commit those local signing choices.

## Privacy and consent

Recording laws and consent requirements vary by jurisdiction and situation. Use the app only for recordings you are authorized to make, provide notice where required, and protect the exported audio yourself. The app is designed for deliberate user-initiated capture, not covert or continuous surveillance.

## Status

This is source code for a capture foundation, not a hosted service or a promise of App Store availability. Unit tests validate deterministic logic; physical-device behavior, Watch connectivity, permissions, background execution, and export-folder behavior must be validated in each developer's own environment.

## License

[MIT](LICENSE)
