# Repository Guidelines

## Project Structure & Module Organization

This is a Theos-based iOS tweak for YouTube Music. Core tweak hooks live in `Source/*.x` and `Source/*.xm`; Objective-C support code lives in `Source/*.m` and `Source/*.h`. YouTube Music runtime interface declarations are under `Source/Headers/`. Preferences UI code is in `Source/Prefs/`, bundled assets and localizations are in `layout/Library/Application Support/YTMusicUltimate.bundle/`, and repo presentation assets are in `Resources/`. Build and release automation lives in `.github/workflows/main.yml`; local packaging helpers are in `scripts/`.

Avoid committing generated IPA files or temporary downloaded app payloads. Treat existing `.ipa` files as local artifacts unless a maintainer explicitly asks otherwise.

## Build, Test, and Development Commands

- `make clean package` builds a rootful `.deb` using Theos.
- `make clean package ROOTLESS=1` builds a rootless package.
- `make clean package SIDELOADING=1` includes `Source/Sideloading.x` for IPA injection workflows.
- `python3 scripts/regression_checks.py` runs the local parser/regression checks.
- `python3 scripts/regression_checks.py --ipa YTMusicUltimate-YYYYMMDD-HHMMSS.ipa` also verifies ATS settings inside a built IPA.

Before building, ensure `THEOS` points to a valid Theos checkout and the iPhoneOS 16.5 SDK is available, matching the workflow setup.

## Coding Style & Naming Conventions

Match the existing Objective-C/Logos style: 4-space indentation, braces on method/function lines, `YTMU` prefixes for project-specific helpers, and descriptive hook filenames such as `Downloading.x` or `PlaybackRate.x`. Keep hooks small and feature-scoped. Prefer UIKit/Foundation native APIs already used in the project. Do not restyle unrelated code while fixing behavior.

## Testing Guidelines

There is no broad unit-test suite. Use `scripts/regression_checks.py` for repository-level checks and add focused checks there when behavior can be validated without a device. For tweak behavior, verify with a Theos package build and, when relevant, an injected IPA plus `--ipa` regression verification. Name new checks after the behavior they protect, not the implementation detail.

## Commit & Pull Request Guidelines

Recent history uses short, direct commit subjects such as `improve german translation`, `bump`, and `cairo-style downloads icon #419`; keep subjects concise and mention issue numbers when useful. Pull requests should describe the user-visible change, list tested commands, call out device or sideloading coverage, and include screenshots for UI/preferences changes. Keep generated packages and unrelated local artifacts out of PRs.
