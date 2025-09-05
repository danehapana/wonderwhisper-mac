# Repository Guidelines

This guide helps contributors work effectively on WonderWhisper Mac. Keep changes focused, tested, and consistent with the patterns below.

## Project Structure & Module Organization
- App: `WonderWhisper Mac/` — Swift/SwiftUI sources, `Resources/Assets.xcassets`, `Info.plist`, `*.entitlements`.
- Tests: `WonderWhisper MacTests/` (unit) and `WonderWhisper MacUITests/` (UI/flows).
- Project: `WonderWhisper Mac.xcodeproj` (or `.xcworkspace` if using SPM/CocoaPods).
- Scripts: `Scripts/` for maintenance tasks (format, lint, release).

## Build, Test, and Development Commands
- Open in Xcode: `open "WonderWhisper Mac.xcodeproj"` (use `.xcworkspace` if present).
- Build (Debug):
  `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug build`
- Test (macOS):
  `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' test`
- Run locally: use Xcode ▶︎, or `open build/Debug/WonderWhisper\ Mac.app` (path may vary).

## Coding Style & Naming Conventions
- Swift: 2‑space indent; ~100‑char line limit.
- Names: types `PascalCase`; methods/vars `camelCase`; constants `static let`.
- Files: one primary type per file; filename matches type (e.g., `AudioTranscriber.swift`).
- UI: prefer SwiftUI with small, composable views and preview providers.
- Formatting/Lint: if configured, run `swiftformat .` and `swiftlint` before committing.

## Testing Guidelines
- Framework: XCTest for unit and UI tests; use async tests where applicable.
- Naming: `test_<UnitUnderTest>_<Behavior>()` (e.g., `test_AudioService_handlesPermissionDenied`).
- Scope: prioritize pure logic and critical flows; add UI tests for key journeys.
- Coverage: aim ≥80% for core modules.
- Run: use the Test command above or Xcode’s Test action.

## Commit & Pull Request Guidelines
- Commits: small, focused, imperative subjects (e.g., `fix: prevent crash when mic permission denied`).
- PRs: link issues; describe scope, approach, and risks; include screenshots/GIFs for UI changes.
- Checks: ensure build, tests, and lint pass locally before requesting review.

## Security & Configuration Tips
- Never commit secrets; prefer `*.xcconfig` and use Keychain at runtime.
- Review `Signing & Capabilities` and `*.entitlements` for least privilege; enable Hardened Runtime.
- Avoid private APIs; audit third‑party dependencies periodically.

