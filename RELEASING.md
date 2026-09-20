# Building and releasing Stacks

This document describes how to build Stacks and distribute the macOS app
directly to users as a signed and notarised DMG. This is a Developer ID
distribution workflow, not a Mac App Store workflow.

The automated release entry point is:

```bash
./Scripts/release.sh
```

The script requires Xcode 27 and creates the final artifact in `dist/`.

## Requirements

- macOS 26 or later.
- Xcode 27 selected in Xcode or with `DEVELOPER_DIR`.
- XcodeGen, if `project.yml` has changed and the Xcode project needs to be
  regenerated.
- An Apple Developer account with a **Developer ID Application** certificate
  and its private key installed in the login keychain.
- Credentials for Apple notarisation, stored either in a local `notarytool`
  keychain profile or supplied as an App Store Connect Team API key.

Check the local toolchain and signing identity before releasing:

```bash
xcodebuild -version
xcode-select -p
security find-identity -p codesigning -v
```

The identity list must contain a valid identity beginning with:

```text
Developer ID Application:
```

Apple's guidance for creating distribution-signed Mac code is available in
[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).

## Normal development build

Regenerate the Xcode project only when `project.yml` changes:

```bash
xcodegen generate
```

Build the app:

```bash
xcodebuild \
  -project Stacks.xcodeproj \
  -scheme Stacks \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Run the test suite when appropriate:

```bash
xcodebuild \
  -project Stacks.xcodeproj \
  -scheme Stacks \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

## Archive layout

The build is split across a Swift package and a few XcodeGen targets:

| Target | Kind | Defined in |
|---|---|---|
| `StacksKit` / `StacksSync` / `StacksServerKit` | package libraries | `Package.swift` (shared with the Linux build) |
| `StacksServer` | tool | `project.yml`, plus a package executable product |
| `StacksDevices` | macOS framework | `project.yml` — MTP over IOUSBHost, macOS-only |
| `Stacks` / `StacksIOS` | apps | `project.yml` |

`StacksUI` is a shared **source directory**, not a target: it is compiled into
both app targets, so the shared views need no `public` access annotations.

The `Stacks` scheme builds the app, the `StacksDevices` framework, and the
`StacksServer` helper. Only the app belongs in the distributable app archive:

- `StacksDevices` is embedded in the app.
- `StacksServer` has `SKIP_INSTALL=YES` because it is a separate helper tool,
  not part of the DMG.

Do not remove these settings. If an archive contains both `Stacks.app` and
`StacksServer`, Xcode treats it as a multi-product content archive and rejects
the Developer ID export method. If the server is distributed separately in
the future, build, sign, and package it as its own artifact.

## Configure local notarisation credentials

### Keychain profile

The simplest local setup is a `notarytool` keychain profile. Apple supports
either an app-specific password or an App Store Connect API key. The command
prompts for values that are not supplied:

```bash
xcrun notarytool store-credentials "StacksNotary" \
  --apple-id "your-apple-account@example.com" \
  --team-id "N7J3BYZ94H"
```

Do not put a real password in a committed file or shell script. The profile
is stored in Keychain, not in this repository.

For an API-key profile, use a Team API key and keep the `.p8` file private:

```bash
xcrun notarytool store-credentials "StacksNotary" \
  --key "/private/path/AuthKey_KEYID.p8" \
  --key-id "KEYID" \
  --issuer "ISSUER_UUID"
```

Apple's documentation notes that individual App Store Connect API keys cannot
use `notaryTool`; use a Team API key for this workflow. See [Creating API keys
for App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api).

## Release workflow

### 1. Optional dry run

This checks the script's configuration without building, signing, or contacting
Apple:

```bash
./Scripts/release.sh --dry-run
```

### 2. Build and sign without notarising

Use this to validate the archive, export, DMG creation, and code signatures:

```bash
./Scripts/release.sh --skip-notarization
```

This produces a DMG but does not make it ready for public distribution.

### 3. Build, sign, notarise, and staple

For a public release, run:

```bash
NOTARYTOOL_PROFILE=StacksNotary ./Scripts/release.sh
```

The script performs these steps:

1. Archives the `Stacks` scheme with Xcode 27.
2. Exports the app using the `developer-id` distribution method.
3. Verifies the exported app signature.
4. Creates a compressed read-only DMG containing `Stacks.app` and an
   `/Applications` shortcut.
5. Signs the DMG with the Developer ID Application identity.
6. Submits the exact DMG to Apple's notary service using `notarytool`.
7. Staples the notarisation ticket to the DMG.
8. Validates the stapled ticket, DMG, app signature, and Gatekeeper assessment.

The final artifact is normally named:

```text
dist/Stacks-VERSION.dmg
```

The version is read from the exported app's `CFBundleShortVersionString`.
Temporary archives and export files are kept under `dist/.release/` for
diagnostics.

## Using an API key directly

For CI or a local shell that does not use a keychain profile, provide the
private key through environment variables:

