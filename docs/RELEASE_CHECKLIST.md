# Release Checklist

**Maintainer:** Amirali Yazdani

## Before tagging a version

- [ ] Run `swift test` and `swift build -c release` on macOS.
- [ ] Run every program listed in the README's sample table and compare expected output.
- [ ] Open the app on the minimum supported macOS release when practical.
- [ ] Verify source editing, line-number scrolling, search, open/save, compile diagnostics, breakpoints, Step/Continue/Stop/Reset, process inspection, and the Activity view.
- [ ] Check light and dark appearance and resize the main window.
- [ ] Verify the app icon in the built app bundle, Finder, and Dock.
- [ ] Review supported-language notes and update `docs/COMPATIBILITY.md` if behavior changed.
- [ ] Review the staged diff for credentials, private files, build output, and unrelated changes.
- [ ] Update `CHANGELOG.md` and keep package version, app metadata, and DMG filename in sync.

## Before a public DMG release

- [ ] Sign the `.app` with a Developer ID Application identity.
- [ ] Enable the hardened runtime and verify the signature.
- [ ] Notarize and staple the app and DMG.
- [ ] Validate the stapled tickets and run Gatekeeper assessment.
- [ ] Install the downloaded DMG on a separate macOS user account or test Mac, with standard Gatekeeper settings.
- [ ] Generate and publish a SHA-256 checksum.
- [ ] Attach the DMG to a GitHub Release and include the macOS minimum version, release notes, and source link.

The CI workflow performs automated tests, sample smoke tests, a macOS application build, and creation of an unsigned development DMG. It does not sign or notarize releases.
