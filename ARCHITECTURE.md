# DNUDesk Architecture Overview

> Written so another AI (or a new engineer) can understand this codebase's shape without
> reading it end to end. Line numbers are approximate as of 2026-09 and will drift; treat
> them as "look near here", not as guarantees. This file complements, not replaces:
> - [`AGENTS.md`](AGENTS.md) — coding conventions, editing hygiene, localization rules, PR review rules.
> - [`BUILD-DNUDesk.md`](BUILD-DNUDesk.md) — exact Windows build/toolchain steps and troubleshooting.
> - [`CLAUDE.md`](CLAUDE.md) / [`GEMINI.md`](GEMINI.md) — both just `@AGENTS.md` pointers for their respective tools.

## 0. What this repository is

This is **RustDesk**, an open-source remote-desktop client, currently rebranded to
**"DNUDesk"** (for Đại Nam University). It is a Rust core (`librustdesk`) driving screen
capture, encoding, networking and input injection, wrapped by a **Flutter UI**
(`flutter/`) for desktop and mobile. A legacy Sciter-based UI still exists under `src/ui/`
but is deprecated — do not extend it for new features unless explicitly asked.

This repo is **client-only**. The rendezvous/relay server binaries (`hbbs`/`hbbr`) live in
a separate upstream `rustdesk-server` repository and are not present here; `libs/hbb_common`
is the protocol/crypto crate shared between the client (this repo) and that server repo.

### This build is pointed at a private, self-hosted server

`libs/hbb_common/src/config.rs`:
```rust
pub const RENDEZVOUS_SERVERS: &[&str] = &["103.77.242.50"];
pub const RS_PUB_KEY: &str = "9mnAo+tXk5z0CnH6fH9QLE8GB6XXkXdciCNNyQp8w84=";
```
These are **not** the public RustDesk servers — they point at a privately-run VPS
(Ubuntu 22.04, also used ad hoc in this project as a static-file host for distributing the
installer; see §9). Every DNUDesk build talks to this VPS's `hbbs`/`hbbr` (Docker Compose,
`docker-compose.yml` on that VPS per `BUILD-DNUDesk.md` §9) instead of the public network.
Two machines only "see" each other if both are running a DNUDesk build pointed at the same
server + the same `RS_PUB_KEY`. `Config::get_rendezvous_server()` resolution order (highest
priority first): exe-embedded override → user's `custom-rendezvous-server` option →
runtime `PROD_RENDEZVOUS_SERVER` → persisted config → this hardcoded constant (last resort).

## 1. Repository layout

```
src/                    Rust app (the "rustdesk" crate, cdylib+staticlib+rlib "librustdesk")
src/server/             audio / clipboard / input / video capture+encode services (host side)
src/server/video_qos.rs adaptive bitrate/fps controller, has its own tests/ suite
src/platform/           platform-specific code (windows.rs is the biggest, by far)
src/ui/                 legacy Sciter UI (deprecated, don't extend)
src/lang/               per-language translation tables (see §10)
src/naming.rs           tiny helper bin: encodes a custom-server license into an exe-name token
src/service.rs          tiny helper bin: macOS launchd service entry point
flutter/                current UI (desktop + mobile), see §8
libs/hbb_common/        GIT SUBMODULE, shared with the separate server repo:
                         rendezvous protocol, Config core, crypto/transport helpers.
                         Costly to touch (round-trip). Prefer libs/base for client-only code.
libs/base/               (crate `base`) client-only: option keys, message proto (the
                         session wire protocol), file transfer (fs.rs), platform code.
                         libs/base/src/config/keys.rs is the single import path for option keys.
libs/scrap/              screen capture (all platforms) — see §6
libs/enigo/              cross-platform input INJECTION (vendored/forked; no protocol
                         knowledge, just "move mouse"/"press key" primitives)
libs/clipboard/          Windows CLIPRDR-style file-clipboard service
libs/virtual_display/    virtual monitor driver (idd) support
libs/remote_printer/     remote printer redirection
libs/portable/           the "portable packer" — see §9, has its own Cargo.toml/winres
                         metadata that is EASY TO FORGET during a rebrand (see §2)
```