```bash
APPLE_API_KEY_ID="KEYID" \
APPLE_API_ISSUER_ID="ISSUER_UUID" \
APPLE_API_KEY_PATH="/private/path/AuthKey_KEYID.p8" \
  ./Scripts/release.sh
```

In CI, `APPLE_API_PRIVATE_KEY` can contain the `.p8` file contents instead of
using `APPLE_API_KEY_PATH`. Never commit either form of the private key.

## GitHub Actions

The release script is intentionally independent of GitHub Actions. A workflow
can call the same script on a macOS runner after importing the Developer ID
certificate into a temporary keychain.

Use protected GitHub environment secrets for:

- `DEVELOPER_ID_CERTIFICATE_BASE64` — base64-encoded `.p12` certificate and
  private key.
- `DEVELOPER_ID_CERTIFICATE_PASSWORD` — password for the `.p12` file.
- `APPLE_API_KEY_ID` — App Store Connect Team API key ID.
- `APPLE_API_ISSUER_ID` — App Store Connect issuer ID.
- `APPLE_API_PRIVATE_KEY` — contents of the `.p8` private key.

A minimal release job has this shape:

```yaml
name: Release

on:
  push:
    tags: ["v*"]
  workflow_dispatch:

jobs:
  release:
    runs-on: xcode-27
    environment: release
    permissions:
      contents: write

    steps:
      - uses: actions/checkout@v6

      - uses: apple-actions/import-codesign-certs@v7
        with:
          p12-file-base64: ${{ secrets.DEVELOPER_ID_CERTIFICATE_BASE64 }}
          p12-password: ${{ secrets.DEVELOPER_ID_CERTIFICATE_PASSWORD }}

      - name: Build, sign, and notarise
        env:
          APPLE_API_KEY_ID: ${{ secrets.APPLE_API_KEY_ID }}
          APPLE_API_ISSUER_ID: ${{ secrets.APPLE_API_ISSUER_ID }}
          APPLE_API_PRIVATE_KEY: ${{ secrets.APPLE_API_PRIVATE_KEY }}
        run: ./Scripts/release.sh

      - name: Publish DMG
        run: gh release create "$GITHUB_REF_NAME" dist/*.dmg --generate-notes
        env:
          GH_TOKEN: ${{ github.token }}
```

Protect the `release` environment with required reviewers before allowing the
workflow to access signing and notarisation secrets. GitHub's guidance for
signing Xcode applications is [Installing an Apple certificate on macOS
runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Validation commands

After a full release, these commands should succeed:

```bash
codesign --verify --deep --strict --verbose=2 \
  dist/.release/export/Stacks.app

codesign --verify --verbose=2 \
  dist/Stacks-VERSION.dmg

xcrun stapler validate dist/Stacks-VERSION.dmg
hdiutil verify dist/Stacks-VERSION.dmg
spctl -a -vv --type open dist/Stacks-VERSION.dmg
spctl -a -vv --type execute dist/.release/export/Stacks.app
```

Replace `VERSION` with the actual version in `dist/`.

If notarisation fails, use the submission ID printed by `notarytool` to fetch
the detailed Apple log:

```bash
xcrun notarytool log SUBMISSION_ID \
  --keychain-profile StacksNotary
```

Apple's [custom notarisation workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
documents submission, status, logs, and stapling.

## Troubleshooting

### `no Developer ID Application identity found`

The certificate or its private key is not available to the current keychain.
Install the `.cer` certificate, import the matching private key, and confirm
with:

```bash
security find-identity -p codesigning -v
```

### `conflicting provisioning settings`

Do not pass a Developer ID identity as a global `xcodebuild archive` setting.
The app and Swift package targets use automatic signing during the archive;
the release script selects Developer ID during export and signs the DMG
explicitly.

### `method ... developer-id` is rejected

Inspect the archive contents:

```bash
find dist/.release/Stacks.xcarchive/Products -maxdepth 5 -print
```

There should be one top-level application product: `Stacks.app`. If
`StacksServer` appears under `Products/usr/local/bin`, regenerate the project
or confirm that its target has `SKIP_INSTALL=YES`, then rerun the archive.

### Notarisation succeeds but Gatekeeper rejects the app

Confirm that the final DMG—not an earlier archive or ZIP—was submitted and
stapled. Re-run `xcrun stapler validate`, `hdiutil verify`, and both `spctl`
commands above. Also inspect any nested code and entitlements with:

```bash
codesign -d --entitlements :- --verbose=4 \
  dist/.release/export/Stacks.app
```

## Release checklist

- [ ] Xcode 27 is selected.
- [ ] `security find-identity -p codesigning -v` shows Developer ID Application.
- [ ] The app version and build number are correct.
- [ ] `StacksServer` is excluded from the app archive.
- [ ] `./Scripts/release.sh --skip-notarization` completes successfully.
- [ ] The final run completes without `--skip-notarization`.
- [ ] The DMG is stapled and passes `spctl`, `codesign`, and `hdiutil verify`.
- [ ] Only the final DMG is uploaded or published.
- [ ] No certificates, private keys, passwords, archives, or DMGs are committed.
