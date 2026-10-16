# Building and distributing Multi-Pascal Mac

**Maintainer:** Amirali Yazdani

Multi-Pascal Mac is a normal macOS application and does **not** have to be published in the Mac App Store. You can distribute it from your own website, GitHub Releases, or another download page. For a smooth public-download experience, sign the application with a **Developer ID Application** certificate and notarize it with Apple. This is separate from App Store review.

## 1. Build a local app and DMG

On a Mac with Xcode command-line tools installed, extract the project and run these commands from its root:

```sh
chmod +x BuildMacApp.command PackageDMG.command
./PackageDMG.command
```

This builds `Multi-Pascal Mac.app`, generates `AppIcon.icns` from `Sources/MultiPascalMac/Resources/AppIcon.png`, and writes:

```text
dist/Multi-Pascal-Mac-1.1-Amirali-Yazdani.dmg
```

The DMG contains the app and an `Applications` shortcut for drag-and-drop installation. With no signing environment variables, it is an **unsigned development build**; macOS may warn users when they first open it. Use that for local testing, not as the preferred public release.

## 2. Sign and notarize a public release

You need a Developer ID Application identity in your macOS Keychain and notarization credentials. Apple currently lists the Apple Developer Program at US$99/year (regional pricing may vary); enrolment is not required merely to make a DMG, but a Developer ID identity is required for the standard trusted direct-distribution path.

### Find your signing identity

```sh
security find-identity -v -p codesigning
```

Look for an identity similar to:

```text
Developer ID Application: Your Name (TEAMID)
```

### Store notarization credentials in Keychain

Create an app-specific password for the Apple Account that owns the Developer ID. Then store a notary profile (replace the placeholders; do not put the password in a script or commit it to Git):

```sh
xcrun notarytool store-credentials "MultiPascalNotary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "APP_SPECIFIC_PASSWORD"
```

The Keychain profile lets `notarytool` use the credentials without writing the password into the repository.

### Build the signed, notarized DMG

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="MultiPascalNotary" \
./PackageDMG.command
```

The script enables the hardened runtime while signing, verifies the application signature, submits the app for notarization, staples the ticket to the app, creates and signs the DMG, submits the DMG, and staples its ticket. A successful release appears at `dist/Multi-Pascal-Mac-1.1-Amirali-Yazdani.dmg`.

If `SIGNING_IDENTITY` is set but `NOTARY_PROFILE` is not, the script creates a signed but **not notarized** DMG. For a public release, use both variables.

## 3. Verify the release before uploading it

Run these checks on a Mac:

```sh
codesign --verify --deep --strict --verbose=2 "Multi-Pascal Mac.app"
spctl --assess --type execute --verbose=4 "Multi-Pascal Mac.app"
xcrun stapler validate "Multi-Pascal Mac.app"
xcrun stapler validate "dist/Multi-Pascal-Mac-1.1-Amirali-Yazdani.dmg"
```

The `stapler validate` checks require a ticket to have been stapled. Test the download path on a separate Gatekeeper-enabled Mac account or machine if possible. Download the actual DMG from the same website/release page users will use, open it, drag the app into Applications, eject the DMG, then launch the app from Applications. Test with normal Gatekeeper settings; never tell users to disable Gatekeeper globally.

## 4. Distribute it

Upload `dist/Multi-Pascal-Mac-1.1-Amirali-Yazdani.dmg` to a download page or a GitHub Release. Include the supported macOS version (macOS 14 or newer for this package), version number, a short feature description, and a link to this project's source/license information. Publish checksums if you want users to verify downloads:

```sh
shasum -a 256 dist/Multi-Pascal-Mac-1.1-Amirali-Yazdani.dmg
```

A DMG is a disk-image installer/container, not an App Store submission. Apple notarization checks a Developer ID-signed app for known malicious components and common signing problems; it is not App Review and does not mean that Apple endorses the app.

## Apple documentation

- [Distribute outside the Mac App Store](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple Developer Program enrollment and fees](https://developer.apple.com/help/account/membership/program-enrollment/)
