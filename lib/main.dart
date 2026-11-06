import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'player/player_window.dart';

// --dart-define=JAVHUB_PHONE=true: a phone-sized window, to try the phone layout on a PC
const _phone = bool.fromEnvironment('JAVHUB_PHONE');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    runApp(const App());
    return;
  }
  // a movie in a window of its own (started by the main window)
  final player = args.indexOf('--player');
  if (player >= 0 && player + 1 < args.length) {
    await runPlayerWindow(args[player + 1]);
    return;
  }
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'JavHub',
      size: _phone ? Size(412, 900) : Size(1440, 900),
      minimumSize: _phone ? Size(360, 640) : Size(960, 640),
      center: true,
      backgroundColor: Color(0xFF0E1014),
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  await PlayerWindows.watchMainWindow();
  runApp(const App());
}
