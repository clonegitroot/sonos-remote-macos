# Sonos Remote for macOS

A native menu bar remote for Sonos rooms and groups on your local network. An active room or group is selected on first connection when one is available.

- Play, pause, skip, mute, adjust group and room levels, and add or remove rooms.
- **Sync Room Volumes** sets each room to the current group level.
- The Mac media keys work when macOS chooses Sonos Remote as its Now Playing app.
- Add small, medium, or large desktop widgets from **Edit Widgets**. The large size displays up to five Sonos Favorites.

## Preview

The previews below use sample rooms, tracks, and favorites.

| Menu bar | Large desktop widget |
| --- | --- |
| <img src="docs/images/menu-bar.png" width="330" alt="Sonos Remote menu bar panel with room picker, playback, and volume"> | <img src="docs/images/widget-large.png" width="344" alt="Large Sonos Remote widget with playback and five Sonos Favorites"> |

| Small desktop widget | Medium desktop widget |
| --- | --- |
| <img src="docs/images/widget-small.png" width="164" alt="Small Sonos Remote widget with playback and volume controls"> | <img src="docs/images/widget-medium.png" width="344" alt="Medium Sonos Remote widget with playback, volume, and room volume sync"> |

## Run locally

Requires macOS 14 or later on Apple silicon and a Mac on the same network as your speakers. Build the app with the instructions below, move it to Applications, and open it. Allow local network access if macOS asks. If discovery fails, enter a Sonos speaker’s IPv4 address in Connection Settings.

The app connects directly to speakers. It stores the last speaker address and selection in local preferences and copies favorite titles and descriptions into a local shared widget cache. The downloadable bundle carries no speaker settings, favorite cache, or Sonos credentials.

## Build

On the tested Mac, WidgetKit excluded the ad hoc build from the widget gallery. The ad hoc ZIP is a local menu bar test build. A widget-enabled distribution build requires separate signing and verification.

With Xcode selected and its command-line tools available, run:

```sh
./build.sh
```

The script creates `build/Sonos Remote.app` and `build/Sonos Remote.zip`. It signs the widget before the containing app and verifies the finished bundle. To use a local signing identity, set `SIGN_IDENTITY` to its name or fingerprint. See [Build notes](BUILD.md) for widget packaging and distribution details.

## License

Sonos Remote is free software licensed under the [GNU General Public License v3.0 only](LICENSE). This is an independent project and is not affiliated with Sonos.
