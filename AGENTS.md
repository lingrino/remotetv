# RemoteTV — maintainer guide

RemoteTV is a macOS remote for the owner's Apple TV: a small window with the Siri
Remote's controls, the keyboard and the Mac's volume/media keys. Audience of one; AI
agents are the only maintainers. Optimize for: latency (launch, key → TV), then the
maintainer's understanding. No settings UI; preferences are constants in code.

This file is the agent guide (Claude Code reads it when there is no CLAUDE.md; don't add one).

## User decisions (2026-11-20, kickoff)

- Native macOS app, **zero dependencies** (Apple frameworks only). The open-source
  projects (pyatv, itsytv-core) were read as protocol references only; nothing was copied
  or imported. Write new protocol code from the facts below, not from their code.
- Minimum macOS = the version on the owner's Mac (27.2). Use the newest APIs freely.
- Performance taken as seriously as fred/peep (sibling repos): measure, don't guess.
- Keyboard: arrows move, Return selects, Delete goes back; volume keys should work.
- Look: modern, plain, obvious, Liquid Glass — like Apple's iOS remote, but better for
  clicking (the clickpad has clickable edges; the iOS remote is swipe-only). No skeuomorphism.
- Single user, one Apple TV most of the time (a couple more when traveling). No config.
- A window you can drag around (not a menu-bar extra), launched from Fred (the owner's
  launcher). Launching it again must show it immediately.
- Local git repo only for now (no remote, no CI, no releases).

Round 2 (2026-11-20, after first use): "very nice". Power button moved from the title bar
to the bottom row (it looked out of place there). Wanted: mute and subtitles like the iOS
remote, typing into TV text fields, a native scrubber; now playing worth exploring if it's
a natural extension. Done: subtitles, scrubber, now-playing title, text input (needs a live
check). Mute needs the AirPlay/MRP tunnel (not started; see Protocol notes).

## Build, run, test

```
make            release .app → build/RemoteTV.app (signed with the Developer ID, see below)
make install    build, copy to /Applications, relaunch
make test       unit tests (debug, all checks on)
make lint       debug + release with -warnings-as-errors: must be zero warnings
make check      lint + test, before every commit
make tvctl      command-line client → .build/release/tvctl
swift scripts/make-icon.swift .   regenerate Resources/AppIcon.icns
```

`scripts/swift.sh` wraps `swift` for the Command Line Tools (copied from fred; same
workarounds). Signing: `scripts/bundle.sh` signs with the owner's Developer ID from the
shared signing keychain (`scripts/setup-signing.sh`, identical copy in fred/peep).
Privacy grants are keyed on bundle id + team, so they survive every rebuild.

### Live testing

- `tvctl scan | pair <tv> | status | press [tv:] down select … | skip 10 | seek 1234 | np |
  captions | text <s> | sleep | wake` shares the app's pairing store; use it to test protocol
  changes without the UI. `tvctl status` prints the connect timings; `tvctl -v …` traces
  every message. Exploration: `tvctl raw <_i> key=value…` (prints the reply) and
  `tvctl listen <s> <event>… +<request>… !<button>…` (TVCTL_DUMP=dir writes every binary
  plist received, decode with plistlib).
- **The TV keeps one connection per pairing identity**: tvctl and the app share one, so
  they kick each other off (the app then reconnects within 0.3 s and kicks tvctl). Quit
  the app (`pkill -x RemoteTV`) while using tvctl; `open -g -a /Applications/RemoteTV.app`
  after.
- The app answers `remotetv://` URLs (`open -g "remotetv://…"`): `show`, `hide`,
  `press/<button>/…`, `skip/<s>`, `sleep`, `wake`, `pairing`, and the debug
  `snapshot?path=/abs/file.png[&controls=1][&appearance=dark|light|system]` (window content
  to PNG; Liquid Glass doesn't render offscreen, layout and symbols do).
- Logs: `/usr/bin/log show --last 5m --predicate 'subsystem == "com.lingrino.remotetv"' --info --debug`
  (plain `log` is a shell builtin here). Launch milestones: `launch→window`,
  `launch→connected`, `reopen→shown`.
- Etiquette: the TV is the owner's. Commands that change what's on screen (press, sleep)
  only when the owner asked or is clearly away from the TV; pairing makes a PIN appear on
  the TV (cancel it if unused). `open` without `-g` steals focus: avoid while the owner works.

## Privacy grants (user-only)

- **Local Network**: Bonjour browse + TCP to the TV (Info.plist `NSLocalNetworkUsageDescription`,
  `NSBonjourServices`). Without it connections fail with a policy error, reported as
  "Local Network access is off".
- **Accessibility**: only for the media-key event tap (volume/play keys while RemoteTV is
  active). Everything else works without it.

## Architecture

```
Sources/RemoteCore/       protocol stack, no AppKit, unit-tested
  OPACK.swift             Apple's binary serialization: Writer (allocation-light), decoder
  TLV8.swift              HAP pairing TLVs (fragments >255 bytes)
  BigUInt.swift           minimal bignum + Montgomery modpow (SRP only)
  BinaryPlist.swift       bplist00 reader/writer with UIDs; KeyedArchive (NSKeyedArchiver reader)
  Media.swift             NowPlaying, TextSession, RTI text operations, ArchiveBuilder
  SRP.swift               SRP-6a client, 3072-bit group, SHA-512
  HAP.swift               PairSetup (M1–M6), PairVerify (M1–M4), Credentials, crypto helpers
  Connection.swift        NWConnection, framing, FrameCipher (ChaCha20-Poly1305)
  Remote.swift            session state machine, handshake, commands, events
  Discovery.swift         Device, Browser (_companion-link._tcp, AppleTV* only)
  CredentialStore.swift   ~/Library/Application Support/RemoteTV/pairings.tsv (0600)
  Errors.swift            ProtocolError (one user-facing line each)
Sources/RemoteTV/         the app (AppKit)
  main.swift              delegate first (starts connecting), then NSApplication
  AppDelegate.swift       wiring: window, remote lifecycle/retry, pairing, keys, URLs, Launch timing
  RemoteView.swift        fixed layout (flipped): NowPlayingStrip (title + scrubber), TextEntry, PairingView
  ClickPad.swift          glass clickpad: wedges/center hit testing, trackpad swipe → touch
  Controls.swift          Theme, PressView (down/up), GlassButton, SplitPill, IconButton
  MediaKeys.swift         session event tap for NX_SYSDEFINED media keys (Accessibility)
Sources/TVCtl/            tvctl
Tests/RemoteCoreTests/    codecs, bignum/SRP vectors (from Python), fake HAP accessory
```

Threading: everything (Remote, Connection, NW callbacks) runs on the main thread/queue.
A key press goes event → OPACK → encrypt → `NWConnection.send` synchronously; no hops.
Only SRP (pairing, ~10 ms release / ~1 s debug) runs on a detached task.

## Protocol notes (Companion Link; owner's TV: AppleTV18,1, tvOS 27.2.1)

Status (2026-11-20): pairing, pair-verify (~37 ms connect), buttons, skip, seek, now
playing and ToggleCaptions verified live. Text input implemented per protocol and
unit-tested, not yet seen working live (see below).

**Ground truth for message names**: macOS ships the iOS remote's framework,
`TVRemoteCore` (and Rapport, the Companion client), in the dyld shared cache. `strings -a`
over `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e.*`
and grep near `TVRCSessionStart` lists every TVRC request/event/key (that's how
`ToggleCaptions` and `FetchCurrentNowPlayingInfoEvent` were found); near `_skpS` for the
Rapport media-control keys (`_mcF`, `_mcs`, `_skpS`, `_vol`).


- Discovery: Bonjour `_companion-link._tcp`; TXT `rpMd` = model ("AppleTV…"). Macs and
  iPhones advertise it too, hence the filter. Connect to the service endpoint by name.
- Frame: `type(1) | length(3, BE) | payload`. Types: 3/4 pair-setup start/next, 5/6
  pair-verify start/next (replies come as the *next* type), 8 encrypted OPACK.
- After pair-verify every non-empty frame is ChaCha20-Poly1305: key = HKDF-SHA512(shared,
  salt "", info "ClientEncrypt-main" / "ServerEncrypt-main"), nonce = counter LE in the
  first 8 of 12 bytes, AAD = the 4-byte header (whose length includes the 16-byte tag).
- Pairing payloads: OPACK `{_pd: TLV8, _pwTy: 1}` (setup) / `{_pd, _auTy: 4}` (verify M1).
  M1 = method 0, state 1 → TV shows a 4-digit PIN. SRP user "Pair-Setup", password = PIN.
  M5 carries our id, Ed25519 LTPK, signature and a name TLV (0x11, OPACK {name}).
- Messages: OPACK `{_i: name, _t: 1 event | 2 request | 3 response, _c: content, _x: xid}`;
  `_em` in a response = error.
- Handshake (sent back to back, no waiting): `_systemInfo` (a stable `_i` makes the TV push
  power events), `_touchStart`, `_sessionStart {_srvT: com.apple.tvremoteservices, _sid}`,
  `TVRCSessionStart {ProtocolVersionKey: "1.2"}` (needed before `FetchAttentionState`),
  `_interest {_regEvents: […]}`, `FetchAttentionState` (power: 1 asleep, 2–4 awake).
- Buttons: `_hidC {_hBtS: 1 down | 2 up, _hidC: usage}` (usages in `Button`). Sleep/Wake are
  sent as "up" only. Skip: `_mcc {_mcc: 7, _skpS: ±seconds as double}` (negative integers
  aren't safe in OPACK). Touch: event `_hidT {_ns, _tFg: 1, _cx, _cy (0…1000), _tPh}`.
- Volume works only when the TV controls the TV/receiver over HDMI-CEC.
- Errors come back as `_em` (text) and/or `_ec` + `_ed` (code, domain; `RPErrorDomain`
  -6714 = not handled, e.g. `_mcc` GetVolume while some apps play).
- Now playing: register `NowPlayingInfo` in `_interest`, send `FetchCurrentNowPlayingInfoEvent`
  (empty reply); the TV pushes `NowPlayingInfo {NowPlayingInfoKey: keyed archive}` now and on
  every state change (play/pause/seek/new item), not continuously. Archive =
  `TVRCNowPlayingInfo` {playbackRate, playbackState (1 playing), captionsEnabled,
  hasValidCaptionOptions, imageData, metadata: TVRCNowPlayingMetadata {title, episodeTitle,
  duration, timeOffset (position at timestamp), timestamp (s since 2001, TV clock), bundleID,
  …}}. Position is extrapolated locally (`NowPlaying.position`). Seeking = `_mcc` skip by
  the difference (no absolute seek in Companion); the TV pushes the new position.
- Captions: request `ToggleCaptions` (TVRC, empty content). State comes from now playing.
- Text input (RTI): `_tiStart` request (reply `_c._tiD` = archive with `$top.sessionUUID`
  and `$top.documentState.docSt.contextBeforeInput` if a field is focused), events
  `_tiStarted {_tiD}` / `_tiStopped`, edit = event `_tiC {_tiV: 1, _tiD:
  RTITextOperations archive ($archiver RTIKeyedArchiver; targetSessionUUID NSUUID,
  keyboardOutput TIKeyboardOutput{insertionText}, textToAssert)}`. The app replaces the
  whole text (`textToAssert`) on every edit. The TV only pushes events to clients whose
  `_systemInfo._i` is non-null (pyatv 0.17 broke focus events by dropping it). Opening
  Search with `_launchApp com.apple.TVSearch` did NOT produce a session blind (focus
  state unknown without seeing the TV): first thing to verify with the owner.
- Mute: not in Companion. The iOS remote mutes through HomeKit (TVRemoteCore: "Sending
  mute key to service", HMCharacteristicTypeMute). Known alternative: MRP `SendHIDEvent`
  consumer page 12 usage 0xE2 over the AirPlay 2 tunnel (pyatv issue #2555), which
  itsytv opens with the *Companion* credentials (no second PIN). That tunnel is the next
  big piece if mute (or MRP-only features) is wanted: AirPlay pair-verify over HTTP,
  HAP-encrypted RTSP, SETUP data stream, encrypted data-stream frames with binary plists
  wrapping protobuf MRP messages. `_mcc` SetVolume (6, `_vol` 0…1) exists and GetVolume
  answered 0.5 with nothing playing; untested what it does to a CEC soundbar (don't
  experiment while the owner is away: it could jump the volume).

## Performance notes (M4 Max, macOS 27.2.1, 2026-11-20)

- Cold launch → window ordered front: ~170 ms, of which ~125 ms is AppKit before
  `didFinishLaunching` (an empty AppKit app measures the same; NSApplication.shared alone
  ~50 ms). Building the window + view ~20 ms, makeKeyAndOrderFront ~17 ms.
- Moving window creation into `applicationWillFinishLaunching` didn't help: AppKit's
  ~50 ms between will/didFinish moved into our window creation instead.
- So the app stays resident: closing the window hides it; launching again (Fred) is a
  reopen → **~10 ms** to visible, already connected. Hidden for 10 min → disconnects;
  reconnect on show.
- The connection starts in `AppDelegate.init`, before NSApplication exists, so TCP and
  mDNS run in parallel with AppKit startup. TCP connect to the TV measured 12–17 ms.
- TCP_NODELAY on: a click is two tiny frames back to back.

## Open work / ideas (owner hasn't asked for these; propose before big ones)

- Artwork: `NowPlaying.artwork` (imageData) is parsed but not shown; it was null for the
  one item seen.
- Mute: see Protocol notes (MRP over AirPlay, or SetVolume(0) if it proves safe).
- App launcher (`FetchLaunchableApplicationsEvent`, `_launchApp`): `Remote.launch` exists.
