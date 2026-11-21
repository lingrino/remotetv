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
- Local git repo at first; the owner is about to publish it on GitHub (no CI/releases yet).

Round 6 (2026-11-20): an independent full review (another model, all files) before going
public on GitHub; its findings were fixed (see Security and Reliability). Next: publish.

Round 5 (2026-11-20): "very thorough and reliable" pass (see Reliability). The main view
stays exactly as simple as it is — no artwork or lists there; those live in a sidebar that
slides out on demand (the owner left its design to the agent: "care about design… make
something great"). tvctl ships inside the app, lands on the PATH by itself, and talks
through the app's connection.

Round 4 (2026-11-20): mute, scrubbing and now playing confirmed working. MRP subtitles
broke audio (see Protocol notes) — reverted to Companion ToggleCaptions. No placeholder in
the text bar; no hover text (tooltips) anywhere — keep it that way.

Round 3 (2026-11-20): text bar redesigned (glass capsule), ⌘C/⌘X/⌘Z, typing sent as
delete/insert edits (YouTube doesn't report its field's text, so replace wiped it). The
owner accepted building the AirPlay/MRP tunnel "only if very reliable and unnoticeable":
it starts after every Companion session, never blocks the remote, retries quietly
(2 s → 60 s backoff), and is the now-playing source when up. Mute = the speaker in the
middle of the volume pill (dim when the tunnel is down).

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

- `tvctl` is on the PATH (`~/.local/bin/tvctl` → `RemoteTV.app/Contents/Helpers/tvctl`; the
  app (re)creates the symlink at launch, `Commands.installCLI`). `tvctl help` lists commands:
  status, np, press/hold, skip/seek, mute, captions, sleep/wake/power, text/type, launch,
  apps, upnext, show/hide, sidebar, raw, snapshot. They run on the **app's** session via
  its control socket (`ControlServer`: `~/Library/Application Support/RemoteTV/control.sock`,
  0600; one line of U+001F-separated args, reply text + "\u{1F}<exit code>"), starting the
  app in the background if needed. ~15 ms per command.
- `tvctl direct …` uses tvctl's own connection for protocol work: `direct status` (connect
  timings), `direct -v …` (traces every message), `direct raw <_i> k=v…`, `direct listen <s>
  <event>… +<request>… !<button>…` (TVCTL_DUMP=dir writes every binary plist received),
  `direct airplay | mrp [s] | mute | mseek <s>`; `scan` and `pair <tv>` are always direct
  (pair tells the running app to reload). **The TV keeps one connection per pairing
  identity**: a direct session kicks the app's off (the app reconnects in 0.3 s and kicks
  it back), so `pkill -x RemoteTV` first and `open -g -a /Applications/RemoteTV.app` after.
  TVCTL_FAKE_IDENTITY=1 makes a direct session use an identity the TV never paired (tests
  the "pairing lost" path).
- `tvctl snapshot <file.png> [dark|light] [controls]` writes the window (with the sidebar)
  to a PNG; Liquid Glass doesn't render offscreen, layout and symbols do.
- `remotetv://` URLs only do `show`, `hide`, `sidebar`: any web page or app can open a URL,
  so nothing that touches the TV or the disk may ever be added to the scheme.
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
Sources/RemoteCore/       protocol stack, no AppKit, unit-tested (release builds keep bounds checks)
  OPACK.swift             Apple's binary serialization: Writer (allocation-light), decoder
  TLV8.swift              HAP pairing TLVs (fragments >255 bytes)
  BigUInt.swift           minimal bignum + Montgomery modpow (SRP only)
  BinaryPlist.swift       bplist00 reader/writer with UIDs; KeyedArchive (NSKeyedArchiver reader)
  Media.swift             NowPlaying, TextSession, RTI text operations, ArchiveBuilder
  AirPlay.swift           HAPCipher, HAPStream, HTTPMessage, AirPlayTunnel (control/events/data)
  Protobuf.swift          hand-rolled protobuf writer/reader
  MRP.swift               MediaRemote: MRP handshake, player state, seek, artwork, mute
  Library.swift           TV apps (with icons), Up Next items, deep links
  SRP.swift               SRP-6a client, 3072-bit group, SHA-512
  HAP.swift               PairSetup (M1–M6), PairVerify (M1–M4), Credentials, crypto helpers
  Connection.swift        NWConnection, framing, FrameCipher (ChaCha20-Poly1305)
  Remote.swift            session state machine: connect, pair-verify, pairing, handshake, events
  Remote+Commands.swift   buttons, playback, text, power, apps, touch, raw requests (Waiter)
  Remote+Reliability.swift deaf watchdog, probe, reconnect, goodbye, wake knock
  Remote+Media.swift      the AirPlay/MRP tunnel's lifecycle and the now-playing merge
  UnixSocket.swift        sockaddr_un helper (control socket; app and tvctl)
  Discovery.swift         Device, Browser (_companion-link._tcp, AppleTV* only)
  CredentialStore.swift   ~/Library/Application Support/RemoteTV/pairings.tsv (0600)
  Errors.swift            ProtocolError (one user-facing line each)
