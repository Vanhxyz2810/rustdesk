import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

/// Registers a Windows-only global hotkey (Ctrl+Alt+H) that hides the main
/// window and any open Connection Manager window to the system tray,
/// regardless of which app currently has focus.
Future<void> registerHideToTrayHotKey() async {
  if (!isWindows) return;
  await hotKeyManager.unregisterAll();
  final hotKey = HotKey(
    key: PhysicalKeyboardKey.keyH,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );
  await hotKeyManager.register(
    hotKey,
    keyDownHandler: (_) {
      windowManager.hide();
      bind.mainHideCmWindow();
    },
  );
}
