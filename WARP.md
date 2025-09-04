# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

Repo scope
- This directory contains the macOS SwiftUI app “WonderWhisper Mac” (Xcode project: "WonderWhisper Mac.xcodeproj").
- There is also an Android documentation subfolder at DictationKeyboardAI/ (docs only; no Android code here).

Common commands (run from this directory)
- Open in Xcode
  - open "WonderWhisper Mac.xcodeproj"
- Build (Debug)
  - xcodebuild build -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug -destination 'platform=macOS'
- Build (Release)
  - xcodebuild build -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Release -destination 'platform=macOS'
- Clean
  - xcodebuild clean -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac"
- Run all unit/UI tests
  - xcodebuild test -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS'
- Run a single test (examples)
  - Swift Testing (unit):
    - xcodebuild test -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' -only-testing:"WonderWhisper MacTests/WonderWhisper_MacTests/example"
  - XCTest (UI):
    - xcodebuild test -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' -only-testing:"WonderWhisper MacUITests/WonderWhisper_MacUITests/testExample"
- Code coverage (optional)
  - xcodebuild test -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' -enableCodeCoverage YES
- Lint
  - No linter is configured in this repository (no SwiftLint/SwiftFormat configs detected).

Mac app architecture (high level)
- Single macOS app target: "WonderWhisper Mac" with two test bundles: unit tests (WonderWhisper MacTests) and UI tests (WonderWhisper MacUITests).
- SwiftUI lifecycle with @main entry in WonderWhisper_MacApp.swift; initial scene hosts ContentView().
- ContentView.swift currently contains placeholder UI (Image + “Hello, world!” text); no external dependencies.
- Assets under WonderWhisper Mac/Assets.xcassets.
- Entitlements (WonderWhisper_Mac.entitlements): App Sandbox enabled, with com.apple.security.files.user-selected.read-only.
- Build settings (from project): macOS deployment target 15.5; Swift 5; product bundle identifier com.slumdev88.wonderwhisper.WonderWhisper-Mac; Development Team 44WC3UNX99.
- Tests:
  - Unit tests use the Swift “Testing” module (@Test attribute) in WonderWhisper_MacTests.swift.
  - UI tests use XCTest in WonderWhisper_MacUITests.swift and WonderWhisper_MacUITestsLaunchTests.swift.

Related docs in this repo
- Android project documentation lives at DictationKeyboardAI/CLAUDE.md. If you are working on that Android app (not part of this macOS target), consult that file directly; do not duplicate its content here.

