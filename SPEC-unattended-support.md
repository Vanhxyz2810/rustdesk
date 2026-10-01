# SPEC: "Unattended support" preset for DNUDesk

Context: DNUDesk is a RustDesk fork used by university IT admins for remote support of
Windows lab machines they manage. Remote-support tools (TeamViewer, AnyDesk, RustDesk
itself) all offer a standard "unattended access" mode: the IT admin connects with the
permanent password during approved maintenance windows. This preset is a small UX
polish on top of that existing, standard path: the Connection Manager (CM) window
starts **minimized** instead of popping up, keeping the desktop quiet during
maintenance. The window is never hidden — its taskbar entry stays, and the local
user can bring it up and disconnect at any time. Everything is config-gated; default
behavior is unchanged.

Read `AGENTS.md` first and follow its coding rules strictly (minimal diff, additive
changes, no `unwrap()` in prod code, merged `use` imports per crate).

## Implementation decisions (already made — do not redesign)

1. **New option key** `unattended-support` in `libs/base/src/config/keys.rs`
   (near `OPTION_ID_WHITELIST`, ~line 59), also added to `KEYS_SETTINGS` (~line 272).

2. **No auth changes.** The existing `approve-mode=password` + permanent-password path
   already accepts sessions without a click. Do NOT touch `src/server/connection.rs`.

3. **Rust IPC branch.** In `src/ipc.rs`, in the config-query handling chain, right
   after the existing `hide_cm` branch (~lines 970-976), add a branch for query
   name `unattended_support`. Add a pure helper:

   ```rust
   pub fn unattended_support_minimize_cm() -> bool
   ```

   returning `true` only when ALL hold:
   - option `unattended-support` == `"Y"`
   - `approve_mode()` == `ApproveMode::Password` (from `hbb_common::password_security`)
   - the `id-whitelist` option is non-empty

   Study how the `hide_cm` branch reads its value (`hbb_common::password_security::hide_cm()`)
   and mirror that pattern. This gate guarantees the CM is never minimized while a
   click-to-accept prompt is pending.

4. **Flutter side** (three small, guarded edits):
   - `flutter/lib/models/server_model.dart`: add field `bool minimizeCm = false;`
     next to the existing `hideCm` field (~line 34).
   - `flutter/lib/main.dart` `runConnectionManagerScreen` (~lines 294-300): after the
     existing `hide_cm` config read, also query `unattended_support` (same
     `cmGetConfig` mechanism). When true: `waitUntilReadyToShow` then
     `windowManager.minimize()` — keep opacity at 1, do NOT call `hide()` (taskbar
     entry must stay). When false: keep the existing `showCmWindow(isStartup: true)`
     call exactly as today.
   - `flutter/lib/models/server_model.dart` `_addTab` (~line 579): change the single
     line `if (!hideCm) windowOnTop(null);` to `if (!hideCm && !minimizeCm) windowOnTop(null);`
     — this is the ONLY existing Dart line to modify.

5. **Rust unit tests** for the helper in the `src/ipc.rs` test module:
   - off → false
   - on + `click` mode → false
   - on + `both` mode → false
   - on + `password` + empty whitelist → false
   - on + `password` + non-empty whitelist → true

   Look at how existing tests in the file set config options and follow that pattern.

6. **Do NOT**: regenerate the FFI bridge, touch `src/ui.rs` (legacy Sciter UI),
   or add lang keys.

## Verification

Run `cargo check` and the narrowest `cargo test` that covers the helper.
Report: files changed, diff summary, test results, and any deviations from this
spec with reasons.
