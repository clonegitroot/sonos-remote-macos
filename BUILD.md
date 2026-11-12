# Build and test Sonos Remote

## Prerequisites

- A Mac with Apple silicon. The app targets macOS 14 or later. The build was tested with Xcode 27.2.
- Full Xcode with the macOS SDK, plus Git. Open Xcode once to complete its first-launch setup. The macOS version needed to run Xcode may be newer than the app’s deployment target.
- A Sonos system reachable from the Mac on the same local network for playback and Favorites testing. Building the app requires neither a Sonos account nor access to a speaker.

Check the selected developer tools:

```sh
xcode-select -p
xcodebuild -version
xcrun --find swiftc
xcrun --sdk macosx --show-sdk-version
```

If the selected tools point to Command Line Tools alone, select full Xcode under **Xcode → Settings → Locations → Command Line Tools**, then repeat the checks.

## Clone and build

```sh
git clone https://github.com/clonegitroot/sonos-remote-macos.git
cd sonos-remote
./build.sh
```

The script compiles the menu bar app and WidgetKit extension, embeds the widget in `Contents/PlugIns`, signs the widget before the app, verifies both signatures, and creates:

| Output | Use |
| --- | --- |
| `build/Sonos Remote.app` | Open locally or copy to Applications |
| `build/Sonos Remote.zip` | Packaged build for testing |

The default signature is ad hoc. The app can be built without an Apple Developer account, but Gatekeeper rejected the ad hoc package in testing and WidgetKit excluded its registered extension from the gallery. Treat this ZIP as a local menu bar test build.

## Run and verify

1. Move the app to Applications and open it. Click the speaker icon in the menu bar. If macOS asks, allow **Local Network** access.
2. Choose a room or group. If discovery fails, check **System Settings → Privacy & Security → Local Network**, then enter a speaker’s IPv4 address under the app’s **Connection Settings** and choose **Connect**.
3. With a widget-capable signed build, Control-click the desktop, choose **Edit Widgets**, and search for **Sonos Remote**. Test the small, medium, and large sizes.
4. Confirm playback and volume target the selected group, and check that the large widget displays saved Sonos Favorites. macOS routes keyboard media controls to the app it selects as Now Playing.

Check the package and the widget registration:

```sh
codesign --verify --deep --strict --verbose=2 "build/Sonos Remote.app"
pluginkit -m -v -i org.sonosremote.mac.widget
```

A PlugInKit listing confirms registration. Check the gallery separately to confirm WidgetKit accepts and renders the extension.

## Signing and distribution

List available signing identities with `security find-identity -v -p codesigning`. For a local signed build, pass an identity name or fingerprint:

```sh
SIGN_IDENTITY="your signing identity" ./build.sh
```

For testing Favorites with a signing team, configure the same valid macOS App Group in `host.entitlements`, `widget.entitlements`, and the `SonosHistoryGroup` setting in both Info.plist files. The host writes only titles and descriptions to the shared cache, and the widget reads that cache. Verify access with the exact signature and app group you intend to use.

For general distribution, use a **Developer ID Application** certificate. Configure the correct app group and any required profiles, sign the extension and app with hardened runtime and a secure timestamp, submit the signed ZIP for notarization, and staple the result to the app. The default build script uses `--timestamp=none` and does not perform those distribution steps. Repackage the stapled app and test the downloaded ZIP, including widget rendering and Favorites, on a separate Mac.

## Widget packaging

The widget executable starts through Foundation’s `_NSExtensionMain` and retains Swift’s `_main` symbol. Launching the WidgetBundle directly caused a crash before indexing. Widget buttons send commands to the running app through its `sonosremote-local` URL scheme.
