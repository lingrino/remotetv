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

- `tvctl scan | pair <tv> | status | press [tv:] down select … | skip 10 | sleep | wake`
  shares the app's pairing store; use it to test protocol changes without the UI.
  `tvctl status` prints the connect timings.
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
  RemoteView.swift        fixed layout (flipped), PairingView
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

Status: discovery, TCP and pair-setup M1/M2 verified live on the owner's TV
(2026-11-20); M3–M6, pair-verify and the session verified only against the fake
accessory in `PairingTests` until the first real pairing. Update this line when it lands.


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

- Text input: when the TV shows a keyboard (`_tiStarted`), show a field and send `_tiC`
  with an RTI NSKeyedArchiver payload (needs `_tiStart`; pyatv's plist_payloads documents
  the shape).
- Now playing (title, artwork, progress) needs MRP over the AirPlay 2 tunnel (HAP over
  AirPlay pairing + protobufs). Large; only if asked.
- Captions / mute buttons from the iOS remote: no Companion command known.
- App launcher (`FetchLaunchableApplicationsEvent`, `_launchApp`): `Remote.launch` exists.
