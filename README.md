# SwiftPad

A native client core for [CryptPad](https://cryptpad.org), written in Swift.

SwiftPad does not reimplement CryptPad's protocol. It embeds CryptPad's own worker bundle in [QuickJS-NG](https://github.com/quickjs-ng/quickjs) and drives it from Swift, so pads, drives, teams and messages are produced and consumed by the same code the official web client runs. 
The bundle is pinned and shipped with the client: the server never delivers executable code.

This repository will grow into a mono repo (core, Android app, iOS app).
Only the core is published for now.

## Contents

- `core/` - Swift package
  - `SwiftPadCore` - the library: session lifecycle, sign-in, drive, pads, teams, calendar, contacts, chat, caches
  - `SwiftPadNIOTransport` - SwiftNIO-based HTTP/WebSocket transport for platforms without URLSession (Android)
  - `swiftpad-cli` - a macOS command-line client over the library

## Build

Requires Swift 6.3 (see `.swift-version`).

```sh
git clone --recurse-submodules https://github.com/ciaens/SwiftPad
cd core
swift build
swift run swiftpad-cli
```

Running the CLI with no arguments prints the command list. See `CLI.md` for a guided tour of the commands.

## Status

Pre-release. The API is not stable and the Android and iOS apps are not published yet.
The CLI is just here to test the core module. Not tested on Windows / Linux.

The QuickJS engine is subject to change, due to poor results on Android.

## License

SwiftPad's own code is released under the MIT License (see `LICENSE`).

The embedded CryptPad worker bundle and its configuration file are CryptPad code, licensed under AGPL-3.0-or-later. Distributing a build that includes them is subject to the AGPL.
See `THIRD_PARTY_NOTICES` for the full list of bundled third-party components.

SwiftPad is an independent project and is not affiliated with or endorsed by XWiki SAS or the CryptPad team.