Sources/RemoteTV/         the app (AppKit)
  main.swift              delegate first (starts connecting), then NSApplication
  AppDelegate.swift       lifecycle, window, show/hide/idle, remote lifecycle/retry, header, URLs, Launch timing
  AppDelegate+Pairing.swift   TV menu, browsing, pairing flow
  AppDelegate+Sidebar.swift   opening the sidebar (window widening), loading its data
  AppDelegate+Keyboard.swift  keys and media keys → buttons; releasing held keys
  AppDelegate+Rename.swift    following a renamed TV
  RemoteView.swift        fixed layout (flipped): NowPlayingStrip (title + scrubber), TextEntry, PairingView
  ClickPad.swift          glass clickpad: wedges/center hit testing, trackpad swipe → touch
  Controls.swift          Theme, PressView (down/up), GlassButton, SplitPill, IconButton
  MediaKeys.swift         session event tap for NX_SYSDEFINED media keys (Accessibility)
  Sidebar.swift           the slide-out panel: now-playing card, Up Next list, app grid, image loading
  ControlServer.swift     tvctl's Unix socket
  Commands.swift          tvctl commands on the app's session; installs the tvctl symlink
Sources/TVCtl/            tvctl
Tests/RemoteCoreTests/    codecs, bignum/SRP vectors (from Python), fake HAP accessory,
                          FakeTV (loopback Apple TV: framing, pair-verify, encryption) +
                          SessionTests (Remote's state machine, liveness, trust boundary)
```

Threading: Remote, Connection, the AirPlay tunnel and all NW callbacks run on the main
thread/queue. A key press goes event → OPACK → encrypt → `NWConnection.send` synchronously;
no hops. Off the main thread: SRP (pairing, ~10 ms release / ~1 s debug, detached task),
the control socket's threads (they only hand requests to main), sidebar image decoding
(ImageIO thumbnails on a concurrent queue), URLSession, and NWPathMonitor's queue.

## Protocol notes (Companion Link; owner's TV: AppleTV18,1, tvOS 27.2.1)

Status (2026-11-20): pairing, pair-verify (~37 ms connect), buttons, skip, seek, now
playing, text input (owner-tested in Search and YouTube), mute, artwork, app list and Up
Next verified live; ToggleCaptions is accepted but flaky (as on Apple's own remote).

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
  `_em` in a response = error. OPACK sized integers are **signed** (the TV sends -6714 as
  0x31 C6 E5): the writer picks signed widths (200 → 2 bytes), the reader sign-extends.
- Trust boundary: until pair-verify finishes and frames are encrypted, nothing from the
  socket but pairing replies is processed (OPACK message frames are dropped), so a LAN host
  answering for the TV's Bonjour name can't inject events.
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
  keyboardOutput TIKeyboardOutput{insertionText, deletionCount}, textToAssert)}`. The app
  sends each local change as delete-N + insert at the TV's cursor (`RTI.diff`): YouTube
  doesn't report its field's text, so replacing it would wipe what's there. The TV only pushes events to clients whose
  `_systemInfo._i` is non-null (pyatv 0.17 broke focus events by dropping it). Launching
  Search remotely doesn't by itself focus a field (no session); the owner's own use works.
- AirPlay remote-control tunnel (`AirPlay.swift`, verified 2026-11-20, ready in ~55–70 ms):
  Bonjour `_airplay._tcp` (same instance name as the Companion service), IPv4.
  `POST /pair-verify` HTTP/1.1 (headers User-Agent AirPlay/320.20, X-Apple-HKP 3,
  octet-stream) ×2 with the **Companion credentials** — accepted, no second pairing.
  Then HAP framing on the control connection (Control-Salt, Control-Write/Read-Encryption-Key):
  ≤1024-byte frames, `len(2 LE) | ciphertext | tag`, AAD = len, nonce = 4 zero bytes +
  counter LE. RTSP/1.0 SETUP (bplist {isRemoteControlOnly: true, …}) → eventPort; event
  channel keys Events-Salt with *Read* as our send key; RECORD; SETUP {streams: [{type 130,
  controlType 2, seed, …}]} → dataPort; data keys "DataStream-Salt<seed>",
  DataStream-Output/Input-Encryption-Key. Data frames: 32-byte BE header (size, "sync"/"rply"
  + 8 zeros, "comm", seqno, pad) + bplist {params: {data: varint-length-prefixed MRP
  protobufs}}; answer every "sync" with a "rply" of the same seqno. `POST /feedback` every
  2 s. Coexists with the Companion connection (no kick-off).
- MRP over the tunnel (`MRP.swift`, `MediaRemote`; ready ~70 ms after the tunnel):
  ProtocolMessage {type 1, identifier 2, errorCode 4 (=0), uniqueIdentifier 85, payload in
  an extension field per type}. Handshake: DEVICE_INFO (15/ext 20, as the iOS remote:
  com.apple.TVRemote 344.28, lastSupportedMessageType 108, deviceClass iPhone) → wait for
  the TV's DEVICE_INFO → SET_CONNECTION_STATE Connected, CLIENT_UPDATES_CONFIG (all true,
  **nowPlayingUpdates must be true**), GET_KEYBOARD_SESSION, PLAYBACK_QUEUE_REQUEST
  (location 0, length 1, includeMetadata, includeLanguageOptions). The TV then pushes
  SetNowPlayingClient (46/50), SetNowPlayingPlayer (47/51), SetState (4/9: playbackState,
  supportedCommands, playbackQueue → ContentItem {metadata, availableLanguageOptions 5,
  currentLanguageOptions 6}), UpdateContentItem (56/60, metadata deltas: protobuf merge =
  byte concatenation, which `ProtoMessage.message` honors), Remove{Client,Player}.
  Now playing = active client → its active player (else MediaRemote-DefaultPlayer) →
  items[location].metadata {title 1, duration 14, elapsedTime 35, playbackRate 39,
  isAlwaysLive 37, elapsedTimeTimestamp 74}. Every app reports here (Prime, YouTube…),
  unlike Companion's NowPlayingInfo (Apple-TV-app-centric, flaky: owner saw it drop).
  Commands: SeekToPlaybackPosition (SendCommand 1/6 {command 45, options {playbackPosition
  9}}); mute = SendHIDEvent (8/13) consumer page 12,
  usage 0xE2, down+up, then an empty GENERIC (42) flush.
  **Subtitles: never send EnableLanguageOption (53) / DisableLanguageOption (54)** with
  options.languageOption 27 = a LanguageOption from the item: tried 2026-11-20 in the TV
  app, the show's audio went silent until the owner re-picked an audio track (the command
  apparently replaces the whole media selection). The button sends Companion
  `ToggleCaptions` (what Apple's remote does; flaky on Apple's remote too). MRP language
  options (ContentItem 5/6; LanguageOption type 1 = legible, 0 = audible) are still read
  for the button's availability and on/off state; only AVKit players publish them (TV
  app yes, Prime no). The 60-byte HID event template is
  in `MediaRemote.hidEvent` (test pins pyatv's known-good bytes). Mute state isn't
  reported for HDMI-CEC audio, so the button doesn't show muted/unmuted.
- Mute/volume background: the iOS remote mutes through HomeKit (TVRemoteCore: "Sending
  mute key to service", HMCharacteristicTypeMute); HomeKit needs a Mac Catalyst app with
  the HomeKit entitlement — not an option for this AppKit app. `_mcc` SetVolume (6, `_vol`
  0…1) exists and GetVolume answered 0.5 with nothing playing; untested on a CEC soundbar
  (could jump the volume; don't experiment while the owner is away).
- Info.plist NSBonjourServices must list every service type resolved (`_airplay._tcp`
  too): an undeclared type fails with NWError -65555 NoAuth in the app (tvctl, a CLI, isn't
  subject to it, so it hides the problem).
- Library (TVRC, Companion): `FetchLaunchableApplicationsEvent` → `{bundleID: name}`; with
  `IncludeAppMetadataKey`, `UsePNG`, `AppRangeStartingIndexKey`, `AppRangeCountKey` →
  `{AppInfos: {bundleID: {LocalizedAppName, ImageKey (PNG, 5:3 tvOS icon), …}}, AppCountKey}`
  (fetched one app per request to keep the TV's order). `FetchUpNextInfoEvent` →
  `{UpNextInfosKey: [archived TVRCUpNextInfo]}` (actionURL deep link, service, reason,
  progress, mediaInfo {title, seasonNumber, episodeNumber (int or real), imageURLTemplate
  mzstatic {w}x{h}.{f}}); it sometimes fails with `AMSErrorDomain 301` for a while (the UI
  keeps the last list). Play an item = `_launchApp {_urlS: actionURL}` (tv.apple.com
  links open the TV app). Also seen, unused: FetchUserAccountsEvent/SwitchUserAccountEvent,
  FetchSiriRemoteInfo (supportsFindMy; Find My needs a payload from the iPhone's Find My
  stack), ToggleReduceLoudSounds, ToggleSystemAppearance, FetchCurrentTopShelfItemsEvent.
- MRP artwork: PLAYBACK_QUEUE_REQUEST with artworkWidth 600, artworkHeight -1 → SetState
  whose ContentItem.artworkData (3) is a JPEG (600×338, ~63 KB). Asked only while the
  sidebar is open, once per item id.
- Data-stream bug to not repeat: the frame type is at bytes 4–11 (after the size); a sync
  frame that isn't answered with a "rply" makes the TV stop sending.

## Reliability (2026-11-20; keep all of these)

- **Deaf sessions**: a TV can keep TCP up while its remote service stops answering (seen by
  other clients after hours). `_hidC` presses and probes are tracked by xid; one unanswered
  for 3 s drops the session, discards queued presses (never replay late) and the app
  reconnects (0.3 s). `Remote.checkDeaf`.
- **Probe on show**: when the window comes forward after ≥15 s of quiet, a cheap answered
  request (`FetchMediaControlStatus`) finds a dead session before the user presses. A
  network change forces the same probe (instead of a reconnect).
- **Every request completes**: `raw` requests (apps, Up Next, tvctl raw) get their reply,
  (nil, error), "disconnected" when the connection ends, or "timed out" after 5 s
  (`Remote.Waiter`) — never a hang (the sidebar once sat on "Loading…" forever).
- **Queued presses expire**: commands made while connecting run only if ≤2 s old when the
  session comes up; a press is one queue entry (never half a press) and a button's "up" is
  never dropped (no stuck holds).
- **Unreadable messages**: a session message that doesn't decode is logged and dropped,
  not fatal; every frame is decrypted even if its type is unknown (the nonce counter).
- **MRP**: the handshake must finish within 5 s or the tunnel is torn down and retried;
  merged content items are compacted (never truncated), artwork stored apart.
- **Keepalive**: Companion NoOp frame (type 1, empty) every 30 s; TCP keepalive (10 s idle,
  2×5 s) catches dead peers; AirPlay `POST /feedback` every 2 s and a 6 s
  unanswered-request watchdog on the AirPlay control channel restarts the tunnel.
- **Goodbye**: `_sessionStop {_srvT, _sid}` before quitting (applicationShouldTerminate →
  terminateLater, ≤0.3 s), before Mac sleep, and when the hidden-window idle timer fires.
  `_sid` is a UInt64 (remote << 32 | local): `OPACK.Writer.uint`.
- **Network changes**: NWPathMonitor; a changed interface/gateway set → reconnect at once
  (don't wait ~20 s for keepalive). Wake from sleep → fresh connection.
- **Wake knock**: the TV's last address (UserDefaults `host.<name>`) gets brief TCP
  connects on 49153/7000/3689/49152/32498 when it can't be reached (a sleeping Apple TV's
  Bonjour sleep proxy wakes it); at most every 10 s and only for the first 3 failures (away
  from home the address belongs to someone else's network).
- **Pairing lost** (TV reset / removed under Remotes and Devices): pair-verify comes back
  with error 2 → `.unpaired`: no retry loop, the menu offers Pair Again. Other codes (busy,
  back off) are ordinary retryable failures. Pairing attempts are tokened (a stale SRP
  result is dropped) and M3/M5 have a 10 s timeout.
- **Renamed TV**: pairings are keyed by name; when the name can't be found (`.notFound`,
  `.timeout`) and an unpaired Apple TV is on the network, the stored credentials are tried
  on it — each candidate once per outage (only the right TV can complete pair-verify) — and
  the pairing moves over (`AppDelegate.followRename`).
- **Local Network denied**: detected (`NWPath.unsatisfiedReason == .localNetworkDenied`,
  DNS -65570) → "Local Network access is off. Click to allow it." (opens the Privacy pane);
  retries continue so it connects once allowed.
- **Dimming**: `_iMC` flags (and FetchMediaControlStatus) say what the current app takes:
  skip buttons dim without skip, the volume pill (and mute) without volume; the scrubber
  hides when neither MRP seek nor skips work. Unknown until the TV says → nothing dims.
  The TV acknowledges every press either way, so dimming is the only honest feedback.
- **Input**: one-shot buttons (power, subtitles, mute) fire only if released over them;
  held buttons always send the "up". Key repeats are ignored (the TV repeats a held
  direction itself); held keys/clicks are released when the window loses focus, when focus
  moves into the text bar, and when ⌘ goes down (AppKit sends no key-up for a key released
  while ⌘ is held). Media keys pass through to the Mac when the TV isn't connected.
- **Hidden** (closed, ⌘H, `tvctl hide`): ticker, artwork and Bonjour browsing stop; the
  session ends after 10 min (re-armed by tvctl commands, which reconnect on demand).
- Failures are typed (`Status.failed(ProtocolError)`): behavior never depends on the
  wording of an error message.

## Security (2026-11-20 review)

- Untrusted input: everything from the network is parsed with explicit bounds; integers
  from binary plists are range-checked (`Reader.int`), plist decoding has an object budget
  (shared references could expand exponentially), OPACK/TLV8/protobuf/HTTP parsers throw
  on truncation. RemoteCore is built without `-Ounchecked`, so a missed check traps.
- TV identity: pair-verify checks the TV's Ed25519 signature against the paired key
  before anything else; pairing requires a valid key from the TV (signature verified when
  sent). Nothing derived from our private seed is sent (`pubID` hashes the public key).
- Control socket: 0600 (created under umask 0177), directory 0700, and `getpeereid` must
  match our uid; the reply handoff is locked. URL scheme: window actions only.
- Pairings file: written to a fresh 0600 file (O_EXCL), fsynced, renamed; a file that
  exists but can't be read is never overwritten; unknown lines are preserved. IME
  composition isn't sent until committed. Long trackpad swipes lift and re-grip at the
  virtual pad's edge (never a lift without motion, which would be a tap).

### Other projects' bugs, checked (2026-11-20)

Itsytv (66 issues), atv-desktop-remote, Clicker, alokdhir/appletv-remote, ribren/clicker,
Raycast, Homebridge, Home Assistant. Handled: stale pairing loops; Keychain prompts (file
store); rename/name collision (follow rename; pair-verify proves identity); key-repeat
click bursts; stuck keys on focus loss; drag-off-then-release clicks; swipes captured off
the pad; momentum swipes; non-ASCII text (UTF-16 bplist strings); pair-verify on a new
connection after pair-setup (tvOS 27 hang); "Connecting…" forever after sleep/network
change; volume confusion with CEC (dimming); HID skip keys that don't skip (`_mcc` skip);
long-press that fell through as a click (real holds); YouTube ignoring MRP play/pause (we
use HID); artwork request loops (asked once per item); Local Network denied; AirPlay
access restricted (Companion keeps working; MRP retries quietly). Watch for (claimed by
one project, not seen here): tvOS ignoring arrow `_hidC` while a `_touchStart` session is
open — the owner uses both without problems on tvOS 27.2.1; the fix would be `_touchStop`
before arrows.

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

- Not yet seen live: playing an Up Next item and launching from the app grid (the same
  `_launchApp` tvctl uses, which works).
- Review leftovers judged not worth it now: unifying `Connection`/`HAPStream` and their
  ciphers (different framing and nonce layouts; ~100 similar lines), a menu-bar mode.
- Hold a skip button to fast-forward/rewind (`_mcc` 8–11 begin/end).
- Reduce Loud Sounds toggle (one TVRC request); a sleep timer (sleep the TV in N minutes).
