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
- Local git repo at first, then GitHub (lingrino/remotetv), released through the
  owner's Homebrew tap like fred and peep (see CI and releases).

Round 9 (2026-11-22): tvctl is a first-class interface to the product, for people and for
other agents, not a debugging aid: "nice help text, a logical and coherent command
structure, and coverage over the features that exist in the app". See "tvctl" below for
what that means in the code. Done in the same change as round 8.

Round 8 (2026-11-22): tvctl works without the app. Asked whether to connect per command or
to keep a background service that both the app and tvctl talk to, the owner chose the
per-command connection: connecting is ~37 ms, while a service would put IPC between the
window and every press, need launchd registration and upgrade restarts, and hold the TV's
one connection all day. A short-lived helper that lingers between commands (repeat
commands in ~15 ms) was the offered next step if scripts ever send bursts; not built.

Round 7 (2026-11-21): published. Public GitHub repo (lingrino/remotetv); repo, ruleset,
secrets and secret scanning are Terraform in lingrino/infra (#3043–#3046), in autotouch's
order (private first, branch resources after the first push, public, then secret
scanning). CI and releases copied from autotouch/fred; every merge publishes
`Casks/remotetv.rb` in lingrino/homebrew-tap, and lingrino/dotfiles installs it on the
personal Mac and the mini. README: the owner's text plus `docs/remote.png` (the real
window, dark mode, sidebar closed, nothing playing: `screencapture -l <window id>` with
RemoteTV frontmost; `tvctl debug snapshot` can't render Liquid Glass). No AI attribution in
commits or PRs, ever.

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
make release    what CI publishes (scripts/release.sh): build/release/RemoteTV-<version>.zip + remotetv.rb
swift scripts/make-icon.swift .   regenerate Resources/AppIcon.icns
```

`scripts/swift.sh` wraps `swift` for the Command Line Tools (copied from fred; same
workarounds). Signing: `scripts/bundle.sh` signs with the owner's Developer ID from the
shared signing keychain (`scripts/setup-signing.sh`, identical copy in fred/peep).
Privacy grants are keyed on bundle id + team, so they survive every rebuild.

### CI and releases (`.github/workflows`, same as fred/peep/autotouch)

- Changes land through PRs only: branch, `make check` (plus live checks for anything the
  TV sees), PR, required checks, squash merge. Every merge to main is a release.
- `validate`, on every PR. The main ruleset requires a PR (no direct pushes, no force
  pushes) and its `lint`, `test` and `scripts` jobs: `make lint`; `make test` plus a
  release dry run (ad-hoc signed) and `brew style` on the generated cask; shellcheck and
  actionlint. Runner label `xcode-27`: GitHub's macOS 27 arm64 image; its default Xcode
  lags, so both workflows set `DEVELOPER_DIR` to Xcode 27.2 (move both with the local
  toolchain). Live checks need the TV, so they stay local: `make check` and the tvctl
  checks before opening a PR.
- `release`, on every push to main: version 0.0.N, N = commits on main (squash merges, so
  every merge bumps it). `scripts/release.sh` builds, signs (app and the tvctl helper, with
  a secure timestamp), notarizes (API key), staples, zips and writes the cask. With the
  Apple secrets it publishes GitHub release `v0.0.N` and `Casks/remotetv.rb` in
  lingrino/homebrew-tap; without them it keeps the ad-hoc zip as a run artifact only.
- Secrets and repo settings come from Terraform in lingrino/infra
  (`terraform/github/repo_remotetv.tf`; `secrets_github.tf` `local.mac_app_repos`: the
  shared Developer ID, notarization and tap-token secrets). fred's AGENTS.md has how the
  owner rotates them.
- Upgrades: `brew upgrade` swaps /Applications/RemoteTV.app under the running app;
  `BundleWatcher` (FSEvents on the enclosing folder) sees the executable become a
  different file and the app restarts into it (`open -g` unless it was frontmost) when the
  window is on screen, or quits when hidden. No `uninstall quit:` in the cask (brew runs it
  on every upgrade, and quitting through Apple Events needs Automation access). Quitting
  from a main-queue block deadlocks (terminateLater waits for the goodbye, itself a
  main-queue block): hop through `RunLoop.main.perform` as `replacedOnDisk` does.
- The owner's Macs install it through their dotfiles (lingrino/dotfiles):
  `cask 'lingrino/tap/remotetv'` in `home/exact_private_dot_config/private_homebrew/Brewfile_*`.
- Renovate keeps action versions current (`renovate.json`).

### Live testing

- `tvctl` is on the PATH (`~/.local/bin/tvctl` → `RemoteTV.app/Contents/Helpers/tvctl`; the
  app (re)creates the symlink at launch, `Commands.installCLI`). `tvctl help` is its
  manual (see "tvctl" below). **The TV keeps one connection per pairing identity**, so one
  process talks to it at a time:
  - App running: commands run on the **app's** session via its control socket
    (`ControlServer`: `~/Library/Application Support/RemoteTV/control.sock`, 0600; one line
    of U+001F-separated args, reply text + "\u{1F}<exit code>"). ~15 ms per command.
  - App not running: tvctl connects itself, runs the one command, and leaves (`oneShot` in
    `Sources/TVCtl/main.swift`; see Reliability). The app is **not** started. Only `show`
    and `sidebar` (and `debug snapshot`) start it (in the background, ~0.4 s).
  - Either way the commands are the same code: `TVCommand` (RemoteCore).
- Protocol work: `tvctl help debug`. `tvctl debug raw <request> k=v…` (any Companion
  request; through the app when it runs), `debug event <name> k=v…`, `debug listen <s>
  <event>… +<request>… !<button>…` (TVCTL_DUMP=dir writes every binary plist received),
  `debug airplay`, `debug mrp [s] | mrp mute | mrp seek <s>` (the AirPlay link alone, no
  Companion session). `--direct` makes any command use tvctl's own connection even while
  the app runs and prints the connect timings (`tvctl --direct status`); `-v` also traces
  every message (both to stderr). `--tv <name>` picks another paired TV. A direct session
  kicks a running app's off (the app reconnects in 0.3 s and kicks it back), so `pkill -x
  RemoteTV` first and `open -g -a /Applications/RemoteTV.app` after; with the app quit,
  every command is a direct session anyway. TVCTL_FAKE_IDENTITY=1 makes tvctl's own
  session use an identity the TV never paired (tests the "pairing lost" path).
- `tvctl debug snapshot <file.png> [dark|light] [controls]` writes the window (with the
  sidebar) to a PNG; Liquid Glass doesn't render offscreen, layout and symbols do.
- `remotetv://` URLs only do `show`, `hide`, `sidebar`: any web page or app can open a URL,
  so nothing that touches the TV or the disk may ever be added to the scheme.
- Logs: `/usr/bin/log show --last 5m --predicate 'subsystem == "com.lingrino.remotetv"' --info --debug`
  (plain `log` is a shell builtin here). Launch milestones: `launch→window`,
  `launch→connected`, `reopen→shown`.
- Etiquette: the TV is the owner's. Commands that change what's on screen (press, sleep)
  only when the owner asked or is clearly away from the TV; pairing makes a PIN appear on
  the TV (cancel it if unused). `open` without `-g` steals focus: avoid while the owner works.

## tvctl (a product interface: keep it one)

`tvctl help` must be enough for a person or an agent who has never seen it. What that
rests on:

- **One name, one meaning.** Commands are grouped as the help lists them: Remote (press,
  hold), Playback (playing, play, pause, playpause, skip, seek, volume, mute, captions),
  Text (type, text), Apps (apps, launch, upnext), Apple TV (status, power, tvs, use, scan,
  pair, forget), RemoteTV window (show, hide, sidebar). A bare noun reads (`power`,
  `text`, `playing`), an argument acts (`power off`, `text "…"`). Where the TV reports
  state, the command for a state is safe to repeat (`play`, `pause`, `captions on`,
  `power on`) and says so in `changed`; where it doesn't (mute over HDMI-CEC), there is
  only a toggle and the help says why. Old names stay as aliases (`np`, `wake`, `sleep`,
  `subtitles`; `Invocation.aliases`), not as second commands.
- **Adding a command** = an entry in `TVCommand.Help.entries` (usage, summary, detail,
  examples), a line in `Help.overview`, and its case in `TVCommand.parse` (acts on the TV)
  or in tvctl's `main` / the app's `command` (doesn't). `CLITests` fails when the three
  disagree, when help is wider than 80 columns, or when a button is missing from the help.
- **Options** work anywhere before a `--`: `--tv <name>`, `--json`, `-h/--help`,
  `--version` (and `--direct`, `-v` for debugging). tvctl hands the app the same command
  line in a form that parses back identically (`Invocation.wire`).
- **Output.** Text is for people and may be reworded. `--json` is the contract: one object
  on one line on stdout, `{"ok":true,…}` or `{"ok":false,"error":"…"}`, snake_case keys,
  seconds as numbers, unknown as null. Add fields; don't rename or remove them. Without
  `--json`, results go to stdout and failures to stderr. Prompts (the pairing PIN) and
  debug output (timings, traces) go to stderr.
- **Exit status**: 0 worked, 1 failed (TV unreachable, nothing playing, no such app), 2
  not understood (unknown command, bad argument; the reply ends with the usage line).
  A command line is checked before anything connects. 75 is internal (the app telling
  tvctl that `--tv` names a TV it isn't controlling: tvctl then connects to that one).
- **Honest results**: `launch` checks the name against the TV's app list instead of
  sending a bundle id into the void; a command the TV didn't confirm exits 1.
- **Protocol tools live under `tvctl debug`** and stay out of `tvctl help`.
- **Not covered, on purpose**: trackpad swipes (the arrows do the same moves), artwork and
  app icons (pictures for the window), the media-key tap. Everything else the window does
  has a command: switching and forgetting TVs (`use`, `forget`: the TV menu), playing an
  Up Next item, launching from the app grid.

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
  Remote+Commands.swift   buttons, playback, text, power, apps, touch, raw requests (Waiter);
                          knows/flush for a session made for one command
  TVCommand.swift         tvctl: reading the command line (Invocation), a command's result
                          (text + JSON + exit status), the commands that act on the TV
  TVCommand+Help.swift    tvctl's words: the command list, each command's help, "did you mean"
  JSON.swift              a JSON value, written on one line in the order listed (--json)
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
  Commands.swift          tvctl's commands about the app (window, which TV); TV commands →
                          TVCommand on the app's session; installs the tvctl symlink
  BundleWatcher.swift     restarts into a new version installed over this one (brew upgrade)
Sources/TVCtl/            tvctl: options and help, the pairings (tvs, scan, pair, use, forget),
                          through the app's socket or its own connection (oneShot), debug tools
Tests/RemoteCoreTests/    codecs, bignum/SRP vectors (from Python), fake HAP accessory,
                          FakeTV (loopback Apple TV: framing, pair-verify, encryption) +
                          SessionTests (Remote's state machine, liveness, trust boundary),
                          CommandTests (commands against FakeTV), CLITests (arguments, help, JSON)
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
- **Every request completes**: `raw` requests (apps, Up Next, tvctl debug raw) get their reply,
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
- **Wake knock**: the TV's last address (UserDefaults `host.<name>`, the app's domain,
  read and written by tvctl too: `Remote.defaults`) gets brief TCP
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
- **tvctl without the app** (`oneShot`, `TVCommand.run`): the command is parsed first (a
  typo never connects). Connecting retries a failed attempt (0.3 s, 1 s, 2 s, 4 s) for up
  to 10 s: one full attempt (8 s), whose failure knocks, and a retry; a lost pairing or
  Local Network denied ends it at once. `.connected` only means the handshake was *sent*,
  so a command waits for what it reads (`Remote.knows`): `power` and `text`/`type` for the
  handshake answers (≤1 s), `mute` for the AirPlay link (until it is up or has failed,
  ≤2 s), `np`/`status`/`seek` for now playing (250 ms after MRP is ready when nothing
  plays). The app's session passes all of these instantly; they also fix the app's
  reconnect-on-demand after its idle timeout (`np` said "nothing playing", `power` could
  toggle the wrong way). Then `Remote.flush`: an answered request sent behind everything
  else proves the TV read it all, and MRP frames are acknowledged one by one ("rply",
  `MediaRemote.unacknowledged`), ≤1 s; unanswered = exit 1 "didn't confirm". Then the goodbye
  and exit. No fixed waits anywhere: don't add one. One at a time: `flock` on
  `tvctl.lock` next to the pairings (parallel tvctls would kick each other off the TV);
  after getting the lock tvctl looks for the app's socket again. The app launching
  mid-command takes the connection: that command fails, the next goes through the app.
- **A client that hangs up** before its answer is written (tvctl interrupted, a bare
  connect to the socket) used to end the app with SIGPIPE, silently: `SO_NOSIGPIPE` can't
  be set on a socket whose peer already closed. The app ignores SIGPIPE
  (`ControlServer.start`). The listen queue is 128: to tvctl a refused connect means "the
  app isn't running", and it would connect itself and take the app's session.
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

- tvctl without the app: not timed against the TV yet (it wasn't reachable on 2026-11-22).
  Against FakeTV on loopback, connect + press + flush + goodbye is 19 ms, so live it should
  be the ~37 ms connect plus a round trip; mute/np/seek add the AirPlay link (~130 ms).
  For comparison, starting the app (what tvctl did before) took 0.43 s for a `snapshot`.

## Open work / ideas (owner hasn't asked for these; propose before big ones)

- Live checks owed for tvctl without the app (built with the TV out of reach; FakeTV tests
  cover the Companion side only): `time tvctl press …`, `playing` with something on and
  idle, `play`/`pause`, `mute`, `seek`, `type`/`text`, `power on|off`, `launch <name>`,
  `upnext <n>` with the app quit. Confirm the TV sends a "rply" for every
  MRP frame of ours (`tvctl -v debug mrp`; if it sends none at all, `flush` doesn't wait
  for them, and `mute`/`seek` leave without that proof). Check tvctl
  started by another app (Fred, a launchd job): macOS may ask *that* app for Local Network
  access; from a terminal tvctl is exempt.

- Not yet seen live: playing an Up Next item and launching from the app grid (the same
  `_launchApp` tvctl uses, which works).
- Review leftovers judged not worth it now: unifying `Connection`/`HAPStream` and their
  ciphers (different framing and nonce layouts; ~100 similar lines), a menu-bar mode.
- Hold a skip button to fast-forward/rewind (`_mcc` 8–11 begin/end).
- Reduce Loud Sounds toggle (one TVRC request); a sleep timer (sleep the TV in N minutes).
