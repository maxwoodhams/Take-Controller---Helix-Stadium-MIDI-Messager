# TAKE CONTROLLER - Helix Stadium MIDI Messager

SwiftUI iPadOS controller for sending Helix Stadium MIDI control changes.

## Open

Open `HelixMIDI.xcodeproj` in Xcode, set your signing team on the `HelixMIDI` target, then run on an iPad. The installed app uses `TAKE CTRL` as its short display name.

## MIDI Behavior

- Buttons send Control Change messages on MIDI channel 1.
- `any value` buttons currently send value `127`.
- Low-range commands use value `0`.
- High-range commands use value `127`.
- Playlist changes send `CC63` with values `0...127`.
- Song changes send `CC10` with values `0...127`.

The app sends each message to every available CoreMIDI destination. Connect your MIDI interface or network MIDI destination before tapping controls, then use the refresh button if needed.

## Persistence

Button order, selected playlist, selected song, playlist names, and song names are stored in `UserDefaults`.
