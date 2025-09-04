# Repository Guidelines

## Project Structure & Module Organization
- App: `WonderWhisper Mac/` — Swift/SwiftUI sources, `Resources/Assets.xcassets`, `Info.plist`, `*.entitlements`.
- Tests: `WonderWhisper MacTests/` (unit) and `WonderWhisper MacUITests/` (UI/flows).
- Project: `WonderWhisper Mac.xcodeproj` or `WonderWhisper Mac.xcworkspace` (if using SPM/CocoaPods).
- Scripts: `Scripts/` for maintenance tasks (formatting, lint, release).

## Build, Test, and Development Commands
- Open in Xcode: `open "WonderWhisper Mac.xcodeproj"` (or `.xcworkspace`).
- Build (Debug):
  `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -configuration Debug build`
  Use `-workspace` instead of `-project` if a workspace exists.
- Test (macOS):
  `xcodebuild -project "WonderWhisper Mac.xcodeproj" -scheme "WonderWhisper Mac" -destination 'platform=macOS' test`
- Run locally: use Xcode ▶︎, or `open build/Debug/WonderWhisper Mac.app` (path may vary).

## Coding Style & Naming Conventions
- Swift: 2‑space indent; 100‑char line limit; types `PascalCase`; methods/vars `camelCase`; constants `static let`.
- Files: one primary type per file; filename matches type (e.g., `AudioTranscriber.swift`).
- UI: prefer SwiftUI with preview providers; keep views small and composable.
- Formatting/Lint: If configured, run `swiftformat .` and `swiftlint` before committing.

## Testing Guidelines
- Framework: XCTest with clear assertions (`XCTAssert*`) and async tests where applicable.
- Naming: `test_<UnitUnderTest>_<Behavior>()` (e.g., `test_AudioService_handlesPermissionDenied`).
- Scope: prioritize pure logic and critical flows; include UI tests for key journeys.
- Coverage: aim ≥80% for core modules; ensure new code includes tests.

## Commit & Pull Request Guidelines
- Commits: small, focused, imperative subject line. Example: `fix: prevent crash when mic permission denied`.
- PRs: link issues; describe scope, approach, and risks; include screenshots/GIFs for UI; list test coverage and manual steps.
- Checks: ensure build, tests, and lint pass locally before requesting review.

## Security & Configuration Tips
- Never commit secrets; prefer `*.xcconfig` and load credentials via Keychain at runtime.
- Review `Signing & Capabilities` and entitlements (`*.entitlements`) for least privilege.
- Enable Hardened Runtime and avoid private APIs; audit third‑party dependencies periodically.

