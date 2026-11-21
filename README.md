# remotetv

A small, fast macOS remote for the Apple TV: the Siri Remote's controls in a window, the
keyboard (arrows, Return, Delete) and the Mac's volume and media keys. It talks to the
Apple TV directly over the local network (Apple's Companion Link protocol, plus the
AirPlay remote-control channel for now playing, seeking and mute). Zero dependencies:
Apple frameworks only.

- Clickpad with real holds (long-press menus, held arrows scroll), Back, TV, Play/Pause,
  power, volume and mute, skip ±10 s, subtitles
- Now playing with a scrubber; a sidebar (⌃⌘S) with artwork, Up Next and the TV's apps
- Typing into the TV's text fields from the Mac's keyboard
- `tvctl`, a command line that works through the running app (`tvctl help`)

Requires macOS 27.2 or later on Apple Silicon.

## Build

```sh
make install     # builds RemoteTV.app, copies it to /Applications and opens it
make check       # zero-warning build + unit tests
```

Builds sign with the maintainer's Developer ID when it's set up, otherwise ad-hoc (macOS
then asks for the privacy permissions again after each rebuild).

On first launch RemoteTV lists the Apple TVs it finds; pick yours and type the code the TV
shows.

## What it does on your Mac

- **Local Network** permission: to find and talk to the Apple TV.
- **Accessibility** permission (optional): only to take the volume and media keys while
  RemoteTV is the front app. Everything else works without it.
- Pairing keys live in `~/Library/Application Support/RemoteTV/pairings.tsv` (readable by
  you only). Remove the file, or "Forget" in the TV menu, to unpair.
- `tvctl` is linked into `~/.local/bin` when that directory exists (never replacing a file
  that isn't RemoteTV's own link).
- Up Next thumbnails are loaded from Apple's image servers (the URLs come from the TV).
- No analytics, no accounts, nothing leaves your network except those thumbnails.

`AGENTS.md` is the maintainer guide: protocol notes, architecture, performance and
reliability decisions.