Root `Cargo.toml` workspace members: `libs/scrap`, `libs/hbb_common`, `libs/base`,
`libs/enigo`, `libs/clipboard`, `libs/virtual_display(+/dylib)`, `libs/portable`,
`libs/remote_printer`. Two extra `[[bin]]` targets besides the main `rustdesk` binary:
`naming` and `service` (both tiny, see tree above).

## 2. Rebrand mechanics (RustDesk → DNUDesk)

The rebrand is driven by **one main switch**: `APP_NAME` in
`libs/hbb_common/src/config.rs` (`pub static ref APP_NAME: RwLock<String> =
RwLock::new("DNUDesk".to_owned());`). Most UI strings, the install path
(`C:\Program Files\<APP_NAME>\`), the Windows service name, shortcuts, and the tray
process derive their name from this at runtime via `crate::get_app_name()`.

**But it is not the only place.** Anything embedded into a compiled Windows **resource**
(`VERSIONINFO`) is a *separate*, static, build-time value that a rebrand pass can miss.
Two such gaps were found and fixed this way in this fork's history:
- `flutter/windows/CMakeLists.txt` `BINARY_NAME` and `flutter/windows/runner/Runner.rc`
  (`FileDescription`/`ProductName`/`OriginalFilename`) — must literally say `"DNUDesk"` /
  `"DNUDesk.exe"`, or the exe name and the taskbar/Task-Manager description mismatch
  `APP_NAME`, which breaks the install/shortcut/auto-open chain (shortcuts point at
  `<APP_NAME>.exe` on disk; if the actual compiled binary has a different `OriginalFilename`
  baked in, nothing about the exe's *content* changes, but tooling that reads that field
  (Explorer, Task Manager) can still show stale branding).
- **`libs/portable/Cargo.toml`** `[package.metadata.winres]` block (`ProductName`,
  `OriginalFilename`, `FileDescription`) and the `description` field — this is the
  **portable packer**'s own version resource (the single-file installer exe you actually
  hand out), built via the `winres` build-dependency, and it is *easy to forget* because it's
  a separate crate from the main app. It's origin upstream said `"RustDesk"` /
  `"RustDesk Remote Desktop"` / `"rustdesk.exe"` and had to be corrected by hand to match
  `APP_NAME`.
- **App icon**: `res/icon.ico` and `flutter/windows/runner/resources/app_icon.ico` — a
  rebrand pass that just swaps the source PNG and re-runs a naive ImageMagick one-liner can
  produce a `.ico` containing **only a single small frame** (e.g. 16×16) instead of a proper
  multi-resolution set (16/32/48/64/128/256). Windows then upscales that one tiny bitmap for
  every larger UI surface (taskbar, Alt-Tab, desktop shortcut), which looks visibly
  distorted/blurry. Check with Pillow: `Image.open(path).info.get('sizes')` should return
  a set of several sizes, not one. Also: a full logo lockup (mark + wordmark text) reads as
  mush at 16–32px; a small standalone mark (cropped, no text) reads far better at icon sizes
  — this is a legitimate design tradeoff to raise with whoever owns the brand, not something
  to silently decide unilaterally.

**Rule of thumb when touching branding:** grep for both the literal old name and `APP_NAME`
usage before assuming a rebrand is complete; check `.rc`/`Cargo.toml`/`winres` metadata
blocks specifically, since those don't recompile just because `APP_NAME` changed elsewhere.

## 3. Windows process model

This app is **one executable that behaves very differently depending on `argv[0]`/flags**,
not one process with internal windows. Understanding this is essential before touching
anything cross-window (hotkeys, tray, connection popups).

| Invocation | Role | Notes |
|---|---|---|
| `DNUDesk.exe` (no args) | Main window (Flutter `desktopType = DesktopType.main`) | Boots the local `--server`-equivalent logic in a background thread too (`start_server`), then Flutter GUI |
| `DNUDesk.exe --tray` | System tray icon process | **Separate OS process**, spawned by the main process if not already running (`src/tray.rs`, `crate::run_me(vec!["--tray"])`). Runs a `tao`/`tray_icon` event loop, NOT a Flutter window. "Open" in its menu just calls `run_me` with no args, relying on the *new* process's native `main.cpp` to `FindWindowW` the existing main window and `ShowWindow`+`SetForegroundWindow` it, then exit — no Dart/FFI involved in that path. |
| `DNUDesk.exe --cm` | Connection Manager popup (the small "X is connected, Permissions, Disconnect" window) | **Separate OS process**, spawned by the *server-side* connection handler (`src/server/connection.rs`, `crate::run_me(vec!["--cm"])`) when an incoming session needs UI. Talks to whichever process accepted the connection over a local IPC socket named `"_cm"` (see §7). |
| `DNUDesk.exe --service` | The Windows Service binary | Runs under SYSTEM, registered via `sc create {app_name} binpath= "...--service" ... DisplayName= "{app_name} Service"` (`src/platform/windows.rs`, `install_me`). |
| `DNUDesk.exe --install` | Interactive install dialog | Triggered automatically when a *packer* exe (see §9) whose filename ends in `install.exe` is run with no args. |
| `DNUDesk.exe --silent-install [printer=0/1] [debug]` | Unattended install | `src/core_main.rs` → `platform::install_me(options, "", silent=true, debug)`. Does registry/shortcut/service setup, spawns `--tray` afterward, but **does NOT auto-launch the main window** when silent — the caller must separately launch the installed exe if it wants the UI to appear. |
| `DNUDesk.exe --uninstall` | Full uninstall | What the registry's `UninstallString` and the Start-Menu "Uninstall" shortcut both point at; stops/deletes the service, kills processes, removes files/registry/shortcuts. Needs admin. |
| Remote session / File Transfer / View Camera / Port Forward / Terminal windows | Each a separate OS window via the `desktop_multi_window` Flutter package (**same process** as whatever spawned them, unlike tray/cm) | Dispatched in `flutter/lib/main.dart`'s `args.first == 'multi_window'` branch, keyed by `kAppTypeDesktopRemote`/`...FileTransfer`/`...ViewCamera`/`...PortForward`/`...Terminal` constants (`flutter/lib/consts.dart`). |

Default install path: `%ProgramFiles%\<APP_NAME>\<APP_NAME>.exe` (`get_default_install_path()`,
`src/platform/windows.rs`).

**First run after a fresh install is genuinely slow** (~minutes observed), not a bug per se:
the freshly-installed instance does one-time setup (keypair generation, first registration
with the rendezvous server) before the Flutter window paints anything (the native win32
window is created early and sits blank/titleless while Dart-side `runMainApp()` in
`main.dart` is still `await`-ing `bind.mainCheckConnectStatus()` and cache loads before
`runApp(App())`). Every subsequent launch is near-instant (observed: <1s) because that
one-time setup is already done. If scripting an "install then launch" flow, expect this
delay on first boot only.

## 4. IPC between local processes

`src/ipc.rs` defines the local IPC transport (named pipe on Windows) and the `enum Data`
message set used for **all** intra-machine, cross-process communication in this app — tray
↔ main, server-connection-handler ↔ CM, etc. It is a plain enum with
`#[serde(tag = "t", content = "c")]`, easy to extend with a new unit/struct variant.

Key named endpoints (`ipc::new_listener("<name>")` / `ipc::connect(timeout, "<name>")`):
- `"_cm"` — hosted by the Connection Manager process (`src/ui_cm_interface.rs::start_ipc`).
  Anything that needs to tell the CM UI something connects here as a client. Generic helper:
  `pub(crate) async fn send_to_cm(data: &ipc::Data)` in `src/ui_interface.rs` (despite the
  `async fn` signature it's `#[tokio::main(flavor = "current_thread")]`-wrapped, i.e. it's
  actually callable as a **plain sync function** — this pattern recurs for several
  "fire a quick IPC call from a sync FFI boundary" functions in that file; do not fight it
  by trying to `.await` it or wrapping it in your own runtime).
- The main IPC socket (unnamed/default postfix) used for install/uninstall/config CLI
  commands and general control between a CLI invocation and the running instance.

**How the CM UI reacts to a new `Data` variant** (the pattern to copy for any new
main-process → CM signal):
1. Add the variant to `enum Data` in `src/ipc.rs`.
2. Handle it in the per-connection `IpcTaskRunner::ipc_task` select loop in
   `src/ui_cm_interface.rs` (search for the `Data::Theme(dark) => self.cm.change_theme(dark);`
   arm as a template) — this loop runs per accepted `"_cm"` connection and has access to
   `self.cm: ConnectionManager<T>` regardless of whether a `Login` was ever received on that
   connection, so it's safe for "broadcast, not tied to a specific client" commands.
3. Add a method to the `trait InvokeUiCM` (same file) — this is the abstraction that both
   the Flutter backend (`impl InvokeUiCM for FlutterHandler` in `src/flutter.rs`) and the
   deprecated Sciter backend (`impl InvokeUiCM for SciterHandler` in `src/ui/cm.rs`, usually
   a no-op stub like `fn file_transfer_log(&self, _: &str, _: &str) {}`) must implement.
4. In the Flutter impl, call `self.push_event("some_event_name", &[...])` — this writes into
   `GLOBAL_EVENT_STREAM` keyed by an "app type" string (`APP_TYPE_CM`, etc.), which is how
   Rust pushes events into a *specific* Dart isolate/process.
5. On the Dart side, the central dispatcher is the long `if (name == '...') {...} else if
   (name == '...')` chain in `flutter/lib/models/model.dart` (inside the closure built by
   `FFI.startEventListener`) — add a branch matching your event name there, typically gated
   by `if (desktopType == DesktopType.cm) ...` if it's CM-specific.

This is exactly how the Ctrl+Alt+H "hide to tray" hotkey (added in this fork, see
`flutter/lib/desktop/widgets/tray_hotkey.dart`) also hides any currently-open CM window:
the main process's hotkey handler calls `windowManager.hide()` on its own window *and*
`bind.mainHideCmWindow()` (a `flutter_ffi.rs` function that calls `send_to_cm(&Data::HideCmWindow)`),
which round-trips through the five steps above to reach the CM process's own `windowManager.hide()`.

## 5. Networking & connection establishment

Two **separate** protobuf schemas are involved, generated from `.proto` files and
re-exported as Rust modules:
- **`rendezvous_proto`** (`libs/hbb_common/protos/rendezvous.proto`, re-exported at
  `libs/hbb_common/src/lib.rs`) — the ID/rendezvous-server protocol. Only used to talk to
  `hbbs`: register this machine's ID + public key, heartbeat, and relay `PunchHole`/
  `RequestRelay` signaling so two peers can find each other.
- **`message_proto`** (`libs/base/protos/message.proto`, re-exported at
  `libs/base/src/lib.rs`) — the actual remote-desktop session protocol once two peers are
  connected: `VideoFrame`, `MouseEvent`/`KeyEvent`, `Clipboard`, `FileTransfer*`,
  `LoginRequest`/`PeerInfo`, `ChatMessage`, `PortForward`, etc. This is the "message bus"
  that video, audio, input, clipboard and file-transfer all ride (see §6).

**`src/rendezvous_mediator.rs`** (`RendezvousMediator::start_udp`) is the client's
persistent connection to `hbbs`. On an incoming request it decides transport in
`handle_punch_hole`: symmetric NAT / forced-relay / no-TCP-listen → `create_relay` (asks
`hbbr` to broker, pure relay, no direct P2P); otherwise it races direct UDP hole-punch, TCP
hole-punch, and (this fork adds) **WebRTC** (SDP offer/answer + ICE, `webrtc::WebRTCStream`,
layered on the same PunchHole/RequestRelay signaling — a customization beyond stock
RustDesk). IPv6 punching is attempted independently and is never relayed. Unauthenticated
punch attempts are capped via bounded pools (`UDP_PUNCHES`/`TCP_PUNCHES`, max 32 each) to
limit resource abuse.

**Encryption**: sessions are end-to-end encrypted with libsodium primitives. Each client
has a persistent Ed25519 signing keypair. The rendezvous/relay server issues a `SignedId`
(the peer's box public key, signed by the server's Ed25519 key) — the connecting side
verifies that signature against `RS_PUB_KEY` (or a configured custom server key) before
trusting the peer's box key, which defeats a rendezvous-level MITM. The actual session key
is then a `crypto_box` (Curve25519) exchange producing a `secretbox` (XSalsa20-Poly1305) key
that encrypts all `message_proto` traffic. For the WebRTC transport, DTLS provides transport
encryption and this fork additionally binds the DTLS fingerprint into the signed identity
to stop a relay/rendezvous-level SDP-swap MITM. See `src/common.rs` (`decode_id_pk*`,
`create_symmetric_key_msg`, `secure_tcp*`) and `src/client.rs` (`secure_connection`).

## 6. Media & input pipeline

All of video, audio, input and clipboard ultimately move as `message_proto` messages over
the same encrypted connection (`GenericService`/`ConnInner` broadcast machinery) — think of
them as producers/consumers of one shared message bus, not separate transports.

**Screen capture** (`libs/scrap/`): `common/mod.rs` picks exactly one platform backend at
compile time (`dxgi` for Windows/DXGI Desktop Duplication with GDI/`CapturerMag` fallback,
`x11`/`wayland` for Linux — Wayland via PipeWire + xdg-desktop-portal D-Bus negotiation,
`quartz` for macOS CGDisplayStream, `android` via MediaProjection/JNI), all implementing
`trait TraitCapturer { fn frame(&mut self, timeout) -> io::Result<Frame> }`. `Frame` is
either `PixelBuffer` (CPU bytes) or `Texture` (GPU handle, for the hardware/`vram` path).
Also present: webcam capture (`common/camera.rs`) and a Linux DRM path for headless/virtual
displays. The consumer is `src/server/video_service.rs`'s per-display loop, which owns the
capturer and calls `.frame(spf)` every cycle.

**Video encoding**: software VP8/VP9 (libvpx), AV1 (libaom), hardware H264/H265 via the
external `hwcodec` crate (feature `hwcodec`), a GPU-memory `vram` path (feature `vram`), and
Android `mediacodec`. `libs/scrap/src/common/codec.rs` defines `trait EncoderApi` and the
`Encoder`/`Decoder` wrapper structs that pick a concrete backend via `EncoderCfg`.
`video_service.rs::setup_encoder()` negotiates codec choice from what the peer declared it
can decode, falling back to VP9 on any encoder-creation failure. **QoS/adaptive bitrate**
lives in `src/server/video_qos.rs` (`struct VideoQoS`) — it reacts to measured network
delay/jitter to adjust fps/quality/bitrate every loop iteration; this fork has a notably
large dedicated test suite under `src/server/video_qos/tests/` (jitter, recovery,
adaptation, baseline, invariants, smoke, sim), suggesting this logic was substantially
hardened relative to upstream.

**Audio**: `src/server/audio_service.rs` uses `cpal` for capture (with `ScreenCaptureKit`
loopback detection on macOS), gates silence to save bandwidth, encodes via `magnum_opus`
(Opus, low-delay), and broadcasts `AudioFrame` messages the same way as video.

**Input**: split into a protocol/policy layer and a raw-injection layer, on *both* sides:
- Host side: `src/server/input_service.rs` receives `MouseEvent`/`KeyEvent`, applies
  RustDesk-specific policy (privacy mode, cursor visibility, anti-jump-attack timing,
  permission checks, lock-key sync), then calls into `libs/enigo/` — a vendored/forked,
  protocol-agnostic OS-input-injection library (`SendInput` on Windows, `xdo`/uinput on
  Linux, `CGEvent` on macOS). Three keyboard modes exist to balance cross-layout fidelity:
  `Map` (raw physical keycode passthrough), `Translate` (client sends the produced
  character, host reproduces it under its own layout), and a legacy Control-Key/Unicode
  union mode.
- Controller side: `src/keyboard.rs` uses `rdev` (a *different* low-level hook crate from
  enigo) to grab local input and build the outgoing `KeyEvent`/`MouseEvent` messages,
  mirroring the same three keyboard modes.

**Clipboard**: text/image sync is simple polling + diffing via `arboard`
(`src/clipboard.rs`, `check_clipboard`/`update_clipboard`, tagged with an owner marker to
avoid echo loops). **File clipboard** (copy files on one machine, paste on the other) is a
different, heavier mechanism modeled on the Windows RDP CLIPRDR virtual channel
(`libs/clipboard/`, `trait CliprdrServiceContext`, chunked `FileContentsRequest`); its
lifecycle is managed by the small singleton in `libs/clipboard/src/context_send.rs`
(`ContextSend::enable/is_enabled/proc`) so the rest of the app doesn't manage the context's
lifetime directly.

**File transfer**: `libs/base/src/fs.rs`, `struct TransferJob` is the job model (one per
transfer), constructed via `new_write`/`new_read`. Files stream as sequential 128KiB
`FileTransferBlock` messages (`const BUF_SIZE = 128 * 1024`), not sent whole, enabling
progress/pause/resume. This fork adds explicit path-safety validation before touching the
local filesystem with a remote-supplied name: `validate_file_name_no_traversal`,
`validate_no_symlink_components`, `join_validated_path`.

## 7. Flutter UI layer (`flutter/lib/`)

- `main.dart` — entry point; branches on launch args/appType to decide which screen to boot
  (see the process-model table in §3 for the process-level version of this split).
- `desktop/` — desktop UI: `pages/` (one file per logical screen), `screen/` (the top-level
  widgets actually instantiated per `multi_window` subprocess), `widgets/` (title bar, tab
  bar, toolbar, the tray hotkey module).
- `mobile/` — mobile UI. Shares the *exact same* `models/` layer and FFI bridge as desktop;
  the only difference is presentational (single-screen `Navigator` push/pop instead of
  multi-window/tabs, touch-oriented widgets like `floating_mouse.dart`, QR scan for ID entry).
- `common/` — cross-platform shared widgets (peer cards, chat, login dialogs, toolbar) used
  by both desktop and mobile page variants.
- `models/` — all app state. Everything hangs off a global `gFFI` (class `FFI`, defined in
  the large `models/model.dart`, ~4700 lines) which owns per-session state keyed by
  `SessionID` and the central native-event dispatcher. Notable individual models:
  `server_model.dart` (host-being-controlled state), `platform_model.dart` /
  `native_model.dart` (the FFI bridge singleton, `bind`), `file_model.dart` (transfers),
  `chat_model.dart`, `ab_model.dart` (address book), `group_model.dart`, `user_model.dart`,
  `peer_model.dart`/`peer_tab_model.dart` (home-page peer list), `cm_file_model.dart`
  (file-transfer log shown in the CM popup), `terminal_model.dart`, `input_model.dart`.
  **State management is a genuine mix** of `provider` (`ChangeNotifier`) and `get`/GetX
  (`.obs`/`Rx*`), sometimes within the same class — not a clean single pattern, so don't be
  surprised finding either style and match whichever the file you're editing already uses.
- `web/` and `native/` — parallel shim directories selected via conditional imports
  (`if (dart.library.html)`) so the same call sites compile for both Flutter-web and native.
- `utils/multi_window_manager.dart` — wraps the `desktop_multi_window` package for
  spawning/tracking the remote/file-transfer/etc. subwindows mentioned in §3.

**FFI bridge**: `src/flutter_ffi.rs` (Rust) has one function per Dart-callable operation;
`flutter_rust_bridge_codegen` generates `flutter/lib/generated_bridge.dart` (Dart, camelCase
functions like `bind.mainCheckConnectStatus()`) and `src/bridge_generated.rs` from it.
**Neither generated file is committed** — see `BUILD-DNUDesk.md` §4 for how to regenerate
after touching `flutter_ffi.rs` (`dobridge.bat` locally: installs `cargo-expand` +
`flutter_rust_bridge_codegen` 1.80.1, then runs the codegen CLI). Forgetting this step after
adding/changing an FFI function is a common build break (`bind.xxx` undefined in Dart, or a
stale signature).

**Event push (Rust → Dart)**: `push_event(name, kv_pairs)` writes into a
`GLOBAL_EVENT_STREAM` keyed by an "app type" string (`APP_TYPE_CM`, etc. — for desktop
remote windows namespaced as `"$appType,$windowId"` to disambiguate multiple windows of the
same type). Each process/window registers exactly one `_eventCallback` via
`platformFFI.setEventCallback(...)`; the `FFI` class's `startEventListener(sessionId,
peerId)` builds the actual dispatcher closure (the long `if (name == '...')` chain in
`models/model.dart`) and fans events out by `SessionID` for multi-tab/session isolation
within one window/process.

**Notable forked Flutter packages** (mostly under the `rustdesk-org` GitHub org, pinned to a
commit in `pubspec.yaml`): `window_manager`, `desktop_multi_window`, `dash_chat_2` (chat
UI), `flutter_custom_cursor`, `flutter_texture_rgba_renderer` / `flutter_gpu_texture_renderer`
(render decoded video frames into a Flutter texture — core video-display path),
`dynamic_layouts`, `window_size` (third-party, not rustdesk-org). This session additionally
added `hotkey_manager` (upstream leanflutter package, not forked) for the Ctrl+Alt+H
global-hotkey feature (§4).

## 8. Build & packaging

Full toolchain setup, exact commands, and a troubleshooting table live in
**`BUILD-DNUDesk.md`** — read that before attempting a build. Summary of the pipeline once
toolchain is set up (local helper scripts referenced there: `dobridge.bat`, `dobuild.bat`,
`dopack.bat`):
1. `dobridge.bat` — regenerate the Dart↔Rust FFI bridge (only needed after touching
   `src/flutter_ffi.rs`).
2. `dobuild.bat` → `python build.py --portable --flutter --skip-portable-pack --hwcodec` —
   builds `librustdesk.dll` (Rust) and the Flutter Windows runner, producing
   `flutter/build/windows/x64/runner/Release/DNUDesk.exe` + `librustdesk.dll` + plugin DLLs
   + `data/` — this folder is a self-contained portable app (no VC++ redist needed).
3. `dopack.bat` → `libs/portable/generate.py -f <Release dir> -e <Release dir>/DNUDesk.exe`
   — the **portable packer**: compresses (brotli) and embeds that whole Release folder as a
   payload inside a small wrapper exe (`libs/portable/src/main.rs`), producing
   `target/release/rustdesk-portable-packer.exe` (~24 MB). This *is* the installer you hand
   out; rename it to `DNUDesk-<version>-install.exe` for distribution (note: **the filename
   itself has behavioral meaning** — `libs/portable/src/main.rs` checks
   `arg_exe.ends_with("install.exe")` with no args to decide whether to auto-run the
   embedded exe with `--install`; passing `--silent-install` explicitly bypasses that check
   regardless of filename).
   - `build.py` hardcodes `rustdesk.exe` as the entry executable name, so after a rebrand you
     must call `generate.py` directly with `-e .../DNUDesk.exe` rather than relying on
     `build.py --portable-pack`.
   - `libs/portable/Cargo.toml`'s `[package.metadata.winres]` block controls *this packer
     exe's own* Windows version resource — see the rebrand gap noted in §2.

**Distribution note from this session**: for ad hoc distribution to other machines, the
packer exe was uploaded via SFTP to `/var/www/html/dl/DNUDesk-install.exe` on the
project's VPS (same VPS as §0's rendezvous server) behind a plain `nginx` install, and a
one-line PowerShell snippet on the target machine does
`Invoke-WebRequest ... ; Start-Process $f -ArgumentList "--silent-install" -Verb RunAs -Wait ; Start-Process "$env:ProgramFiles\DNUDesk\DNUDesk.exe"`
— this is ad hoc project infrastructure, not something the build system automates.

## 9. Localization (`src/lang/*.rs`)

See `AGENTS.md`'s Localization section for the authoritative rules (never edit
`template.rs`'s existing entries when translating; `it.rs` is hand-maintained by its
translator, never auto-fill it; sentence-case for new English keys; etc.). One line each:
`template.rs` is the master key list (all values `""`), `en.rs` holds only keys whose display
text differs from the key itself, every other `xx.rs` carries the full key set with `""` for
untranslated entries.

## 10. Editing conventions

Fully specified in `AGENTS.md` — read it before making non-trivial changes. Highlights most
relevant to this codebase's shape:
- `libs/hbb_common` is a submodule shared with the separate server repo — prefer
  `libs/base` for anything client-only to avoid that round-trip.
- Prefer additive, `#[cfg]`-gated new code over reshaping existing functions; a new function
  with a little duplication beats a shared abstraction that forces unrelated callers to
  change.
- Platform-specific logic belongs in `src/platform/{windows,linux,macos}.rs`; shared files
  (`src/tray.rs`, `src/core_main.rs`, `src/server/connection.rs`, …) should only get
  thin one-line hooks calling into that platform-specific module.
- No `unwrap()`/`expect()` outside tests/lock-poisoning; never hold a lock across `.await`;
  never nest a Tokio runtime (except the established `#[tokio::main(flavor =
  "current_thread")]`-on-a-"sync"-fn pattern in `src/ui_interface.rs` — that one is
  intentional, don't "fix" it).
- One `use` per crate, merged into a single braced block (see AGENTS.md for the exact
  exceptions around `#[cfg]` and re-exports).

## 11. Quick index — "where do I look for X?"

| Task | Start here |
|---|---|
| Change what happens on install/uninstall/service | `src/core_main.rs` (arg dispatch), `src/platform/windows.rs` (`install_me`, `uninstall_me`, service `sc create` strings) |
| Add a new cross-process signal (main → tray/CM) | `src/ipc.rs` (`enum Data`) + §4 of this doc |
| Add/change a Dart-callable Rust function | `src/flutter_ffi.rs`, then regenerate per `BUILD-DNUDesk.md` §4 |
| Change tray menu / tray behavior | `src/tray.rs` |
| Change the Connection Manager popup UI | `flutter/lib/desktop/pages/server_page.dart` (`ConnectionManager`, `_CmHeader`, `_PrivilegeBoard`, `_CmControlPanel`) |
| Change the main/home screen UI | `flutter/lib/desktop/pages/desktop_home_page.dart` |
| Add a global hotkey | `flutter/lib/desktop/widgets/tray_hotkey.dart` (uses the `hotkey_manager` package; register only inside `runMainApp()` in `main.dart` so it doesn't leak into other subprocess windows) |
| Change video/audio quality behavior | `src/server/video_qos.rs` (has its own test suite — run it) |
| Change how remote input is applied | `src/server/input_service.rs` (host side) / `src/keyboard.rs` (controller side) |
| Change file-transfer chunking/validation | `libs/base/src/fs.rs` |
| Change which servers a build talks to | `libs/hbb_common/src/config.rs` (`RENDEZVOUS_SERVERS`, `RS_PUB_KEY`) — remember this is submodule code |
| Change app branding/name | `libs/hbb_common/src/config.rs` `APP_NAME` **plus** every place in §2 of this doc — grep, don't assume one edit is enough |
| Change the installer/packer itself | `libs/portable/` (`generate.py`, `src/main.rs`, its own `Cargo.toml` winres block) |
| Add/translate UI strings | `src/lang/*.rs` per §9, following `AGENTS.md`'s rules exactly |
